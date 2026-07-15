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
from datetime import datetime

ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'check_es_subs.env')

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

def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

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
    r = requests.get(url, headers=HEADERS, params=params, timeout=timeout)
    return r.json() if r.status_code == 200 else {}

def api_post(base, params):
    r = requests.post(base, headers=HEADERS, params=params, timeout=30)
    return r

def api_patch(base, params):
    r = requests.patch(base, headers=HEADERS, params=params, timeout=30)
    return r

def providers_get(url, timeout_sec=15):
    r = requests.get(url, headers=HEADERS, timeout=timeout_sec)
    return r.json() if r.status_code == 200 else {}

MEDIA_MOVIES = '/mnt/media/movies'
DEEPL_API_KEY = os.getenv('DEEPL_API_KEY', '')
OMDB_API_KEY = os.getenv('OMDB_API_KEY', '')
OMDB_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'omdb_cache.json')
omdb_cache = {}

def load_omdb_cache():
    global omdb_cache
    if os.path.isfile(OMDB_CACHE_PATH):
        try:
            with open(OMDB_CACHE_PATH) as f:
                omdb_cache = json.load(f)
            log(f"Cargados {len(omdb_cache)} items del cache OMDb")
        except Exception:
            omdb_cache = {}

def save_omdb_cache():
    try:
        with open(OMDB_CACHE_PATH, 'w') as f:
            json.dump(omdb_cache, f, indent=2)
        log(f"Cache OMDb guardado ({len(omdb_cache)} items)")
    except Exception as e:
        log(f"Error guardando cache OMDb: {e}")

def has_es_subs(subtitles):
    if not subtitles:
        return False
    return any(s.get('code2') in ('es', 'ea', 'sp') for s in subtitles)

def find_video_file(movie_dir):
    for f in os.listdir(movie_dir):
        if re.search(r'\.(mp4|mkv|avi|m4v)$', f, re.I):
            return f
    return None

def save_es_sub(content, title, year, movie_dir=None):
    if not movie_dir:
        movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
    if not os.path.isdir(movie_dir):
        log(f"    Directorio no encontrado: {movie_dir}")
        return False
    video = find_video_file(movie_dir)
    if not video:
        log(f"    No se encontro archivo de video en {movie_dir}")
        return False
    base = re.sub(r'\.(mp4|mkv|avi|m4v)$', '', video, flags=re.I)
    sub_path = os.path.join(movie_dir, f"{base}.es.srt")
    with open(sub_path, 'w', encoding='utf-8') as f:
        f.write(content)
    log(f"    Guardado: {sub_path}")
    return True

def download_opensubtitles_rest(title, year, imdb_id=None):
    """Buscar y descargar subs ES desde OpenSubtitles REST API (legacy)"""
    if not imdb_id:
        log(f"    Sin IMDB ID, salteando")
        return False
    imdb_num = imdb_id.replace('tt', '')
    log(f"    Buscando en OpenSubtitles REST API (IMDB: {imdb_id})...")
    try:
        url = f"https://rest.opensubtitles.org/search/imdbid-{imdb_num}/sublanguageid-spa"
        r = requests.get(url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=10)
        if r.status_code != 200:
            log(f"    Error API: {r.status_code}")
            return False
        data = r.json()
        if not data or len(data) == 0:
            log(f"    Sin subs ES en OpenSubtitles")
            return False
        best = max(data, key=lambda x: float(x.get('SubRating', 0) or 0))
        dl_url = best.get('SubDownloadLink', '')
        if not dl_url:
            log(f"    Sin link de descarga")
            return False
        log(f"    Descargando: {best.get('SubFileName', '?')} (rating: {best.get('SubRating', '?')})")
        dl = requests.get(dl_url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=15, allow_redirects=True)
        if dl.status_code != 200:
            log(f"    Error descarga: {dl.status_code}")
            return False
        raw = dl.content
        if raw[:2] == b'\x1f\x8b':
            try:
                raw = gzip.decompress(raw)
            except Exception as e:
                log(f"    Error decompressing gzip: {e}")
                return False
        try:
            content = raw.decode('utf-8')
        except UnicodeDecodeError:
            content = raw.decode('latin-1')
        if len(content) < 50:
            log(f"    Contenido muy corto")
            return False
        if save_es_sub(content, title, year):
            log(f"    OK!")
            return True
    except Exception as e:
        log(f"    Error OpenSubtitles REST: {e}")
    return False

def download_english_sub(imdb_id):
    """Descargar sub EN desde OpenSubtitles REST API (preferir SRT)"""
    if not imdb_id:
        return None
    imdb_num = imdb_id.replace('tt', '')
    log(f"    Buscando sub EN en OpenSubtitles...")
    try:
        url = f"https://rest.opensubtitles.org/search/imdbid-{imdb_num}/sublanguageid-eng"
        r = requests.get(url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=10)
        if r.status_code != 200:
            return None
        data = r.json()
        if not data:
            log(f"    Sin subs EN en OpenSubtitles")
            return None
        srt_subs = [s for s in data if s.get('SubFormat') == 'srt']
        candidates = srt_subs if srt_subs else data
        best = max(candidates, key=lambda x: float(x.get('SubRating', 0) or 0))
        dl_url = best.get('SubDownloadLink', '')
        if not dl_url:
            return None
        log(f"    Descargando EN ({best.get('SubFormat','?')}): {best.get('SubFileName', '?')}")
        dl = requests.get(dl_url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=15, allow_redirects=True)
        if dl.status_code != 200:
            return None
        raw = dl.content
        if raw[:2] == b'\x1f\x8b':
            raw = gzip.decompress(raw)
        try:
            content = raw.decode('utf-8')
        except UnicodeDecodeError:
            content = raw.decode('latin-1')
        if len(content) < 50:
            return None
        return content
    except Exception as e:
        log(f"    Error descarga EN: {e}")
    return None

def parse_srt_blocks(content):
    """Parsear SRT en (index, timestamp, text) tuples, tolerando formatos no estandar"""
    text = content.strip()
    blocks = []
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if re.match(r'^\d+$', line):
            idx = line
            i += 1
            if i >= len(lines):
                break
            ts = lines[i].strip()
            i += 1
            text_lines = []
            while i < len(lines):
                l = lines[i].strip()
                if re.match(r'^\d+$', l) and i + 1 < len(lines) and '-->' in lines[i + 1]:
                    break
                if l == '':
                    i += 1
                    continue
                text_lines.append(l)
                i += 1
            if text_lines and '-->' in ts:
                blocks.append((idx, ts, text_lines))
        else:
            i += 1
    return blocks

def translate_with_deepl(srt_content, title, year, movie_dir=None):
    """Traducir SRT de EN a ES via DeepL API"""
    if not movie_dir:
        movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
    if not os.path.isdir(movie_dir):
        log(f"    Directorio no encontrado: {movie_dir}")
        return False

    blocks = parse_srt_blocks(srt_content)
    log(f"    Procesando {len(blocks)} bloques SRT para traducir...")

    if not blocks:
        log(f"    No se pudo parsear el SRT")
        return False

    text_lines = ['\n'.join(t) for _, _, t in blocks]
    total = sum(len(t) for t in text_lines)
    log(f"    {len(blocks)} bloques, {total} chars a traducir")

    separator = '\n---|||---\n'
    joined = separator.join(text_lines)

    DEEPL_CHUNK = 120000
    if len(joined) > DEEPL_CHUNK:
        log(f"    Texto grande, dividiendo en partes...")
        parts = []
        current = []
        current_len = 0
        for t in text_lines:
            tl = len(t) + len(separator)
            if current_len + tl > DEEPL_CHUNK and current:
                parts.append(separator.join(current))
                current = [t]
                current_len = len(t)
            else:
                current.append(t)
                current_len += tl
        if current:
            parts.append(separator.join(current))
    else:
        parts = [joined]

    all_translated = []
    separators_used = 0

    for pi, part in enumerate(parts):
        log(f"    Traduciendo parte {pi + 1}/{len(parts)}...")
        try:
            r = requests.post('https://api-free.deepl.com/v2/translate',
                headers={'Authorization': f'DeepL-Auth-Key {DEEPL_API_KEY}'},
                json={
                    'text': [part],
                    'target_lang': 'ES'
                },
                timeout=120)
            if r.status_code != 200:
                log(f"    Error DeepL: {r.status_code} - {r.text[:200]}")
                return False
            result = r.json()
            translated = result.get('translations', [{}])[0].get('text', '')
            if not translated:
                log(f"    Respuesta DeepL vacia")
                return False
            all_translated.append(translated)
        except Exception as e:
            log(f"    Error llamando DeepL: {e}")
            return False

    translated_full = separator.join(all_translated)
    translated_lines = translated_full.split(separator)

    if len(translated_lines) != len(text_lines):
        log(f"    Advertencia: DeepL devolvio {len(translated_lines)} segmentos, esperaba {len(text_lines)}")
        if len(translated_lines) < len(text_lines):
            translated_lines += [''] * (len(text_lines) - len(translated_lines))
        else:
            translated_lines = translated_lines[:len(text_lines)]

    output = []
    for (idx, ts, _), text in zip(blocks, translated_lines):
        output.append(idx)
        output.append(ts)
        output.append(text.strip())

    final = '\n'.join(output)
    if save_es_sub(final, title, year, movie_dir):
        log(f"    Traducido y guardado via DeepL!")
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
    with open(srt_path, 'w', encoding='utf-8') as f:
        f.write(content)
    log(f"    Guardado: {srt_path}")
    return True

OS_CACHE = {}

def get_episode_imdb_id(series_title, season, episode):
    key = f"{series_title}|S{season:02d}E{episode:02d}"
    if key in omdb_cache:
        return omdb_cache[key]
    try:
        from urllib.parse import quote
        url = f"http://www.omdbapi.com/?apikey={OMDB_API_KEY}&t={quote(series_title)}&season={season}&episode={episode}"
        r = requests.get(url, timeout=10)
        if r.status_code != 200:
            omdb_cache[key] = None
            save_omdb_cache()
            return None
        data = r.json()
        if data.get('Response') != 'True' or not data.get('imdbID'):
            omdb_cache[key] = None
            save_omdb_cache()
            return None
        imdb_id = data['imdbID']
        omdb_cache[key] = imdb_id
        save_omdb_cache()
        return imdb_id
    except Exception as e:
        log(f"    Error OMDb: {e}")
        omdb_cache[key] = None
        save_omdb_cache()
        return None

def download_episode_es_opensubtitles_by_ep_imdb(episode_imdb_id, season, episode, video_path):
    """Buscar y descargar sub ES por IMDB ID del episodio (ej: tt7740568)"""
    imdb_num = episode_imdb_id.replace('tt', '')
    log(f"    Buscando en OpenSubtitles por IMDB de episodio ({episode_imdb_id})...")
    try:
        url = f"https://rest.opensubtitles.org/search/imdbid-{imdb_num}/sublanguageid-spa"
        r = requests.get(url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=10)
        if r.status_code != 200:
            log(f"    Error API: {r.status_code}")
            return False
        data = r.json()
        if not data:
            log(f"    Sin subs ES en OpenSubtitles")
            return False
        best = max(data, key=lambda x: float(x.get('SubRating', 0) or 0))
        dl_url = best.get('SubDownloadLink', '')
        if not dl_url:
            log(f"    Sin link de descarga")
            return False
        log(f"    Descargando: {best.get('SubFileName', '?')} (rating: {best.get('SubRating', '?')})")
        dl = requests.get(dl_url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=15, allow_redirects=True)
        if dl.status_code != 200:
            log(f"    Error descarga: {dl.status_code}")
            return False
        raw = dl.content
        if raw[:2] == b'\x1f\x8b':
            try:
                raw = gzip.decompress(raw)
            except Exception:
                return False
        try:
            content = raw.decode('utf-8')
        except UnicodeDecodeError:
            content = raw.decode('latin-1')
        if len(content) < 50:
            return False
        return save_es_sub_episode(content, None, season, episode, video_path)
    except Exception as e:
        log(f"    Error OpenSubtitles: {e}")
    return False

def download_episode_es_opensubtitles(imdb_id, season, episode, video_path):
    """Buscar sub ES para episodio via OpenSubtitles REST API por IMDB de la serie"""
    imdb_num = imdb_id.replace('tt', '')
    log(f"    Buscando en OpenSubtitles para S{season}E{episode}...")
    try:
        if imdb_id not in OS_CACHE:
            url = f"https://rest.opensubtitles.org/search/imdbid-{imdb_num}/sublanguageid-spa"
            r = requests.get(url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=10)
            if r.status_code != 200:
                log(f"    Error API: {r.status_code}")
                return False
            data = r.json()
            if not data:
                log(f"    Sin resultados en OpenSubtitles")
                OS_CACHE[imdb_id] = []
                return False
            OS_CACHE[imdb_id] = data
        else:
            data = OS_CACHE[imdb_id]

        if not data:
            log(f"    Sin sub ES para S{season}E{episode}")
            return False
        matching = [d for d in data
                    if str(d.get('SeriesSeason')) == str(season)
                    and str(d.get('SeriesEpisode')) == str(episode)]
        if not matching:
            log(f"    Sin sub ES para S{season}E{episode}")
            return False
        best = max(matching, key=lambda x: float(x.get('SubRating', 0) or 0))
        dl_url = best.get('SubDownloadLink', '')
        if not dl_url:
            return False
        log(f"    Descargando: {best.get('SubFileName', '?')}")
        dl = requests.get(dl_url, headers={'User-Agent': 'SubDownloader 2.0.1'}, timeout=60, allow_redirects=True)
        if dl.status_code != 200:
            log(f"    Error descarga: {dl.status_code}")
            return False
        raw = dl.content
        if raw[:2] == b'\x1f\x8b':
            try:
                raw = gzip.decompress(raw)
            except Exception:
                return False
        try:
            content = raw.decode('utf-8')
        except UnicodeDecodeError:
            content = raw.decode('latin-1')
        if len(content) < 50:
            return False
        return save_es_sub_episode(content, None, season, episode, video_path)
    except Exception as e:
        log(f"    Error OpenSubtitles: {e}")
    return False

def process_movies():
    log("=== Verificando peliculas ===")
    data = get_json(f"{BAZARR_URL}/api/movies?limit=500")
    movies = data.get('data', [])
    log(f"Total peliculas: {len(movies)}")

    ok = 0
    missing = 0
    downloaded = 0
    failed = 0

    for movie in movies:
        title = movie.get('title', '?')
        year = movie.get('year', '')
        radarr_id = movie.get('radarrId')
        subs = movie.get('subtitles', [])

        if has_es_subs(subs):
            ok += 1
            continue

        missing += 1
        log(f"  Falta ES: {title} ({year}) [ID: {radarr_id}]")

        # 1) Intentar con providers de Bazarr
        try:
            providers = providers_get(f"{BAZARR_URL}/api/providers/movies?radarrid={radarr_id}")
            available = providers.get('data', [])
        except Exception:
            available = []
        es_available = [s for s in available if isinstance(s, dict) and s.get('language') == 'es']

        if es_available:
            best = max(es_available, key=lambda x: x.get('score', 0))
            log(f"    Bazarr: {best.get('provider')} (score: {best.get('score')})")
            r = api_post(f"{BAZARR_URL}/api/providers/movies", {
                "radarrid": radarr_id,
                "forced": "False",
                "hi": "False",
                "original_format": "True",
                "provider": best.get('provider'),
                "subtitle": best.get('subtitle')
            })
            if r.status_code == 204:
                log(f"    OK!")
                downloaded += 1
                time.sleep(PAUSE)
                continue
            log(f"    Error descarga Bazarr: {r.status_code}")

        # 2) Fallback: OpenSubtitles REST API (ES)
        imdb_id = movie.get('imdbId', '')
        if download_opensubtitles_rest(title, year, imdb_id):
            downloaded += 1
            time.sleep(PAUSE)
            continue

        # 3) Fallback: descargar EN y traducir con DeepL
        log(f"    Sin subs ES. Intentando descargar EN y traducir con DeepL...")
        en_sub = download_english_sub(imdb_id)
        if en_sub:
            movie_dir = os.path.join(MEDIA_MOVIES, f"{title} ({year})")
            if translate_with_deepl(en_sub, title, year, movie_dir):
                downloaded += 1
                time.sleep(PAUSE)
                continue

        log(f"    Agotadas todas las fuentes: no hay subs para {title} ({year})")
        failed += 1
        time.sleep(PAUSE)

    log(f"Resultados: {ok} con ES, {missing} faltaban, {downloaded} descargadas, {failed} sin ES")
    return ok, missing, downloaded, failed


def process_series():
    log("=== Verificando series ===")
    data = get_json(f"{BAZARR_URL}/api/series?limit=100")
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
        eps = episodes.get('data', [])

        if not eps:
            log(f"    No se pudieron obtener episodios")
            continue

        ok = 0
        missing = 0
        downloaded = 0
        failed = 0

        for ep in eps:
            season = ep.get('season', 0)
            ep_num = ep.get('episode', '?')
            ep_id = ep.get('sonarrEpisodeId') or ep.get('episodeId')
            subs = ep.get('subtitles', [])

            if season == 0:
                continue

            if has_es_subs(subs):
                ok += 1
                continue

            missing += 1
            ep_title = ep.get('title', '?')

            # Map Bazarr path to real filesystem (/media -> /mnt/media)
            ep_path = ep.get('path', '')
            if not ep_path:
                video_path = None
            else:
                video_path = ep_path.replace('/media/', '/mnt/media/', 1)

            if not video_path or not os.path.isfile(video_path):
                log(f"    S{season}E{ep_num} - Archivo no encontrado: {video_path}, salteando")
                failed += 1
                continue

            log(f"    S{season}E{ep_num} ({ep_title}) - Falta ES")

            # 1) Probar OpenSubtitles primero (rapido)
            if download_episode_es_opensubtitles(imdb_id, season, ep_num, video_path):
                downloaded += 1
                time.sleep(PAUSE)
                continue

            # 1.5) OMDb + OpenSubtitles por IMDB ID del episodio
            ep_imdb_id = get_episode_imdb_id(title, season, ep_num)
            if ep_imdb_id and download_episode_es_opensubtitles_by_ep_imdb(ep_imdb_id, season, ep_num, video_path):
                downloaded += 1
                time.sleep(PAUSE)
                continue

            # 2) Fallback: providers de Bazarr
            try:
                providers = providers_get(
                    f"{BAZARR_URL}/api/providers/episodes?episodeid={ep_id}",
                    timeout_sec=15
                )
                available = providers.get('data', [])
            except Exception:
                available = []
            es_avail = [s for s in available if isinstance(s, dict) and s.get('language') in ('es', 'ea', 'sp')]

            if es_avail:
                best = max(es_avail, key=lambda x: x.get('score', 0))
                log(f"      Bazarr: {best.get('provider')} (score: {best.get('score')})")
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
                    log(f"      OK!")
                    downloaded += 1
                    time.sleep(PAUSE)
                    continue
                log(f"      Error descarga Bazarr: {r.status_code}")

            log(f"      No disponible en ninguna fuente")
            failed += 1
            time.sleep(PAUSE)

        log(f"    Serie {title}: {ok} con ES, {downloaded} descargados, {failed} sin ES")
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
    data = get_json(f"{BAZARR_URL}/api/movies?limit=500")
    movies = data.get('data', [])
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
    load_omdb_cache()
    m_ok, m_missing, m_downloaded, m_failed = process_movies()
    s_ok, s_downloaded, s_failed = process_series()
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
    import sys
    if len(sys.argv) > 2 and sys.argv[1] == '--translate-movie':
        result = translate_movie_by_title(' '.join(sys.argv[2:]))
        print(result)
        sys.exit(0)
    main()
