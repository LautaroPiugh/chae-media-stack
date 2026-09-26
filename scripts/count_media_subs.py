#!/usr/bin/env python3
"""
Recorre las carpetas de media y cuenta los subtitulos (externos .srt/.ass/
.vtt + pistas embebidas via ffprobe) por pelicula y por episodio.

Genera el reporte completo en /home/chae/stack/logs/media-subs-inventory.txt
y imprime por stdout el resumen + los faltantes.

Uso:
    python3 /home/chae/stack/scripts/count_media_subs.py

Notas:
- ffprobe corre dentro del contenedor chae-jellyfin (no hay ffprobe en el host);
  /mnt/media esta montado como /media ahi.
- Un .srt sin sufijo de idioma no cuenta como ES (se lista aparte).
- chae-archive solo se reporta a nivel de conteo: es material de migracion
  (node_modules, skeleton de nextcloud), no biblioteca.
"""

import os
import re
import sys
import subprocess
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sub_qa

MEDIA = '/mnt/media'
LIB_ROOTS = [os.path.join(MEDIA, 'movies'), os.path.join(MEDIA, 'series')]
OTHER_ROOTS = [os.path.join(MEDIA, 'downloads'), os.path.join(MEDIA, 'anime'),
               os.path.join(MEDIA, 'music'), os.path.join(MEDIA, 'backups'),
               os.path.join(MEDIA, 'chae-archive')]
VIDEO_EXT = {'.mkv', '.mp4', '.avi', '.m4v', '.wmv', '.webm'}
SUB_EXT = {'.srt', '.ass', '.ssa', '.vtt'}
JELLYFIN = 'chae-jellyfin'
FFPROBE = '/usr/lib/jellyfin-ffmpeg/ffprobe'
OUT_PATH = '/home/chae/stack/logs/media-subs-inventory.txt'
EP_RE = re.compile(r'[Ss](\d{1,2})[Ee](\d{1,3})')
LANG_TOKEN_RE = re.compile(r'^[a-z]{2,3}(-[a-z]{2,4})?$', re.I)
HI_TOKENS = {'hi', 'sdh', 'cc', 'forced', 'default'}
WORKERS = 6


def is_es(lang):
    """lang en codigo ISO corto/largo (externo o embebido) -> es espanol."""
    l = (lang or '').lower()
    if not l or l == 'und':
        return False
    return l in {'es', 'spa', 'esp', 'ea', 'sp'} or l.startswith('es-') or l.startswith('spa-')


def norm_lang(lang):
    l = (lang or '').lower()
    return 'es' if is_es(l) else (l or 'und')


def walk_videos(root):
    """-> lista de paths de video bajo root."""
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if os.path.splitext(name)[1].lower() in VIDEO_EXT:
                out.append(os.path.join(dirpath, name))
    return sorted(out)


def subs_in_dir(dirpath):
    """-> (dict stem_lower -> [sub paths], total subs en el dir)."""
    by_stem = defaultdict(list)
    total = 0
    for name in os.listdir(dirpath):
        if os.path.splitext(name)[1].lower() not in SUB_EXT:
            continue
        total += 1
        by_stem[os.path.splitext(name)[0].lower()].append(os.path.join(dirpath, name))
    return by_stem, total


def match_subs(video_path, by_stem):
    """Subs cuyo stem es exactamente el del video o el del video + sufijo
    (.lang / .hi...). Tambien evita que E01 captche los subs de E010."""
    stem = os.path.splitext(os.path.basename(video_path))[0].lower()
    hits = []
    for s, paths in by_stem.items():
        if s == stem or s.startswith(stem + '.'):
            hits.extend(paths)
    return sorted(hits)


def parse_ext_langs(video_path, sub_paths):
    """-> (Counter de idiomas normalizados, lista de paths sin id detectado)."""
    stem = os.path.splitext(os.path.basename(video_path))[0]
    langs = Counter()
    unknown = []
    for p in sub_paths:
        raw = os.path.splitext(os.path.basename(p))[0]
        suffix = raw[len(stem):] if raw.lower().startswith(stem.lower()) else raw
        tokens = [t for t in suffix.split('.') if t]
        id_tokens = [t for t in tokens if LANG_TOKEN_RE.match(t) and t.lower() not in HI_TOKENS]
        if id_tokens:
            langs[norm_lang(id_tokens[0])] += 1
        else:
            # .srt sin sufijo: decide por CONTENIDO (igual que check_es_subs),
            # no por nombre — hay Bazarr/OS que guardan ES como .srt a secas.
            lang = 'und'
            try:
                with open(p, encoding='utf-8', errors='replace') as fh:
                    es, en, _nw = sub_qa.word_ratios(fh.read())
                if es + en > 0 and es >= en:
                    lang = 'es'
                elif en > es:
                    lang = 'en'
            except OSError:
                pass
            langs[lang] += 1
            if lang == 'und':
                unknown.append(p)
    return langs, unknown


def probe_container_path(host_path):
    """ffprobe dentro del contenedor Jellyfin -> Counter de idiomas embebidos.
    claves: ISO 639-2 (spa, eng...) o 'und' si la pista no trae tag."""
    cpath = host_path.replace(MEDIA, '/media', 1)
    try:
        r = subprocess.run(
            ['docker', 'exec', JELLYFIN, FFPROBE, '-v', 'error',
             '-select_streams', 's',
             '-show_entries', 'stream_tags=language',
             '-of', 'csv=p=0', cpath],
            capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        return None
    langs = Counter()
    for line in r.stdout.splitlines():
        line = line.strip()
        langs[norm_lang(line) if line else 'und'] += 1
    return langs  # vacio = sin pistas de subtitulo


def fmt_langs(counter):
    if not counter:
        return '-'
    return ', '.join(f'{k}x{v}' if v > 1 else k
                     for k, v in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0])))


def item_label(root, path):
    """Etiqueta legible: serie/season/ep o pelicula."""
    rel = os.path.relpath(path, root)
    d = os.path.dirname(rel)
    base = os.path.splitext(os.path.basename(rel))[0]
    parts = [p for p in d.split(os.sep) if p and p != '.']
    m = EP_RE.search(base)
    ep = f'S{int(m.group(1)):02d}E{int(m.group(2)):02d}' if m else base
    if not parts:
        return ep
    if re.match(r'^Season \d+$', parts[-1], re.I):
        return f'{parts[0]}/{parts[-1]}/{ep}'
    return f'{parts[0]}/{ep}'


def collect_rows():
    """-> (rows_lib, orphan_subs, other_stats).
    row = dict(root, kind, label, video, ext(langs, unknown, files), emb, probe_ok)"""
    rows = []
    orphans = []
    for root in LIB_ROOTS:
        if not os.path.isdir(root):
            continue
        videos = walk_videos(root)
        all_subs = {}
        for dirpath, _d, files in os.walk(root):
            for name in files:
                if os.path.splitext(name)[1].lower() in SUB_EXT:
                    all_subs.setdefault(dirpath, []).append(
                        os.path.join(dirpath, name))
        claimed = set()
        for v in videos:
            d = os.path.dirname(v)
            stem = os.path.splitext(os.path.basename(v))[0].lower()
            matches = []
            for p in all_subs.get(d, []):
                s = os.path.splitext(os.path.basename(p))[0].lower()
                if s == stem or s.startswith(stem + '.'):
                    matches.append(p)
            claimed.update(matches)
            langs, unknown = parse_ext_langs(v, matches)
            kind = 'PELI' if root.endswith('movies') else 'EP'
            rows.append({
                'root': root, 'kind': kind,
                'label': item_label(root, v), 'video': v,
                'ext': langs, 'ext_files': matches, 'ext_unknown': unknown,
                'emb': None, 'probe_ok': True,
            })
        for d, files in all_subs.items():
            for p in files:
                if p not in claimed:
                    orphans.append(p)
    return rows, orphans


def other_stats():
    """Conteo simple (sin ffprobe) de videos/subs fuera de movies/series."""
    stats = {}
    for root in OTHER_ROOTS:
        if not os.path.isdir(root):
            stats[os.path.basename(root)] = (0, 0)
            continue
        nv = ns = 0
        for dirpath, _d, files in os.walk(root):
            for name in files:
                ext = os.path.splitext(name)[1].lower()
                if ext in VIDEO_EXT:
                    nv += 1
                elif ext in SUB_EXT:
                    ns += 1
        stats[os.path.basename(root)] = (nv, ns)
    return stats


def main():
    print(f'[{datetime.now():%H:%M:%S}] escaneando biblioteca (movies+series)...')
    rows, orphans = collect_rows()
    print(f'[{datetime.now():%H:%M:%S}] {len(rows)} videos, {len(orphans)} subs huerfanos. '
          f'Probeando pistas embebidas via contenedor Jellyfin...')

    def _probe(row):
        row['emb'] = probe_container_path(row['video'])
        row['probe_ok'] = row['emb'] is not None
        return row

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        rows = list(ex.map(_probe, rows))

    # ---- derivados ----
    for r in rows:
        ext_n = sum(r['ext'].values())
        emb = r['emb'] if r['probe_ok'] else Counter()
        emb_n = sum(emb.values())
        r['total'] = ext_n + emb_n
        r['has_es'] = any(is_es(k) and v for k, v in r['ext'].items()) or \
                      any(is_es(k) and v for k, v in emb.items())
        r['ext_n'], r['emb_n'] = ext_n, emb_n

    movies = sorted([r for r in rows if r['kind'] == 'PELI'], key=lambda r: r['label'].lower())
    eps = sorted([r for r in rows if r['kind'] == 'EP'], key=lambda r: r['label'].lower())
    ostats = other_stats()

    total_ext = sum(r['ext_n'] for r in rows)
    total_emb = sum(r['emb_n'] for r in rows)
    no_es = [r for r in rows if not r['has_es']]
    zero = [r for r in rows if r['total'] == 0]
    probe_fail = [r for r in rows if not r['probe_ok']]
    ext_dist = Counter(r['ext_n'] for r in rows)
    emb_dist = Counter(r['emb_n'] for r in rows)
    ext_lang_totals = Counter()
    emb_lang_totals = Counter()
    for r in rows:
        ext_lang_totals.update(r['ext'])
        if r['probe_ok']:
            emb_lang_totals.update(r['emb'])

    # ---- reporte completo ----
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, 'w') as f:
        f.write(f'# Inventario de subtitulos — {datetime.now():%Y-%m-%d %H:%M:%S}\n')
        f.write(f'# Biblioteca: {len(movies)} peliculas, {len(eps)} episodios\n')
        f.write(f'# Externos: {total_ext} | Embebidos: {total_emb} | '
                f'Sin ES: {len(no_es)} | Sin ninguno: {len(zero)}\n\n')

        for title, group in (('== PELICULAS ==', movies), ('== EPISODIOS ==', eps)):
            f.write(f'{title}\n')
            for r in group:
                flag = 'SIN-SUBS' if r['total'] == 0 else ('OK ' if r['has_es'] else 'FALTA-ES')
                pb = '' if r['probe_ok'] else '  (ffprobe falló)'
                f.write(f'[{flag}] {r["label"]}\n'
                        f'    ext({r["ext_n"]}): {fmt_langs(r["ext"])}{pb}\n'
                        f'    emb({r["emb_n"]}): '
                        f'{fmt_langs(r["emb"] if r["probe_ok"] else None)}\n')

        if orphans:
            f.write('\n== SUBS HUERFANOS (sin video que los matchee) ==\n')
            for p in sorted(orphans):
                f.write(f'{p}\n')

        f.write('\n== OTRAS CARPETAS DE /mnt/media (conteo simple) ==\n')
        for name, (nv, ns) in ostats.items():
            f.write(f'{name}: {nv} videos, {ns} subs\n')

    # ---- resumen stdout ----
    print()
    print('=' * 64)
    print(f'INVENTARIO DE SUBTITULOS  ({datetime.now():%Y-%m-%d %H:%M})')
    print('=' * 64)
    print(f'Biblioteca : {len(movies)} peliculas + {len(eps)} episodios '
          f'({len(rows)} videos)')
    print(f'Externos   : {total_ext} archivos  [{fmt_langs(ext_lang_totals)}]')
    print(f'Embebidos  : {total_emb} pistas    [{fmt_langs(emb_lang_totals)}]')
    print('Distrib. ext por item: ' +
          ', '.join(f'{k}={v}' for k, v in sorted(ext_dist.items())))
    print('Distrib. emb por item: ' +
          ', '.join(f'{k}={v}' for k, v in sorted(emb_dist.items())))

    shows = defaultdict(lambda: [0, 0])
    for r in eps:
        show = r['label'].split('/')[0]
        shows[show][0] += 1
        if r['has_es']:
            shows[show][1] += 1
    print('\nPor serie (episodios con ES / total):')
    for show, (n, nes) in sorted(shows.items()):
        status = 'OK' if nes == n else f'FALTAN {n - nes}'
        print(f'  {show:<22} {nes:>3}/{n:<3}  {status}')

    mv_es = sum(1 for r in movies if r['has_es'])
    print(f'\nPeliculas con ES: {mv_es}/{len(movies)}')

    if no_es:
        print(f'\n--- SIN ESPAÑOL ({len(no_es)}) ---')
        for r in no_es:
            print(f'  [{r["kind"]}] {r["label"]}  ext={fmt_langs(r["ext"])} '
                  f'emb={fmt_langs(r["emb"] if r["probe_ok"] else None)}')
    if zero:
        print(f'\n--- SIN NINGUN SUBTITULO ({len(zero)}) ---')
        for r in zero:
            print(f'  [{r["kind"]}] {r["label"]}')
    if orphans:
        print(f'\n--- SUBS HUERFANOS ({len(orphans)}) ---')
        for p in sorted(orphans):
            print(f'  {p}')
    if probe_fail:
        print(f'\n--- FFPROBE FALLÓ ({len(probe_fail)}) ---')
        for r in probe_fail:
            print(f'  {r["video"]}')

    print('\nOtras carpetas de /mnt/media (no biblioteca):')
    for name, (nv, ns) in ostats.items():
        print(f'  {name:<16} {nv:>4} videos, {ns:>3} subs')

    print(f'\nReporte completo: {OUT_PATH}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
