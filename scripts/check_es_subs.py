#!/usr/bin/env python3
"""
Verifica que todas las peliculas y series tengan subtitulos en espanol.
Si faltan, intenta descargarlos via Bazarr providers o OpenSubtitles REST API.
Ejecutar periodicamente via cron (ej: cada 6h).
"""

import requests
import json
import time
import os
import sys
import re
import gzip
import fcntl
import logging
import subprocess
from logging.handlers import RotatingFileHandler
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sub_qa
import fix_subs_whisper as subfix

ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'check_es_subs.env')
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'check_es_subs.log')
LOCK_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.check_es_subs.lock')
OS_QUOTA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'os_quota.json')
OS_DAILY_LIMIT = int(os.getenv('OS_DAILY_LIMIT', '5'))
# PROVIDERS_ONLY=1 → SOLO los providers de Bazarr+ (incluye opensubtitles/.org vía
# FlareSolverr). No toca OpenSubtitles.com (cuota), ni traduce, ni whisper.
PROVIDERS_ONLY = os.getenv('PROVIDERS_ONLY', '0') == '1'

def load_env(path):
    if not os.path.isfile(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            k, _, v = line.partition('=')
            os.environ[k.strip()] = v.strip()

load_env(ENV_PATH)

BAZARR_URL = os.getenv('BAZARR_URL', 'http://localhost:6767')
API_KEY = os.getenv('BAZARR_API_KEY', '')
HEADERS = {"X-API-KEY": API_KEY}
NOTIFY_URL = os.getenv('NOTIFY_URL', 'http://localhost:3555/notify/system-update')
NOTIFY_SECRET = os.getenv('NOTIFY_SECRET', '')
PAUSE = 1
NEG_TTL = 30 * 86400  # expiracion de entradas negativas del cache OMDb (30 dias)

logger = logging.getLogger('check_es_subs')
logger.setLevel(logging.INFO)
if not logger.handlers:
    _fh = RotatingFileHandler(LOG_PATH, maxBytes=2_000_000, backupCount=3)
    _fh.setFormatter(logging.Formatter('[%(asctime)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S'))
    _sh = logging.StreamHandler(sys.stdout)
    _sh.setFormatter(logging.Formatter('[%(asctime)s] %(message)s', datefmt='%H:%M:%S'))
    logger.addHandler(_fh)
    logger.addHandler(_sh)

_lock_fh = None

def acquire_lock():
    """Evita corridas solapadas de cron (flock exclusivo no bloqueante)."""
    global _lock_fh
    _lock_fh = open(LOCK_PATH, 'w')
    try:
        fcntl.flock(_lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        logger.info("Ya hay una corrida en curso; saliendo")
        sys.exit(0)

class BazarrDown(Exception):
    pass

def log(msg):
    logger.info(msg)

def notify_whatsapp(text):
    if not NOTIFY_URL or not NOTIFY_SECRET:
        return
    try:
        requests.post(NOTIFY_URL,
                      headers={'x-update-token': NOTIFY_SECRET},
                      json={'message': text}, timeout=10)
    except Exception:
        pass

def get_json(url, params=None, timeout=30):
    """GET JSON contra Bazarr. Devuelve None si Bazarr fallo (timeout/HTTP/JSON)."""
    try:
        r = requests.get(url, headers=HEADERS, params=params, timeout=timeout)
    except requests.RequestException as e:
        log(f"ERROR: Bazarr inaccesible ({url}): {e}")
        return None
    if r.status_code != 200:
        log(f"ERROR: Bazarr respondio HTTP {r.status_code} en {url}")
        return None
    try:
        return r.json()
    except ValueError:
        log(f"ERROR: Bazarr devolvio JSON invalido en {url}")
        return None

def api_post(base, params):
    r = requests.post(base, headers=HEADERS, params=params, timeout=30)
    return r

def api_patch(base, params):
    r = requests.patch(base, headers=HEADERS, params=params, timeout=30)
    return r

def providers_get(url, timeout_sec=60):
    r = requests.get(url, headers=HEADERS, timeout=timeout_sec)
    return r.json() if r.status_code == 200 else {}

MEDIA_MOVIES = '/mnt/media/movies'
DEEPL_API_KEY = os.getenv('DEEPL_API_KEY', '')
GEMINI_API_KEY = os.getenv('GEMINI_API_KEY', '')
OMDB_API_KEY = os.getenv('OMDB_API_KEY', '')
OMDB_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'omdb_cache.json')
omdb_cache = {}

def load_omdb_cache():
    global omdb_cache
    if os.path.isfile(OMDB_CACHE_PATH):
        try:
            with open(OMDB_CACHE_PATH) as f:
                omdb_cache = json.load(f)
            # migrar negativos viejos (null permanente) a formato con TTL
            for k, v in omdb_cache.items():
                if v is None:
                    omdb_cache[k] = {'neg': time.time()}
            log(f"Cargados {len(omdb_cache)} items del cache OMDb")
        except Exception:
            omdb_cache = {}

def save_omdb_cache():
    """Escritura atomica (tmp + rename) para no corromper el cache."""
    try:
        tmp = f"{OMDB_CACHE_PATH}.tmp"
        with open(tmp, 'w') as f:
            json.dump(omdb_cache, f, indent=2)
        os.replace(tmp, OMDB_CACHE_PATH)
        log(f"Cache OMDb guardado ({len(omdb_cache)} items)")
    except Exception as e:
        log(f"Error guardando cache OMDb: {e}")

def cached_imdb(key):
    """Devuelve (hit, imdb_id|None). Las entradas negativas expiran tras NEG_TTL."""
    v = omdb_cache.get(key, '__miss__')
    if v == '__miss__':
        return False, None
    if isinstance(v, dict):
        if time.time() - float(v.get('neg', 0)) < NEG_TTL:
            return True, None
        del omdb_cache[key]
        return False, None
    return True, v

def has_es_subs(subtitles):
    if not subtitles:
        return False
    return any(s.get('code2') in ES_CODES2 for s in subtitles)


def _scan_es_sidecars(video_path):
    """[(path, clase)] de todos los sidecar ES del video, sin importar cómo los
    haya nombrado Bazarr (.es.srt, .es-MX.srt, .srt a secas, .hi.srt, .sdh.srt).

    La clase sale del CONTENIDO (sub_qa.classify_srt), no del nombre ni del flag
    hearing_impaired del provider: ambos son poco fiables — vimos .hi.srt con
    ratio_sdh 0.00 (diálogo limpio mal etiquetado) y candidatos con
    hearing_impaired "False" que venían con [sonidos] de verdad.
    """
    if not video_path:
        return []
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', os.path.basename(video_path), flags=re.I)
    d = os.path.dirname(video_path)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    stem = base.lower()
    out = []
    for f in names:
        fl = f.lower()
        if not fl.endswith('.srt'):
            continue
        # {base}.es*.srt, {base}.srt o {base}.es.hi.srt — todos los nombres que usa Bazarr
        if not (fl.startswith(stem + '.es') or fl == stem + '.srt'):
            continue
        path = os.path.join(d, f)
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                content = fh.read()
        except Exception:
            continue
        if '-->' not in content:
            continue
        out.append((path, sub_qa.classify_srt(content)))
    return out


def _promote_sdh(video_path, hi_path):
    """Limpia un sub SDH y lo guarda como .es.srt canónico.

    Prefiere esto antes que traducir del inglés o transcribir con whisper: es
    diálogo humano en español, solo hay que sacarle los [sonidos]. Si tras
    limpiar quedan menos del 40% de los cues, era casi todo efectos y no vale.
    """
    try:
        with open(hi_path, encoding='utf-8', errors='replace') as fh:
            content = fh.read()
    except Exception:
        return None
    before = len(sub_qa.parse_srt(content))
    cleaned, after = subfix.clean_sdh_srt(content)
    if not cleaned or before == 0 or (after / before) < 0.40:
        log(f"    SDH con poco diálogo tras limpiar ({after}/{before}); se descarta")
        return None
    if not _finalize_srt(cleaned, _canonical_es_path(video_path), video_path):
        return None
    log(f"    SDH limpiado y promovido ({after}/{before} cues)")
    return _canonical_es_path(video_path)


def _canonical_es_path(video_path):
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', os.path.basename(video_path), flags=re.I)
    return os.path.join(os.path.dirname(video_path), f"{base}.es.srt")


def _find_usable_es(video_path):
    """Devuelve el path de un sidecar ES usable, o None.

    Política: primero un sub español NORMAL. Si solo existe SDH/HI español, se
    limpia y se promueve (mejor que traducir o transcribir).
    """
    entries = _scan_es_sidecars(video_path)
    for p, clase in entries:
        if clase == 'normal':
            return p
    for p, clase in entries:
        if clase == 'sdh':
            promoted = _promote_sdh(video_path, p)
            if promoted:
                return promoted
    return None

def needs_work(video_path, subtitles):
    """(hay_que_trabajar, motivo). Un sub roto cuenta igual que uno faltante.
    Motivos: ok | embebido | sin_es | roto | desync ('desync' = el sub es
    diálogo ES válido pero el QA lo rechaza por sincronía/cobertura → se puede
    resincronizar en vez de reemplazar).
    No confía en lo que reporta Bazarr: verifica sidecar en disco y, si no,
    los tracks embebidos con ffprobe (Bazarr a veces reporta ES fantasma)."""
    usable = _find_usable_es(video_path) if video_path else None
    if usable:
        try:
            with open(usable, encoding='utf-8', errors='replace') as f:
                content = f.read()
        except Exception:
            return True, 'roto'
        try:
            qa = sub_qa.qa_subtitle(content, video_path=video_path)
        except Exception:
            return True, 'roto'
        if qa.get('ok'):
            return False, 'ok'
        if sub_qa.is_sync_shaped(qa.get('motivo', '')):
            return True, 'desync'
        return True, 'roto'
    if video_path:
        base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', os.path.basename(video_path), flags=re.I)
        if os.path.isfile(os.path.join(os.path.dirname(video_path), f"{base}.es.hi.srt")):
            return True, 'roto'
        if subfix.has_embedded_es(video_path):
            return False, 'embebido'
    return True, 'sin_es'

def _sidecar_names(video_path):
    """Nombres de sidecar ES del video (misma regla que _scan_es_sidecars)."""
    if not video_path:
        return []
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', os.path.basename(video_path), flags=re.I)
    d = os.path.dirname(video_path)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    stem = base.lower()
    out = []
    for f in names:
        fl = f.lower()
        if not fl.endswith('.srt'):
            continue
        if fl.startswith(stem + '.es') or fl == stem + '.srt':
            out.append(f)
    return out


def _snapshot_sidecars(video_path):
    """{nombre: contenido} de los sidecar ES actuales, para poder restaurar."""
    d = os.path.dirname(video_path)
    snap = {}
    for f in _sidecar_names(video_path):
        try:
            with open(os.path.join(d, f), encoding='utf-8', errors='replace') as fh:
                snap[f] = fh.read()
        except OSError:
            pass
    return snap


def _restore_sidecars(video_path, snap):
    """Deshace descargas fallidas: borra los sidecar nuevos y reescribe los viejos."""
    d = os.path.dirname(video_path)
    for f in _sidecar_names(video_path):
        if f not in snap:
            try:
                os.remove(os.path.join(d, f))
            except OSError:
                pass
    for f, content in snap.items():
        try:
            with open(os.path.join(d, f), 'w', encoding='utf-8') as fh:
                fh.write(content)
        except OSError:
            pass


def _read_text(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return None


def _changed_sidecars(video_path, snap):
    """[(path, clase)] de sidecar ES nuevos o modificados respecto al snapshot.

    Solo estos pueden ser la descarga reciente: aceptar "cualquier sidecar en
    disco" era lo que hacía marcar OK! sobre el sub viejo.
    """
    out = []
    for p, clase in _scan_es_sidecars(video_path):
        f = os.path.basename(p)
        if f not in snap or snap[f] != _read_text(p):
            out.append((p, clase))
    return out


def _drop_file(path):
    try:
        os.remove(path)
    except OSError:
        pass


def try_bazarr_es(cands, post_url, body_base, video_path):
    """Prueba candidatos de Bazarr hasta que quede un sub español usable.

    Orden de preferencia: un sub español NORMAL. Si solo aparecen SDH/HI, se
    guarda el mejor como respaldo y se sigue buscando uno normal; si no hay
    ninguno, se limpia el SDH (sacando [sonidos]) y se promueve a .es.srt.
    Nunca se borra sin antes haber intentado limpiarlo.

    Un candidato solo se acepta si pasa el QA de sub_qa (un sub desincronizado
    o incompleto no cuenta como "OK"). Si ningún candidato sirve, los sidecars
    quedan como estaban antes de empezar.
    """
    ordered = sorted([c for c in cands if isinstance(c, dict)],
                     key=lambda x: -(x.get('score') or 0))
    snap = _snapshot_sidecars(video_path)
    sdh_backup = None
    tried = 0
    for best in ordered:
        if tried >= 15:
            break
        tried += 1
        log(f"    Bazarr: {best.get('provider')} (score: {best.get('score')})")
        body = dict(body_base)
        body['provider'] = best.get('provider')
        body['subtitle'] = best.get('subtitle')
        r = api_post(post_url, body)
        if r.status_code != 204:
            log(f"    Error descarga Bazarr: {r.status_code}")
            continue
        time.sleep(2)
        nuevos = _changed_sidecars(video_path, snap)
        if not nuevos:
            log(f"    Sin sidecar nuevo en disco; sigo con el siguiente")
            continue
        vistos = False
        for p, clase in nuevos:
            if clase == 'normal':
                vistos = True
                qa = sub_qa.qa_subtitle(_read_text(p) or '', video_path=video_path)
                if qa.get('ok'):
                    for q, _ in nuevos:
                        if q != p:
                            _drop_file(q)
                    log(f"    OK!")
                    return True
                log(f"    Descartado por QA ({qa.get('motivo')}); sigo con el siguiente")
                _drop_file(p)
                break
        for p, clase in nuevos:
            if clase == 'sdh' and sdh_backup is None:
                sdh_backup = p
                vistos = True
                log(f"    Es SDH; lo guardo de respaldo y sigo buscando uno normal")
                break
        if not vistos:
            log(f"    Descartado (sin diálogo en español); sigo con el siguiente")
    if sdh_backup and _promote_sdh(video_path, sdh_backup):
        for p, _ in _changed_sidecars(video_path, snap):
            if p != _canonical_es_path(video_path):
                _drop_file(p)
        log(f"    Solo había SDH; limpiado y listo")
        return True
    _restore_sidecars(video_path, snap)
    return False


def bazarr_scan_movie(radarr_id):
    if not radarr_id:
        return
    try:
        api_patch(f"{BAZARR_URL}/api/movies", {"radarrid": radarr_id, "action": "scan-disk"})
    except Exception:
        pass

def bazarr_scan_series(series_id):
    if not series_id:
        return
    try:
        api_patch(f"{BAZARR_URL}/api/series", {"seriesid": series_id, "action": "scan-disk"})
    except Exception:
        pass

def is_hearing_impaired(entry):
    """True si el sub es para sordos (SDH/CC/HI), por flag del API o por nombre."""
    if not isinstance(entry, dict):
        return False
    if str(entry.get('SubHearingImpaired', '0')) == '1':
        return True
    if str(entry.get('hearing_impaired', '')).lower() in ('true', '1', 'yes'):
        return True
    if str(entry.get('hi', '')).lower() in ('true', '1', 'yes'):
        return True
    name = str(entry.get('SubFileName', '') or entry.get('release_info', '') or entry.get('release', ''))
    return bool(re.search(r'\bsdh\b|\bcc\b|\bhi\b|hearing.impaired', name, re.I))

def without_hearing_impaired(entries):
    filtered = [e for e in entries if isinstance(e, dict) and not is_hearing_impaired(e)]
    skipped = len(entries) - len(filtered)
    if skipped:
        log(f"    Descartados {skipped} subs para sordos (SDH)")
    return filtered

OS_API = 'https://api.opensubtitles.com/api/v1'
OS_KEY = os.getenv('OPENSUBTITLES_COM_KEY', '')
OS_HEADERS = {'Api-Key': OS_KEY, 'User-Agent': 'ChaeSubs v1.0', 'Accept': 'application/json'}
# Códigos con los que OpenSubtitles/Bazarr listan español (incluye variantes latam)
OS_LANGS = 'es,spa,es-ES,es-LA,esla,es-MX,es-AR,ea,sp'
ES_CODES2 = ('es', 'ea', 'sp', 'spa', 'es-ES', 'es-LA', 'esla', 'es-MX', 'es-AR')

_os_quota_warned = False

def os_quota_state():
    today = datetime.now().strftime('%Y-%m-%d')
    try:
        with open(OS_QUOTA_PATH) as f:
            st = json.load(f)
    except Exception:
        st = {}
    if st.get('date') != today:
        st = {'date': today, 'used': 0}
    return st

def os_quota_save(st):
    try:
        tmp = f"{OS_QUOTA_PATH}.tmp"
        with open(tmp, 'w') as f:
            json.dump(st, f)
        os.replace(tmp, OS_QUOTA_PATH)
    except Exception:
        pass

def os_quota_ok():
    global _os_quota_warned
    st = os_quota_state()
    if int(st.get('used', 0)) >= OS_DAILY_LIMIT:
        if not _os_quota_warned:
            log(f"    Cuota OpenSubtitles agotada hoy ({st.get('used')}/{OS_DAILY_LIMIT}); se usan fuentes gratis")
            notify_whatsapp(f"⚠️ Cuota de OpenSubtitles agotada hoy ({OS_DAILY_LIMIT}/día). El resto del día van fuentes gratuitas.")
            _os_quota_warned = True
        return False
    return True

def os_quota_consume():
    st = os_quota_state()
    st['used'] = int(st.get('used', 0)) + 1
    os_quota_save(st)
    log(f"    Cuota OpenSubtitles: {st['used']}/{OS_DAILY_LIMIT} hoy")
    return st['used']

def os_normalize(item):
    a = item.get('attributes', {}) if isinstance(item, dict) else {}
    files = a.get('files') or []
    f0 = files[0] if files and isinstance(files[0], dict) else {}
    fd = a.get('feature_details') or {}
    name = f0.get('file_name') or a.get('release') or ''
    fmt = ''
    if '.' in name:
        cand = name.rsplit('.', 1)[-1].lower()
        if cand in ('srt', 'ass', 'ssa', 'vtt', 'sub', 'txt'):
            fmt = cand
    return {
        'SubFileName': name,
        'SubHearingImpaired': '1' if a.get('hearing_impaired') else '0',
        'hearing_impaired': 'true' if a.get('hearing_impaired') else 'false',
        'SubRating': a.get('ratings') or 0,
        'SubFormat': fmt,
        'file_id': f0.get('file_id'),
        'release_info': a.get('release') or '',
        'release': a.get('release') or '',
        'SeriesSeason': fd.get('season_number'),
        'SeriesEpisode': fd.get('episode_number'),
    }

def os_search_entries(params):
    if not OS_KEY:
        log("    Falta OPENSUBTITLES_COM_KEY, no se puede buscar en OpenSubtitles")
        return []
    try:
        r = requests.get(f"{OS_API}/subtitles", headers=OS_HEADERS, params=params, timeout=20)
    except requests.RequestException as e:
        log(f"    Error OpenSubtitles: {e}")
        return []
    if r.status_code == 401:
        log("    Error OpenSubtitles: API key invalida")
        return []
    if r.status_code != 200:
        log(f"    Error API: {r.status_code} - {r.text[:200]}")
        return []
    try:
        data = r.json()
    except ValueError:
        log("    Error API: JSON invalido")
        return []
    return [os_normalize(it) for it in data.get('data', []) if isinstance(it, dict)]

def to_srt(content):
    if not content or '-->' in content:
        return content
    if '[Script Info]' in content or 'Dialogue:' in content:
        try:
            p = subprocess.run(
                ['docker', 'exec', '-i', 'chae-bazarr', 'ffmpeg', '-y', '-loglevel', 'error',
                 '-f', 'ass', '-i', '-', '-c:s', 'srt', '-f', 'srt', '-'],
                input=content, capture_output=True, text=True, timeout=120)
            if p.returncode == 0 and '-->' in (p.stdout or ''):
                return p.stdout
            log(f"    Error convirtiendo ASS a SRT: {(p.stderr or '')[:200]}")
        except Exception as e:
            log(f"    Error convirtiendo ASS a SRT: {e}")
    return content

def os_download_subtitle(entry):
    file_id = entry.get('file_id') if isinstance(entry, dict) else None
    if not file_id:
        log("    Sin file_id de descarga")
        return None
    if not os_quota_ok():
        return None
    try:
        r = requests.post(f"{OS_API}/download", headers=OS_HEADERS,
                          json={'file_id': file_id}, timeout=30)
    except requests.RequestException as e:
        log(f"    Error descarga: {e}")
        return None
    if r.status_code == 406:
        log(f"    Cuota OpenSubtitles agotada: {r.text[:200]}")
        os_quota_consume()
        return None
    if r.status_code != 200:
        log(f"    Error descarga: {r.status_code} - {r.text[:200]}")
        return None
    try:
        payload = r.json()
    except ValueError:
        log("    Error descarga: JSON invalido")
        return None
    if payload.get('remaining') is not None:
        log(f"    Cuota OpenSubtitles restante hoy: {payload.get('remaining')}")
    link = payload.get('link') or ''
    if not link:
        log("    Sin link de descarga")
        return None
    try:
        dl = requests.get(link, timeout=60, allow_redirects=True)
    except requests.RequestException as e:
        log(f"    Error descarga: {e}")
        return None
    if dl.status_code != 200:
        log(f"    Error descarga: {dl.status_code}")
        return None
    raw = dl.content
    if raw[:2] == b'\x1f\x8b':
        try:
            raw = gzip.decompress(raw)
        except Exception as e:
            log(f"    Error decompressing gzip: {e}")
            return None
    try:
        content = raw.decode('utf-8')
    except UnicodeDecodeError:
        content = raw.decode('latin-1')
    if len(content) < 50:
        log(f"    Contenido muy corto")
        return None
    os_quota_consume()
    return to_srt(content)

def pick_best_sub(entries, prefer_srt=False):
    if not entries:
        return None
    if prefer_srt:
        srt_subs = [e for e in entries if e.get('SubFormat') == 'srt']
        entries = srt_subs or entries
    return max(entries, key=lambda x: float(x.get('SubRating', 0) or 0))

def find_video_file(movie_dir):
    for f in os.listdir(movie_dir):
        if re.search(r'\.(mp4|mkv|avi|m4v)$', f, re.I):
            return f
    return None

def _finalize_srt(content, sub_path, video_path):
    dur = sub_qa.video_duration(video_path) if video_path else None
    qa = sub_qa.qa_subtitle(content, duration=dur)
    if not qa.get('ok'):
        log(f"    QA rechazo el sub ({qa.get('motivo')}); no se guarda")
        return False
    with open(sub_path, 'w', encoding='utf-8') as f:
        f.write(content)
    log(f"    Guardado: {sub_path} (cues={qa.get('cues')} cover={qa.get('cover')})")
    return True

def save_es_sub(content, title, year, movie_dir=None, video_path=None):
    if video_path:
        dir_path = os.path.dirname(video_path)
        base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', os.path.basename(video_path), flags=re.I)
        sub_path = os.path.join(dir_path, f"{base}.es.srt")
        return _finalize_srt(content, sub_path, video_path)
    if not movie_dir:
        movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
    if not os.path.isdir(movie_dir):
        log(f"    Directorio no encontrado: {movie_dir}")
        return False
    video = find_video_file(movie_dir)
    if not video:
        log(f"    No se encontro archivo de video en {movie_dir}")
        return False
    vpath = os.path.join(movie_dir, video)
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', video, flags=re.I)
    sub_path = os.path.join(movie_dir, f"{base}.es.srt")
    return _finalize_srt(content, sub_path, vpath)

def download_opensubtitles_rest(title, year, imdb_id=None):
    """Buscar y descargar subs ES desde OpenSubtitles (api.opensubtitles.com)"""
    if not imdb_id:
        log(f"    Sin IMDB ID, salteando")
        return False
    imdb_num = imdb_id.replace('tt', '')
    log(f"    Buscando en OpenSubtitles (IMDB: {imdb_id})...")
    data = without_hearing_impaired(os_search_entries({
        'imdb_id': imdb_num,
        'languages': OS_LANGS,
        'hearing_impaired': 'exclude',
        'order_by': 'ratings',
        'order_direction': 'desc',
    }))
    if not data:
        log(f"    Sin subs ES en OpenSubtitles")
        return False
    best = pick_best_sub(data)
    log(f"    Descargando: {best.get('SubFileName', '?')} (rating: {best.get('SubRating', '?')})")
    content = os_download_subtitle(best)
    if not content:
        return False
    if save_es_sub(content, title, year):
        log(f"    OK!")
        return True
    return False

def download_english_sub(imdb_id, parent_imdb_id=None, season=None, episode=None):
    """Descargar sub EN desde OpenSubtitles (preferir SRT)"""
    params = {
        'languages': 'en',
        'hearing_impaired': 'exclude',
        'order_by': 'ratings',
        'order_direction': 'desc',
    }
    if parent_imdb_id and season is not None and episode is not None:
        log(f"    Buscando sub EN en OpenSubtitles para S{season}E{episode}...")
        params['parent_imdb_id'] = parent_imdb_id.replace('tt', '')
        params['season_number'] = season
        params['episode_number'] = episode
    elif imdb_id:
        log(f"    Buscando sub EN en OpenSubtitles...")
        params['imdb_id'] = imdb_id.replace('tt', '')
    else:
        return None
    data = without_hearing_impaired(os_search_entries(params))
    if not data:
        log(f"    Sin subs EN en OpenSubtitles")
        return None
    best = pick_best_sub(data, prefer_srt=True)
    log(f"    Descargando EN ({best.get('SubFormat','?')}): {best.get('SubFileName', '?')}")
    return os_download_subtitle(best)

def parse_srt_blocks(content):
    return sub_qa.parse_srt(content)

def translate_with_deepl(srt_content, title, year, movie_dir=None, video_path=None):
    """Traducir SRT a ES (DeepL con fallback Gemini) y guardarlo validado."""
    if video_path:
        movie_dir = os.path.dirname(video_path)
    if not movie_dir:
        movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
    if not video_path and not os.path.isdir(movie_dir):
        log(f"    Directorio no encontrado: {movie_dir}")
        return False

    blocks = sub_qa.parse_srt(srt_content)
    log(f"    Procesando {len(blocks)} bloques SRT para traducir...")
    if not blocks:
        log(f"    No se pudo parsear el SRT")
        return False

    final = subfix.translate_srt(srt_content)
    if not final:
        log(f"    Fallo la traduccion (DeepL y Gemini)")
        return False

    if save_es_sub(final, title, year, movie_dir, video_path=video_path):
        log(f"    Traducido y guardado!")
        return True
    return False

def save_es_sub_episode(content, serie_title, season, episode, sub_path):
    """Guardar sub ES para un episodio en el directorio correcto"""
    if not os.path.isfile(sub_path):
        log(f"    Archivo de video no encontrado: {sub_path}")
        return False
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', os.path.basename(sub_path), flags=re.I)
    dir_path = os.path.dirname(sub_path)
    srt_path = os.path.join(dir_path, f"{base}.es.srt")
    return _finalize_srt(content, srt_path, sub_path)

def load_external_en_sub(video_path):
    if not video_path:
        return None
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', video_path, flags=re.I)
    for cand in (base + '.en.srt', base + '.en.hi.srt', base + '.eng.srt', base + '.en.sdh.srt'):
        if os.path.isfile(cand):
            try:
                with open(cand, encoding='utf-8', errors='replace') as f:
                    content = f.read()
            except Exception:
                continue
            if '-->' in content and len(content) >= 50:
                log(f"    Sub EN externo: {os.path.basename(cand)}")
                return content
    return None

def load_en_sub(video_path):
    return load_external_en_sub(video_path) or extract_embedded_en_sub(video_path)

def whisper_worth_it(video_path, indent='    '):
    """Ultima linea antes de transcribir: si ya hay un sub EN, no transcribir.

    Whisper sobre un medio que ya tiene sub en ingles produce exactamente el
    mismo texto que ya esta en disco, y encima se nota. La FASE C se disparaba
    con `not done`, que tambien es True cuando la traduccion fallo por cuota,
    no solo cuando no habia ningun sub en ingles. Por ahi se gastaban de 25
    minutos a 2 horas de CPU por archivo para terminar con las manos vacias.

    La regla del skill es "whisper solo si no hay ni ES ni ingles"; esta
    funcion la hace cumplir en un solo lugar para que peliculas y series no
    puedan divergir otra vez.
    """
    if load_en_sub(video_path):
        log(f"{indent}hay sub EN pero falta traductor: no transcribo, whisper seria redundante")
        return False
    return True

def extract_embedded_en_sub(video_path):
    """Extraer subtitulo embebido en ingles de un video (via ffmpeg en chae-bazarr)"""
    if not video_path or not os.path.isfile(video_path):
        return None
    container_path = video_path.replace('/mnt/media/', '/media/', 1)
    try:
        probe = subprocess.run(
            ['docker', 'exec', 'chae-bazarr', 'ffprobe', '-v', 'quiet', '-select_streams', 's',
             '-show_entries', 'stream=index:stream_tags=language,title', '-of', 'json', container_path],
            capture_output=True, text=True, timeout=90)
        if probe.returncode != 0:
            return None
        streams = json.loads(probe.stdout or '{}').get('streams', [])
    except Exception as e:
        log(f"    Error ffprobe: {e}")
        return None

    candidates = []
    for i, st in enumerate(streams):
        tags = st.get('tags') or {}
        lang = str(tags.get('language', '')).lower()
        title_tag = str(tags.get('title', '') or '')
        if lang not in ('eng', 'en', 'en-us', 'en-gb', 'enm'):
            continue
        is_hi = bool(re.search(r'\bsdh\b|\bcc\b|\bhi\b|hearing.impaired', title_tag, re.I))
        candidates.append((i, is_hi))
    if not candidates:
        return None

    non_hi = [c for c in candidates if not c[1]]
    stream_idx = (non_hi or candidates)[0][0]

    try:
        ext = subprocess.run(
            ['docker', 'exec', 'chae-bazarr', 'ffmpeg', '-y', '-loglevel', 'error', '-i', container_path,
             '-map', f'0:s:{stream_idx}', '-c:s', 'srt', '-f', 'srt', '-'],
            capture_output=True, text=True, timeout=300)
        if ext.returncode != 0:
            log(f"    Error extrayendo sub embebido: {(ext.stderr or '')[:200]}")
            return None
        content = ext.stdout or ''
        if len(content) < 50 or '-->' not in content:
            return None
        log(f"    Sub EN embebido extraido ({len(content)} chars)")
        return content
    except Exception as e:
        log(f"    Error extrayendo sub embebido: {e}")
        return None

def get_episode_imdb_id(series_title, season, episode):
    key = f"{series_title}|S{season:02d}E{episode:02d}"
    hit, val = cached_imdb(key)
    if hit:
        return val
    try:
        from urllib.parse import quote
        url = f"https://www.omdbapi.com/?apikey={OMDB_API_KEY}&t={quote(series_title)}&season={season}&episode={episode}"
        r = requests.get(url, timeout=10)
        if r.status_code != 200:
            omdb_cache[key] = {'neg': time.time()}
            return None
        data = r.json()
        if data.get('Response') != 'True' or not data.get('imdbID'):
            omdb_cache[key] = {'neg': time.time()}
            return None
        imdb_id = data['imdbID']
        omdb_cache[key] = imdb_id
        return imdb_id
    except Exception as e:
        log(f"    Error OMDb: {e}")
        return None

def download_episode_es_opensubtitles_by_ep_imdb(episode_imdb_id, season, episode, video_path):
    """Buscar y descargar sub ES por IMDB ID del episodio (ej: tt7740568)"""
    if not episode_imdb_id:
        return False
    imdb_num = episode_imdb_id.replace('tt', '')
    log(f"    Buscando en OpenSubtitles por IMDB de episodio ({episode_imdb_id})...")
    data = without_hearing_impaired(os_search_entries({
        'imdb_id': imdb_num,
        'languages': OS_LANGS,
        'hearing_impaired': 'exclude',
        'order_by': 'ratings',
        'order_direction': 'desc',
    }))
    if not data:
        log(f"    Sin subs ES en OpenSubtitles")
        return False
    best = pick_best_sub(data)
    log(f"    Descargando: {best.get('SubFileName', '?')} (rating: {best.get('SubRating', '?')})")
    content = os_download_subtitle(best)
    if not content:
        return False
    return save_es_sub_episode(content, None, season, episode, video_path)

def download_episode_es_opensubtitles(imdb_id, season, episode, video_path):
    """Buscar sub ES para episodio via OpenSubtitles por IMDB de la serie"""
    if not imdb_id:
        return False
    imdb_num = imdb_id.replace('tt', '')
    log(f"    Buscando en OpenSubtitles para S{season}E{episode}...")
    data = without_hearing_impaired(os_search_entries({
        'parent_imdb_id': imdb_num,
        'season_number': season,
        'episode_number': episode,
        'languages': OS_LANGS,
        'hearing_impaired': 'exclude',
        'order_by': 'ratings',
        'order_direction': 'desc',
    }))
    if not data:
        log(f"    Sin sub ES para S{season}E{episode}")
        return False
    best = pick_best_sub(data)
    log(f"    Descargando: {best.get('SubFileName', '?')}")
    content = os_download_subtitle(best)
    if not content:
        return False
    return save_es_sub_episode(content, None, season, episode, video_path)



def sync_or_keep(video_path, label):
    """Para un sub 'desync': primero resincronizar con ffsubsync (lo que hace
    Bazarr+ a mano). Si no alcanza pero el sub está completo y en idioma (lo
    único que falta son créditos), se conserva: no pisarlo con otro descargado.
    Devuelve 'sync' | 'keep' | 'fail'."""
    if subfix.try_sync_es(video_path):
        return 'sync'
    if subfix.keep_if_complete(video_path):
        log(f"    {label}: sub completo; la diferencia es solo al final (créditos/extensión) — se conserva")
        return 'keep'
    return 'fail'


def process_movies():
    log("=== Verificando peliculas ===")
    data = get_json(f"{BAZARR_URL}/api/movies", {"limit": 2000})
    if data is None:
        raise BazarrDown("no se pudo obtener la lista de peliculas")
    movies = data.get('data', [])
    log(f"Total peliculas: {len(movies)}")

    ok = 0
    missing = 0
    downloaded = 0
    kept = 0
    failed = 0

    for movie in movies:
        title = movie.get('title', '?')
        year = movie.get('year', '')
        radarr_id = movie.get('radarrId')
        subs = movie.get('subtitles', [])
        movie_file = movie.get('path', '').replace('/media/', '/mnt/media/', 1)

        trabaja, motivo = needs_work(movie_file, subs)
        if not trabaja:
            ok += 1
            continue

        missing += 1
        if motivo == 'desync':
            log(f"  Sub ES desincronizado, se intenta resincronizar: {title} ({year}) [ID: {radarr_id}]")
            estado = sync_or_keep(movie_file, title)
            if estado == 'sync':
                bazarr_scan_movie(radarr_id)
                downloaded += 1
                time.sleep(PAUSE)
                continue
            if estado == 'keep':
                kept += 1
                time.sleep(PAUSE)
                continue
            log(f"    La resincronización no alcanzó; se intenta reemplazar")
        elif motivo == 'roto':
            log(f"  Sub ES roto, se intenta reemplazar: {title} ({year}) [ID: {radarr_id}]")
        else:
            log(f"  Falta ES: {title} ({year}) [ID: {radarr_id}]")
        imdb_id = movie.get('imdbId', '')
        movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
        done = False

        # ══ FASE A — descargar un sub ES real (lo mejor que haya online) ══
        # 1) Providers de Bazarr (cuenta Bazarr, sin cuota de la app)
        try:
            providers = providers_get(f"{BAZARR_URL}/api/providers/movies?radarrid={radarr_id}")
            available = providers.get('data', [])
        except Exception:
            available = []
        es_available = without_hearing_impaired(
            [s for s in available if isinstance(s, dict) and s.get('language') in ES_CODES2]
        )
        if es_available and try_bazarr_es(
            es_available,
            f"{BAZARR_URL}/api/providers/movies",
            {"radarrid": radarr_id, "forced": "False", "hi": "False", "original_format": "True"},
            movie_file,
        ):
            done = True

        # 2) OpenSubtitles API ES (consume cuota)
        if not PROVIDERS_ONLY and not done and download_opensubtitles_rest(title, year, imdb_id):
            done = True

        # ══ FASE B — traducir del inglés (solo si no había ES descargable) ══
        # 3) Sub EN embebido/externo + traducir (sync perfecto)
        if not PROVIDERS_ONLY and not done:
            en_sub = load_en_sub(movie_file)
            if en_sub and translate_with_deepl(en_sub, title, year, movie_dir):
                done = True

        # 4) Providers de Bazarr en EN + traducir
        if not PROVIDERS_ONLY and not done:
            en_avail = without_hearing_impaired(
                [s for s in available if isinstance(s, dict) and s.get('language') == 'en']
            )
            if en_avail:
                best = max(en_avail, key=lambda x: x.get('score', 0))
                log(f"    Bazarr EN: {best.get('provider')} (score: {best.get('score')})")
                r = api_post(f"{BAZARR_URL}/api/providers/movies", {
                    "radarrid": radarr_id,
                    "forced": "False",
                    "hi": "False",
                    "original_format": "True",
                    "provider": best.get('provider'),
                    "subtitle": best.get('subtitle')
                })
                if r.status_code == 204:
                    time.sleep(2)
                    en_sub = load_en_sub(movie_file)
                    if en_sub and translate_with_deepl(en_sub, title, year, movie_dir):
                        done = True

        # 5) OpenSubtitles API EN + traducir (consume cuota)
        if not PROVIDERS_ONLY and not done:
            log(f"    Sin subs ES descargables. Intentando EN para traducir...")
            en_sub = download_english_sub(imdb_id)
            if en_sub and translate_with_deepl(en_sub, title, year, movie_dir):
                done = True

        # ══ FASE C — whisper (ultima bala) ══
        if not PROVIDERS_ONLY and not done and os.path.isfile(movie_file or ''):
            if whisper_worth_it(movie_file, '    '):
                log(f"    Fallback whisper sobre el audio...")
                ok_w, motivo_w = subfix.repair_file(movie_file, subfix.target_srt_path(movie_file), keep_backup=False)
                if ok_w:
                    done = True
                else:
                    log(f"    whisper: {motivo_w}")

        if done:
            bazarr_scan_movie(radarr_id)
            downloaded += 1
        else:
            log(f"    Agotadas todas las fuentes: no hay subs para {title} ({year})")
            failed += 1
        time.sleep(PAUSE)

    log(f"Resultados: {ok} con ES, {missing} faltaban, {downloaded} descargadas, "
        f"{kept} conservadas (solo créditos), {failed} sin ES")
    return ok, missing, downloaded, failed


def process_series():
    log("=== Verificando series ===")
    data = get_json(f"{BAZARR_URL}/api/series", {"limit": 2000})
    if data is None:
        raise BazarrDown("no se pudo obtener la lista de series")
    series_list = data.get('data', [])
    log(f"Total series en Bazarr: {len(series_list)}")

    total_ok = 0
    total_downloaded = 0
    total_failed = 0

    for serie in series_list:
        title = serie.get('title', '?')
        sid = serie.get('sonarrSeriesId')
        ep_count = serie.get('episodeFileCount', 0)
        imdb_id = serie.get('imdbId', '')
        series_path = serie.get('path', '')
        log(f"  Serie: {title} ({ep_count} episodios, IMDB: {imdb_id})")

        if ep_count == 0:
            log(f"    Sin episodios en disco, salteando")
            continue

        episodes = get_json(f"{BAZARR_URL}/api/episodes", {"seriesid[]": sid})
        eps = episodes.get('data', []) if isinstance(episodes, dict) else []

        if not eps:
            log(f"    No se pudieron obtener episodios")
            continue

        ok = 0
        missing = 0
        downloaded = 0
        kept = 0
        failed = 0

        for ep in eps:
            season = ep.get('season', 0)
            ep_num = ep.get('episode', '?')
            ep_id = ep.get('sonarrEpisodeId') or ep.get('episodeId')
            subs = ep.get('subtitles', [])

            if season == 0:
                continue

            # Map Bazarr path to real filesystem (/media -> /mnt/media)
            ep_path = ep.get('path', '')
            if not ep_path:
                video_path = None
            else:
                video_path = ep_path.replace('/media/', '/mnt/media/', 1)

            trabaja, motivo = needs_work(video_path, subs)
            if not trabaja:
                ok += 1
                continue

            missing += 1
            ep_title = ep.get('title', '?')

            if not video_path or not os.path.isfile(video_path):
                log(f"    S{season}E{ep_num} - Archivo no encontrado: {video_path}, salteando")
                failed += 1
                continue

            if motivo == 'desync':
                log(f"    S{season}E{ep_num} ({ep_title}) - Sub ES desincronizado, se resincroniza")
                estado = sync_or_keep(video_path, f"S{season}E{ep_num}")
                if estado == 'sync':
                    downloaded += 1
                    time.sleep(PAUSE)
                    continue
                if estado == 'keep':
                    kept += 1
                    time.sleep(PAUSE)
                    continue
                log(f"    S{season}E{ep_num} - la resincronización no alcanzó; se reemplaza")
            elif motivo == 'roto':
                log(f"    S{season}E{ep_num} ({ep_title}) - Sub ES roto, se reemplaza")
            else:
                log(f"    S{season}E{ep_num} ({ep_title}) - Falta ES")
            ep_imdb_id = get_episode_imdb_id(title, season, ep_num)
            done = False

            # ══ FASE A — descargar un sub ES real (lo mejor que haya online) ══
            # 1) Providers de Bazarr ES (cuenta Bazarr, sin cuota de la app)
            try:
                providers = providers_get(
                    f"{BAZARR_URL}/api/providers/episodes?episodeid={ep_id}",
                    timeout_sec=60
                )
                available = providers.get('data', [])
            except Exception:
                available = []
            es_avail = without_hearing_impaired(
                [s for s in available if isinstance(s, dict) and s.get('language') in ES_CODES2]
            )
            if es_avail and try_bazarr_es(
                es_avail,
                f"{BAZARR_URL}/api/providers/episodes",
                {"seriesid": sid, "episodeid": ep_id,
                 "forced": "False", "hi": "False", "original_format": "True"},
                video_path,
            ):
                done = True

            # 2) OpenSubtitles API ES (consume cuota)
            if not PROVIDERS_ONLY and not done and download_episode_es_opensubtitles(imdb_id, season, ep_num, video_path):
                done = True

            # 3) OMDb + OpenSubtitles por IMDB del episodio (consume cuota)
            if not PROVIDERS_ONLY and not done and ep_imdb_id and download_episode_es_opensubtitles_by_ep_imdb(
                    ep_imdb_id, season, ep_num, video_path):
                done = True

            # ══ FASE B — traducir del inglés (solo si no había ES descargable) ══
            # 4) Sub EN embebido/externo + traducir (sync perfecto)
            if not PROVIDERS_ONLY and not done and (DEEPL_API_KEY or GEMINI_API_KEY):
                en_sub = load_en_sub(video_path)
                if en_sub and translate_with_deepl(en_sub, title, 0, video_path=video_path):
                    done = True

            # 5) Providers de Bazarr EN + traducir
            if not PROVIDERS_ONLY and not done and (DEEPL_API_KEY or GEMINI_API_KEY):
                en_avail = without_hearing_impaired(
                    [s for s in available if isinstance(s, dict) and s.get('language') == 'en']
                )
                if en_avail:
                    best = max(en_avail, key=lambda x: x.get('score', 0))
                    log(f"      Bazarr EN: {best.get('provider')} (score: {best.get('score')})")
                    r = api_post(f"{BAZARR_URL}/api/providers/episodes", {
                        "seriesid": sid,
                        "episodeid": ep_id,
                        "forced": "False",
                        "hi": "False",
                        "original_format": "True",
                        "provider": best.get('provider'),
                        "subtitle": best.get('subtitle')
                    })
                    if r.status_code == 204:
                        time.sleep(2)
                        en_sub = load_en_sub(video_path)
                        if en_sub and translate_with_deepl(en_sub, title, 0, video_path=video_path):
                            done = True

            # 6) OpenSubtitles API EN + traducir (consume cuota)
            if not PROVIDERS_ONLY and not done and (DEEPL_API_KEY or GEMINI_API_KEY):
                if ep_imdb_id:
                    en_sub = download_english_sub(ep_imdb_id)
                else:
                    en_sub = download_english_sub(None, parent_imdb_id=imdb_id,
                                                  season=season, episode=ep_num)
                if en_sub and translate_with_deepl(en_sub, title, 0, video_path=video_path):
                    done = True

            # ══ FASE C — whisper (ultima bala) ══
            if not PROVIDERS_ONLY and not done:
                if whisper_worth_it(video_path, '      '):
                    log(f"      Fallback whisper sobre el audio...")
                    ok_w, motivo_w = subfix.repair_file(video_path, subfix.target_srt_path(video_path),
                                                        keep_backup=False)
                    if ok_w:
                        done = True
                    else:
                        log(f"      whisper: {motivo_w}")

            if done:
                downloaded += 1
            else:
                log(f"      No disponible en ninguna fuente")
                failed += 1
            time.sleep(PAUSE)

        log(f"    Serie {title}: {ok} con ES, {downloaded} descargados, "
            f"{kept} conservadas (solo créditos), {failed} sin ES")
        if downloaded:
            bazarr_scan_series(sid)
        total_ok += ok
        total_downloaded += downloaded
        total_failed += failed

    log("=== Fin series ===")
    return total_ok, total_downloaded, total_failed


def translate_movie_by_title(title_input):
    """Traducir una pelicula especifica (para /traducir del bot)"""
    load_env(ENV_PATH)
    load_omdb_cache()
    log(f"Buscando pelicula: {title_input}")
    data = get_json(f"{BAZARR_URL}/api/movies", {"limit": 2000})
    movies = data.get('data', []) if isinstance(data, dict) else []
    matches = [m for m in movies if title_input.lower() in m.get('title', '').lower()]
    if not matches:
        log(f"No se encontro pelicula: {title_input}")
        return f"No encontré ninguna película que coincida con \"{title_input}\""
    if len(matches) > 1:
        names = ", ".join(f"{m['title']} ({m.get('year','')})" for m in matches[:5])
        return f"Varias coincidencias: {names}. Sé más específico."

    movie = matches[0]
    title = movie.get('title', '?')
    year = movie.get('year', '')
    imdb_id = movie.get('imdbId', '')
    radarr_id = movie.get('radarrId')
    log(f"Traduciendo: {title} ({year}) [IMDB: {imdb_id}]")

    subs = movie.get('subtitles', [])
    if has_es_subs(subs):
        return f"✅ {title} ({year}) ya tiene subtítulos en español."

    # Download EN and translate
    en_sub = download_english_sub(imdb_id)
    if not en_sub:
        return f"No se pudo descargar subtítulo en inglés para {title} ({year})."

    movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
    if translate_with_deepl(en_sub, title, year, movie_dir):
        # Re-check Bazarr after saving
        time.sleep(2)
        return f"✅ {title} ({year}) traducido al español correctamente."
    else:
        return f"❌ Falló la traducción de {title} ({year})."


def main():
    log("=== INICIO VERIFICACION SUBTITULOS ES ===")
    acquire_lock()
    load_omdb_cache()
    try:
        m_ok, m_missing, m_downloaded, m_failed = process_movies()
        s_ok, s_downloaded, s_failed = process_series()
    except BazarrDown as e:
        msg = f"⚠️ Bazarr no responde ({e}); verificacion de subtitulos abortada"
        log(f"ERROR: {msg}")
        notify_whatsapp(msg)
        sys.exit(2)
    finally:
        save_omdb_cache()
    log("=== FIN ===")

    total_downloaded = m_downloaded + s_downloaded
    total_failed = m_failed + s_failed

    if total_downloaded > 0 or total_failed > 0:
        parts = []
        if total_downloaded > 0:
            parts.append(f"✅ {total_downloaded} sub{'' if total_downloaded == 1 else 's'} descargado{'' if total_downloaded == 1 else 's'}")
        if total_failed > 0:
            parts.append(f"❌ {total_failed} fallaron")
        msg = "📺 " + ", ".join(parts)
        notify_whatsapp(msg)
        log(f"Notificacion enviada: {msg}")
    else:
        log("Sin novedades, no se envia notificacion")


if __name__ == "__main__":
    try:
        if len(sys.argv) > 2 and sys.argv[1] == '--translate-movie':
            result = translate_movie_by_title(' '.join(sys.argv[2:]))
            print(result)
            sys.exit(0)
        main()
    except SystemExit:
        raise
    except Exception:
        logger.exception("Fallo critico en check_es_subs.py")
        notify_whatsapp("❌ check_es_subs.py fallo con excepcion; revisar logs")
        sys.exit(1)
