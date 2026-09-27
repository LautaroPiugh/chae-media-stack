#!/usr/bin/env python3
"""Reparacion de subtitulos ES de maxima calidad via whisper (subgenai) + traduccion."""

import os
import sys
import re
import json
import time
import gzip
import shutil
import tempfile
import uuid
import subprocess

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sub_qa

ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'check_es_subs.env')

WHISPER_URL = os.getenv('WHISPER_URL', 'http://127.0.0.1:9000')
DEEPL_URL = 'https://api-free.deepl.com/v2/translate'
GEMINI_MODELS = [m.strip() for m in os.getenv(
    'GEMINI_MODELS', 'gemini-3.6-flash,gemini-flash-latest'
).split(',') if m.strip()]
GEMINI_URL = 'https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent?key={k}'

FFMPEG_CONTAINER = 'chae-bazarr'
VIDEO_EXTS = ('.mkv', '.mp4', '.avi', '.m4v')

# Whisper `medium` en CPU procesa ~0.5s de audio por segundo de pared, asi que el
# timeout del cliente tiene que escalar con la duracion del medio. Un valor fijo
# de 3600s solo cubre ~30 min de audio: cualquier episodio mas largo fallaba en
# los 3 reintentos, quemando horas de CPU sin entregar nunca un subtitulo.
WHISPER_RATE = float(os.getenv('WHISPER_RATE', '0.5'))
WHISPER_MARGIN = float(os.getenv('WHISPER_MARGIN', '2.2'))
WHISPER_TIMEOUT_FLOOR = int(os.getenv('WHISPER_TIMEOUT_FLOOR', '600'))
WHISPER_TIMEOUT_CEIL = int(os.getenv('WHISPER_TIMEOUT_CEIL', '14400'))


def whisper_timeout(duration_s):
    """Timeout de una request de transcripcion, derivado de la duracion del medio."""
    try:
        dur = float(duration_s or 0)
    except (TypeError, ValueError):
        dur = 0.0
    # NaN no es <= 0 y tampoco escala: sin este chequeo caeria al floor (600s),
    # que es el timeout mas corto posible, justo el peor resultado.
    if dur <= 0 or dur != dur:
        # Duracion desconocida: asumir el peor caso en vez de adivinar corto.
        return WHISPER_TIMEOUT_CEIL
    est = dur / WHISPER_RATE * WHISPER_MARGIN
    return int(min(WHISPER_TIMEOUT_CEIL, max(WHISPER_TIMEOUT_FLOOR, est)))


def load_env(path=None):
    path = path or ENV_PATH
    if not os.path.isfile(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, _, v = line.partition('=')
            os.environ.setdefault(k.strip(), v.strip())


load_env()
DEEPL_API_KEY = os.getenv('DEEPL_API_KEY', '')
GEMINI_API_KEY = os.getenv('GEMINI_API_KEY', '')


def log(msg):
    ts = time.strftime('%H:%M:%S')
    print(f"[{ts}] {msg}", flush=True)


def to_container(path):
    return sub_qa.to_container_path(path)


def extract_audio(video_path, out_path=None):
    cpath = to_container(video_path)
    fd = None
    if out_path:
        tmp = out_path
    else:
        fd, tmp = tempfile.mkstemp(prefix='subwhisper_', suffix='.mp3')
        os.close(fd)
    # mp3 64k mono 16kHz: mismo input que whisper quiere, pero ~4x menos bytes que el
    # wav crudo. Con el wav de 180MB subgen cortaba la conexión (RemoteDisconnected).
    cmd = ['docker', 'exec', FFMPEG_CONTAINER, 'ffmpeg', '-y', '-loglevel', 'error',
           '-i', cpath, '-map', '0:a:0', '-ac', '1', '-ar', '16000',
           '-c:a', 'libmp3lame', '-b:a', '64k', '-f', 'mp3', '-']
    with open(tmp, 'wb') as f:
        p = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, timeout=1200)
    if p.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) < 1000:
        log(f"    ffmpeg audio fallo: {(p.stderr or b'')[:200].decode(errors='replace')}")
        if os.path.isfile(tmp):
            os.remove(tmp)
        return None
    return tmp


def whisper_transcribe(audio_path, language=None, attempts=3, duration_s=None):
    if not os.path.isfile(audio_path):
        return None
    data = {'model': 'whisper-1', 'response_format': 'srt', 'temperature': '0'}
    if language:
        data['language'] = language
    timeout = whisper_timeout(duration_s)
    log(f"    timeout={timeout}s (dur={int(duration_s) if duration_s else '?'}s, "
        f"rate={WHISPER_RATE}, margen={WHISPER_MARGIN}x)")
    for attempt in range(1, attempts + 1):
        try:
            with open(audio_path, 'rb') as f:
                r = requests.post(f"{WHISPER_URL}/v1/audio/transcriptions",
                                  files={'file': (os.path.basename(audio_path), f, 'audio/mpeg')},
                                  data=data, timeout=timeout)
        except requests.RequestException as e:
            log(f"    whisper error (intento {attempt}/{attempts}, timeout={timeout}s): {e}")
            if attempt < attempts:
                time.sleep(min(60, 15 * attempt))
            continue
        if r.status_code in (500, 502, 503, 504, 429):
            log(f"    whisper HTTP {r.status_code} (intento {attempt}/{attempts})")
            if attempt < attempts:
                time.sleep(min(60, 15 * attempt))
            continue
        if r.status_code != 200:
            log(f"    whisper HTTP {r.status_code}: {r.text[:200]}")
            return None
        text = r.text
        if '-->' not in text:
            log(f"    whisper devolvio algo que no es SRT: {text[:120]}")
            return None
        return text
    return None


def _chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def translate_deepl(texts):
    """DeepL acepta un array de textos y devuelve uno por entrada (sin separadores)."""
    if not DEEPL_API_KEY or not texts:
        return None
    try:
        r = requests.post(DEEPL_URL,
                          headers={'Authorization': f'DeepL-Auth-Key {DEEPL_API_KEY}'},
                          json={'text': list(texts), 'target_lang': 'ES', 'preserve_formatting': True},
                          timeout=180)
    except requests.RequestException as e:
        log(f"    DeepL error: {e}")
        return None
    if r.status_code != 200:
        log(f"    DeepL HTTP {r.status_code}: {r.text[:150]}")
        return None
    try:
        translations = r.json().get('translations') or []
    except Exception:
        return None
    parts = [t.get('text', '') for t in translations]
    if len(parts) != len(texts):
        log(f"    DeepL descuadro de segmentos: {len(parts)} != {len(texts)}")
        return None
    parts = [p.strip() for p in parts]
    if any(not p for p in parts):
        log("    DeepL devolvio segmentos vacios")
        return None
    return parts


def translate_gemini(texts):
    if not GEMINI_API_KEY or not texts:
        return None
    prompt = (
        "You are a professional subtitle translator. Translate each subtitle line into "
        "natural neutral Latin American Spanish (use \"usted\" forms, avoid \"vosotros\"). "
        "Keep tone, register and line breaks inside each element. "
        "Return ONLY a JSON array of strings with EXACTLY the same length and order as the input. "
        "Never return empty strings. Do not add notes or commentary.\n\n"
        "Input:\n" + json.dumps(texts, ensure_ascii=False)
    )
    payload = {
        'contents': [{'parts': [{'text': prompt}]}],
        'generationConfig': {
            'temperature': 0.2,
            'responseMimeType': 'application/json',
        },
    }
    for model in GEMINI_MODELS:
        try:
            r = requests.post(GEMINI_URL.format(m=model, k=GEMINI_API_KEY),
                              json=payload, timeout=300)
        except requests.RequestException as e:
            log(f"    Gemini {model} error: {e}")
            continue
        if r.status_code in (404, 403, 503, 500, 502, 429):
            log(f"    Gemini {model} HTTP {r.status_code}; probando el siguiente")
            continue
        if r.status_code != 200:
            log(f"    Gemini {model} HTTP {r.status_code}: {r.text[:150]}")
            continue
        try:
            raw = r.json()['candidates'][0]['content']['parts'][0]['text']
            arr = json.loads(raw)
        except Exception as e:
            log(f"    Gemini {model} respuesta invalida: {e}")
            continue
        if not isinstance(arr, list) or len(arr) != len(texts):
            log(f"    Gemini {model} descuadro: {len(arr) if isinstance(arr, list) else '?'} != {len(texts)}")
            continue
        arr = [str(x).strip() for x in arr]
        if any(not x for x in arr):
            log(f"    Gemini {model} devolvio segmentos vacios")
            continue
        return arr
    return None


def translate_texts(texts):
    out = [''] * len(texts)
    pending = list(range(len(texts)))
    for fn, label, size in ((translate_deepl, 'DeepL', 100),
                            (translate_gemini, 'Gemini', 180)):
        if not pending:
            break
        nxt = []
        for idxs in _chunks(pending, size):
            sample = [texts[i] for i in idxs]
            res = fn(sample)
            if res is None:
                nxt.extend(idxs)
                continue
            for i, t in zip(idxs, res):
                out[i] = t
        if nxt and nxt != pending:
            log(f"    {label}: quedan {len(nxt)} sin traducir, pasa al siguiente motor")
        pending = nxt
    if pending:
        log(f"    sin traductor para {len(pending)} segmentos")
        return None
    return out


# ── Pre-flight de traductores ────────────────────────────────────────────────
# Transcribir cuesta entre 25 min y 2 h de CPU por archivo. Si despues no hay
# traductor, el SRT ingles se tira a la basura. Cuando ambos motores caen por
# cuota (DeepL 456, Gemini 429 "quota"), lo unico que sale de la corrida es una
# factura de CPU. Este probe los descarta antes de gastar la transcripcion.
#
# Falla ABIERTO a proposito: si un motor no se puede sondear con certeza, se
# asume que puede trabajar. Un falso negativo dejaria series sin subtitulo
# cuando el motor si funciona, que es peor que un chequeo de sobra.
PROBE_TEXT = 'hello'
PROBE_TTL = 900  # 15 min de gracia antes de re-sondear un motor marcado muerto


def _probe_cache_file():
    d = os.environ.get('XDG_STATE_HOME') or os.path.join(
        os.path.expanduser('~'), '.local', 'state')
    return os.path.join(d, 'whisper-translator-probe.json')


def _load_probe_cache():
    try:
        with open(_probe_cache_file()) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_probe_cache(data):
    path = _probe_cache_file()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            json.dump(data, f)
    except OSError:
        pass


def _probe_deepl():
    """'alive', 'dead' (cuota agotada) o 'unknown'."""
    if not DEEPL_API_KEY:
        return 'unknown'
    try:
        r = requests.post(DEEPL_URL,
                          headers={'Authorization': f'DeepL-Auth-Key {DEEPL_API_KEY}'},
                          json={'text': [PROBE_TEXT], 'target_lang': 'ES'},
                          timeout=30)
    except requests.RequestException:
        return 'unknown'
    if r.status_code == 200:
        return 'alive'
    if r.status_code == 456:
        return 'dead'
    return 'unknown'


def _probe_gemini():
    """'alive', 'dead' (cuota agotada) o 'unknown'."""
    if not GEMINI_API_KEY:
        return 'unknown'
    for model in GEMINI_MODELS:
        try:
            r = requests.post(GEMINI_URL.format(m=model, k=GEMINI_API_KEY),
                              json={'contents': [{'parts': [{'text': 'di hola'}]}]},
                              timeout=45)
        except requests.RequestException:
            continue
        if r.status_code == 200:
            return 'alive'
        # 429 es ambiguo: "quota" es cuota agotada, "rate limit" es throttling
        # pasajero. Solo el primero justifica dar el motor por muerto.
        if r.status_code == 429 and 'quota' in r.text.lower():
            return 'dead'
    return 'unknown'


def translators_ready():
    """True si algun motor puede traducir. Cachea los caidos para no re-sondear."""
    cache = _load_probe_cache()
    now = time.time()
    procs = {'DeepL': _probe_deepl, 'Gemini': _probe_gemini}
    states = {}
    to_probe = []
    for name, fn in procs.items():
        entry = cache.get(name) or {}
        if now - entry.get('checked_at', 0) < PROBE_TTL:
            states[name] = entry.get('state', 'unknown')
        else:
            to_probe.append(name)
    for name in to_probe:
        state = procs[name]()
        states[name] = state
        cache[name] = {'state': state, 'checked_at': now}
    if to_probe:
        _save_probe_cache(cache)

    alive = [n for n, s in states.items() if s == 'alive']
    dead = [n for n, s in states.items() if s == 'dead']
    unknown = [n for n, s in states.items() if s == 'unknown']
    if dead:
        log(f"    traductores sin cuota: {', '.join(dead)}")
    # Solo se bloquea si TODOS los motores quedaron confirmados muertos. Un
    # 'unknown' cuenta como posible: bloquear ahi dejaria series sin subtitulo
    # por un fallo de red que quizas ni impedia traducir.
    if not alive and not unknown:
        return False
    return True


def translate_srt(content):
    """Traducir SRT a ES conservando timestamps. Devuelve el SRT o None."""
    blocks = sub_qa.parse_srt(content)
    if not blocks:
        return None
    es, en, nwords = sub_qa.word_ratios(content)
    if nwords > 40 and es / max(es + en, 1) >= 0.55:
        return content
    texts = []
    for _, _, body in blocks:
        texts.append('\n'.join(body))
    translated = translate_texts(texts)
    if translated is None:
        return None
    new_blocks = []
    for (idx, ts, body), t in zip(blocks, translated):
        new_blocks.append((idx, ts, t.split('\n')))
    return sub_qa.render_srt(new_blocks)


def find_video_for(srt_path):
    base = re.sub(r'\.(es\.)?(hi\.)?srt$', '', srt_path, flags=re.I)
    for ext in VIDEO_EXTS:
        cand = base + ext
        if os.path.isfile(cand):
            return cand
    d = os.path.dirname(srt_path)
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.lower().endswith(VIDEO_EXTS):
                return os.path.join(d, f)
    return None


def target_srt_path(video_path):
    base = os.path.splitext(os.path.basename(video_path))[0]
    return os.path.join(os.path.dirname(video_path), f"{base}.es.srt")


def repair_file(video_path, srt_path=None, keep_backup=True):
    """Regenerar sub ES desde el audio del video. Devuelve (ok, motivo)."""
    if not video_path or not os.path.isfile(video_path):
        return False, "video no encontrado"
    dest = target_srt_path(video_path)
    dur = sub_qa.video_duration(video_path)
    log(f"  whisper+traducir: {os.path.basename(video_path)} (dur={dur and int(dur)}s)")

    # Si no hay traductor, la transcripcion que sigue no sirve para nada.
    if not translators_ready():
        return False, "sin traductores con cuota (transcripcion evitada)"

    audio = extract_audio(video_path)
    if not audio:
        return False, "no se pudo extraer audio"
    try:
        log(f"    audio extraido ({os.path.getsize(audio) // 1024} KB), transcribiendo...")
        raw = whisper_transcribe(audio, duration_s=dur)
    finally:
        try:
            os.remove(audio)
        except OSError:
            pass
    if not raw:
        return False, "whisper no devolvio SRT"

    es = translate_srt(raw)
    if not es:
        return False, "fallo la traduccion"

    es = trim_past_end(es, dur)

    qa = sub_qa.qa_subtitle(es, duration=dur, tail_ok=60.0)
    if not qa.get('ok'):
        return False, f"QA rechazo: {qa.get('motivo')}"

    if keep_backup:
        for old in (dest, srt_path):
            if old and os.path.isfile(old) and old != dest + '.bak':
                try:
                    shutil.copy2(old, old + '.bak')
                except OSError as e:
                    log(f"    aviso: no se pudo hacer backup: {e}")

    tmp = dest + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(es)
    os.replace(tmp, dest)
    log(f"    guardado: {dest} (cues={qa.get('cues')} cover={qa.get('cover')})")
    return True, "ok"


def trim_past_end(srt_content, duration, grace=15.0):
    if not duration:
        return srt_content
    cutoff = duration + grace
    blocks = sub_qa.parse_srt(srt_content)
    kept = []
    for idx, ts, body in blocks:
        sec = sub_qa.ts_to_sec(ts)
        if sec is None or sec <= cutoff:
            kept.append((idx, ts, body))
    if len(kept) == len(blocks):
        return srt_content
    if len(kept) < 3:
        return srt_content
    return sub_qa.render_srt(kept)


FFSYNC_OFFSET_RE = re.compile(r'offset seconds:\s*(-?\d+(?:\.\d+)?)')
FFSYNC_SCALE_RE = re.compile(r'framerate scale factor:\s*(\d+(?:\.\d+)?)')


def ffsync_metrics(text):
    """(offset_seg, scale) reportados por ffsubsync; (None, None) si no hay log."""
    mo = FFSYNC_OFFSET_RE.search(text or '')
    ms = FFSYNC_SCALE_RE.search(text or '')
    off = float(mo.group(1)) if mo else None
    scale = float(ms.group(1)) if ms else None
    return off, scale


def try_sync_es(video_path, srt_path=None):
    """Re-sincroniza el sidecar ES contra el audio del video con ffsubsync
    (lo mismo que hace Bazarr+ a mano). Devuelve True solo si aplicó un ajuste
    real (offset o escala) Y el resultado pasa el QA de sub_qa.

    Si el sub ya estaba sincronizado (offset ~0 y escala ~1) o el resultado no
    pasa el QA, el archivo original no se toca.
    """
    if not video_path or not os.path.isfile(video_path):
        return False
    srt = srt_path or target_srt_path(video_path)
    if not os.path.isfile(srt):
        return False
    cvid, csrt = to_container(video_path), to_container(srt)
    cout = f'/tmp/ffsubsync-{uuid.uuid4().hex}.srt'
    try:
        p = subprocess.run(
            ['docker', 'exec', FFMPEG_CONTAINER, 'ffsubsync', cvid, '-i', csrt,
             '-o', cout, '--skip-sync-on-low-quality'],
            capture_output=True, text=True, timeout=900)
    except Exception as e:
        log(f"    ffsubsync: {e}")
        return False
    off, scale = ffsync_metrics((p.stdout or '') + (p.stderr or ''))
    try:
        r = subprocess.run(['docker', 'exec', FFMPEG_CONTAINER, 'cat', cout],
                           capture_output=True, text=True, timeout=120)
    except Exception as e:
        log(f"    ffsubsync: no se pudo leer la salida ({e})")
        return False
    finally:
        subprocess.run(['docker', 'exec', FFMPEG_CONTAINER, 'rm', '-f', cout],
                       capture_output=True, timeout=60)
    new = r.stdout or ''
    if p.returncode != 0 or '-->' not in new:
        log(f"    ffsubsync no devolvio SRT (rc={p.returncode}, offset={off})")
        return False
    if ((off is None or abs(off) < 0.5)
            and (scale is None or abs(scale - 1.0) < 0.001)):
        log(f"    ffsubsync: el sub ya estaba sincronizado (offset={off}, scale={scale})")
        return False
    dur = sub_qa.video_duration(video_path)
    qa = sub_qa.qa_subtitle(new, duration=dur)
    if not qa.get('ok'):
        log(f"    ffsubsync: el sub sigue fuera de spec ({qa.get('motivo')}); no se guarda")
        return False
    try:
        shutil.copy2(srt, srt + '.bak')
    except OSError as e:
        log(f"    aviso: no se pudo hacer backup: {e}")
    tmp = srt + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(new)
    os.replace(tmp, srt)
    log(f"    ffsubsync OK: offset={off}s scale={scale} "
        f"(cues={qa.get('cues')} cover={qa.get('cover')})")
    return True


def keep_if_complete(video_path, srt_path=None):
    """True si el sub es diálogo ES completo y lo que falta al final son
    créditos (cover >= sub_qa.KEEP_COVER_OK): en ese caso NO se debe reemplazar."""
    srt = srt_path or target_srt_path(video_path)
    if not os.path.isfile(srt):
        return False
    try:
        with open(srt, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except Exception:
        return False
    if sub_qa.classify_srt(content) not in ('normal', 'sdh'):
        return False
    qa = sub_qa.qa_subtitle(content, video_path=video_path)
    cover = qa.get('cover')
    return bool(cover and cover >= sub_qa.KEEP_COVER_OK)


def has_embedded_es(video_path):
    cpath = to_container(video_path)
    try:
        p = subprocess.run(
            ['docker', 'exec', FFMPEG_CONTAINER, 'ffprobe', '-v', 'quiet',
             '-select_streams', 's', '-show_entries', 'stream_tags=language,title',
             '-of', 'json', cpath],
            capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            return False
        for s in json.loads(p.stdout or '{}').get('streams', []):
            tags = s.get('tags') or {}
            lang = str(tags.get('language', '')).lower()
            title = str(tags.get('title', '') or '').lower()
            if lang in ('spa', 'esp', 'es', 'sp') or 'spanish' in title or 'espanol' in title:
                return True
    except Exception:
        return False
    return False


def library_roots(root):
    root = os.path.abspath(root)
    if os.path.basename(root) == 'media' or root.rstrip('/') == '/mnt/media':
        cand = [os.path.join(root, d) for d in ('movies', 'series', 'anime')]
        return [c for c in cand if os.path.isdir(c)] or [root]
    return [root]


def iter_videos(root):
    for base in library_roots(root):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames
                           if d not in ('@eaDir', '.recycle', 'lost+found',
                                        '$RECYCLE.BIN', 'System Volume Information')]
            for f in sorted(filenames):
                if f.lower().endswith(VIDEO_EXTS):
                    yield os.path.join(dirpath, f)


def es_srt_for(video_path):
    base = os.path.splitext(video_path)[0]
    d = os.path.dirname(video_path)
    stem = os.path.basename(base).lower()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for f in names:
        fl = f.lower()
        if not fl.endswith('.srt'):
            continue
        if not fl.startswith(stem + '.es'):
            continue
        if re.search(r'\.hi\.|\.sdh\.', f, re.I):
            continue
        return os.path.join(d, f)
    return None


def audit(root):
    rows = []
    for video in iter_videos(root):
        srt = es_srt_for(video)
        if not srt:
            if has_embedded_es(video):
                rows.append({'video': video, 'srt': None, 'ok': True,
                             'motivo': 'ES embebido', 'clase': 'ok_embebido'})
                continue
            rows.append({'video': video, 'srt': None, 'ok': False,
                         'motivo': 'sin subtitulos ES', 'clase': 'sin_es'})
            continue
        qa = sub_qa.qa_subtitle_file(srt, video)
        clase = 'ok'
        if not qa.get('ok'):
            m = qa.get('motivo', '')
            if 'vacio' in m:
                clase = 'cues_vacios'
            elif 'largo' in m or 'corto' in m or 'cobertura' in m:
                clase = 'desync'
            elif 'espanol' in m:
                clase = 'idioma'
            else:
                clase = 'otro'
        elif srt.endswith('.es.hi.srt'):
            clase = 'solo_hi'
            qa['ok'] = False
            qa['motivo'] = 'solo track ES-SDH, falta .es.srt'
        rows.append({'video': video, 'srt': srt, 'ok': qa.get('ok'),
                     'motivo': qa.get('motivo') or 'ok', 'clase': clase,
                     'cover': qa.get('cover'), 'cues': qa.get('cues'),
                     'empty': qa.get('empty_n'), 'last': qa.get('last'),
                     'duration': qa.get('duration')})
    return rows


SDH_BRACKET_RE = re.compile(r'[\[\(][^\]\)]*[\]\)]')
SDH_MUSIC_RE = re.compile(r'^\s*[♪♫#>\-–—*~\s]*$')


def clean_sdh_text(line):
    out = SDH_BRACKET_RE.sub('', line)
    out = out.replace('♪', '').strip()
    return out


def clean_sdh_srt(content):
    """Saca los marcadores SDH de un SRT completo.

    Devuelve (srt_limpio, cues_restantes). srt_limpio es None si tras limpiar
    quedan menos de 3 cues (era casi todo sonido, no diálogo).
    """
    blocks = sub_qa.parse_srt(content)
    out_blocks = []
    for idx, ts, body in blocks:
        cleaned = [clean_sdh_text(l) for l in body]
        cleaned = [l for l in cleaned if l and not SDH_MUSIC_RE.match(l)]
        if not cleaned:
            continue
        out_blocks.append((idx, ts, cleaned))
    if len(out_blocks) < 3:
        return None, len(out_blocks)
    return sub_qa.render_srt(out_blocks), len(out_blocks)


def promote_solo_hi(video_path, hi_path=None):
    """Convertir un .es.hi.srt en .es.srt limpiando marcadores SDH."""
    hi_path = hi_path or es_srt_for(video_path)
    if not hi_path or not hi_path.endswith('.es.hi.srt'):
        return False, "no es .es.hi.srt"
    try:
        content = open(hi_path, encoding='utf-8', errors='replace').read()
    except Exception as e:
        return False, str(e)
    blocks = sub_qa.parse_srt(content)
    out_blocks = []
    for idx, ts, body in blocks:
        cleaned = [clean_sdh_text(l) for l in body]
        cleaned = [l for l in cleaned if l and not SDH_MUSIC_RE.match(l)]
        if not cleaned:
            continue
        out_blocks.append((idx, ts, cleaned))
    if len(out_blocks) < 3:
        return False, f"demasiados cues vacios tras limpiar ({len(out_blocks)})"
    new_srt = sub_qa.render_srt(out_blocks)
    dur = sub_qa.video_duration(video_path)
    qa = sub_qa.qa_subtitle(new_srt, duration=dur)
    if not qa.get('ok'):
        return False, f"QA rechazo: {qa.get('motivo')}"
    dest = target_srt_path(video_path)
    if os.path.isfile(dest):
        try:
            shutil.copy2(dest, dest + '.bak')
        except OSError:
            pass
    tmp = dest + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(new_srt)
    os.replace(tmp, dest)
    return True, f"ok ({qa.get('cues')} cues)"


def repair_row(r):
    """Reparación de un item auditado: sync primero si es 'desync', y nunca
    pisar un sub completo cuyo faltante sean créditos. Devuelve (ok, motivo)."""
    srt = r.get('srt') or target_srt_path(r['video'])
    if r.get('clase') == 'desync':
        if try_sync_es(r['video'], srt):
            return True, 'ok (ffsubsync)'
        if keep_if_complete(r['video'], srt):
            return True, 'conservado (diferencia solo al final)'
    return repair_file(r['video'], srt)


def repair_many(rows, jobs=1):
    ok_n = 0
    total = len(rows)
    if jobs <= 1:
        for i, r in enumerate(rows, 1):
            log(f"[{i}/{total}] {r['clase']}: {os.path.relpath(r['video'], '/mnt/media')}")
            ok, motivo = repair_row(r)
            log(f"    -> {'OK' if ok else motivo}")
            ok_n += 1 if ok else 0
            time.sleep(1)
        return ok_n
    from concurrent.futures import ThreadPoolExecutor, as_completed
    log(f"lanzando con {jobs} hilos")
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(repair_row, r): r for r in rows}
        for i, fut in enumerate(as_completed(futs), 1):
            r = futs[fut]
            try:
                ok, motivo = fut.result()
            except Exception as e:
                ok, motivo = False, str(e)
            log(f"[{i}/{total}] {r['clase']} {os.path.basename(r['video'])} -> {'OK' if ok else motivo}")
            ok_n += 1 if ok else 0
    return ok_n


def main():
    if len(sys.argv) < 2:
        print("uso:")
        print("  fix_subs_whisper.py audit <dir>")
        print("  fix_subs_whisper.py repair <video.mkv|.srt>")
        print("  fix_subs_whisper.py sync <video.mkv|.srt>  # ffsubsync (re-sincronizar)")
        print("  fix_subs_whisper.py fix-broken <dir>   # sync/whisper sobre desync/vacios/idioma")
        print("  fix_subs_whisper.py fix-solo-hi <dir>  # .es.hi.srt -> .es.srt (limpio)")
        print("  fix_subs_whisper.py library            # /mnt/media completo")
        sys.exit(2)

    cmd = sys.argv[1]

    if cmd == 'sync':
        target = sys.argv[2]
        if target.lower().endswith('.srt'):
            video = find_video_for(target)
        else:
            video, target = target, es_srt_for(target) or target_srt_path(target)
        ok = try_sync_es(video, target)
        print("OK " if ok else "FALLO ")
        sys.exit(0 if ok else 1)

    if cmd == 'audit':
        root = sys.argv[2] if len(sys.argv) > 2 else '/mnt/media'
        rows = audit(root)
        bad = [r for r in rows if not r['ok']]
        print(f"\n=== AUDITORIA {root} ===")
        print(f"total: {len(rows)}  ok: {len(rows) - len(bad)}  danados: {len(bad)}\n")
        by = {}
        for r in bad:
            by.setdefault(r['clase'], []).append(r)
        for clase, items in sorted(by.items()):
            print(f"-- {clase} ({len(items)}) --")
            for r in items:
                rel = os.path.relpath(r['video'], root)
                print(f"   {rel}")
                print(f"      {r['motivo']}")
        return

    if cmd == 'repair':
        target = sys.argv[2]
        if target.lower().endswith('.srt'):
            video = find_video_for(target)
            ok, motivo = repair_file(video, target)
        else:
            ok, motivo = repair_file(target, es_srt_for(target))
        print(("OK " if ok else "FALLO ") + motivo)
        sys.exit(0 if ok else 1)

    if cmd == 'fix-solo-hi':
        root = sys.argv[2] if len(sys.argv) > 2 else '/mnt/media'
        rows = [r for r in audit(root) if r['clase'] == 'solo_hi']
        log(f"solo_hi: {len(rows)} items")
        ok_n = 0
        for i, r in enumerate(rows, 1):
            ok, motivo = promote_solo_hi(r['video'], r['srt'])
            log(f"[{i}/{len(rows)}] {os.path.relpath(r['video'], root)} -> {motivo}")
            if ok:
                ok_n += 1
        log(f"promovidos {ok_n}/{len(rows)}")
        return

    if cmd in ('fix-broken', 'library'):
        args = sys.argv[2:]
        jobs = 1
        root = '/mnt/media'
        for a in args:
            if a.startswith('--jobs='):
                jobs = int(a.split('=', 1)[1])
            elif not a.startswith('--'):
                root = a
        broken_cls = {'cues_vacios', 'desync', 'idioma', 'otro', 'sin_es'}
        rows = audit(root)
        bad = [r for r in rows if r['clase'] in broken_cls]
        log(f"auditoria {root}: {len(rows)} items, {len(bad)} rotos (whisper)")
        ok_n = repair_many(bad, jobs=jobs)
        log(f"reparados {ok_n}/{len(bad)}")
        if cmd == 'library':
            hi = [r for r in audit(root) if r['clase'] == 'solo_hi']
            log(f"solo_hi para promover: {len(hi)}")
            for i, r in enumerate(hi, 1):
                ok, motivo = promote_solo_hi(r['video'], r['srt'])
                log(f"[{i}/{len(hi)}] {os.path.relpath(r['video'], root)} -> {motivo}")
        rows2 = audit(root)
        bad2 = [r for r in rows2 if r['clase'] in broken_cls or r['clase'] == 'solo_hi']
        log(f"tras reparar: pendientes {len(bad2)} (roto/solo_hi) de {len(rows2)}")
        sys.exit(0 if not bad2 else 1)


if __name__ == '__main__':
    main()
