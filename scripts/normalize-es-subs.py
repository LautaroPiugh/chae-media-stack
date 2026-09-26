#!/usr/bin/env python3
"""Normaliza los sidecar ES y deja a Bazarr sincronizado con el disco.

Política de subtítulos: español/español latam normales, nunca SDH/HI/CC.

Qué hace:
  1. borra los *.es*.hi.srt / *.sdh. (SDH — la política los prohíbe)
  2. renombra las variantes (.es-MX.srt, .es-ES.srt, .esla.srt…) a .es.srt
     canonical. Importante: Bazarr detecta .es-MX.srt como 'ea' (Spanish
     Latino) y el perfil de idioma pide 'es', así que los deja en "wanted"
     aunque el sub esté. Con .es.srt los da por cubiertos.
  3. le pide a Bazarr un scan-disk de todas las películas y series para que
     refresque su lista de wanted.

Uso:
  python3 normalize-es-subs.py            # normaliza + rescan
  python3 normalize-es-subs.py --dry-run  # solo muestra qué haría
"""
import json
import os
import re
import sys
import urllib.request

ROOTS = ['/mnt/media/movies', '/mnt/media/series', '/mnt/media/anime']
HI_RE = re.compile(r'\.hi\.|\.sdh\.', re.I)
# cualquier sidecar .srt con marca de español (incluye .es-MX.hi.srt, .spa.srt…)
VARIANT_RE = re.compile(r'\.(es|spa|esp)', re.I)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_es_subs as ces

DRY = '--dry-run' in sys.argv


def log(msg):
    print(msg, flush=True)


def canonical_target(path):
    """{base}.es-MX.srt -> {base}.es.srt"""
    base = re.sub(r'\.(es|spa|esp)[a-z0-9\-]*\.srt$', '', path, flags=re.I)
    return base + '.es.srt'


def main():
    removed = renamed = kept = collisions = 0
    hi_list, rename_list = [], []

    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            for f in sorted(fn):
                if not f.lower().endswith('.srt'):
                    continue
                path = os.path.join(dp, f)
                if not VARIANT_RE.search(f):
                    continue
                if HI_RE.search(f):
                    removed += 1
                    hi_list.append(os.path.relpath(path, '/mnt/media'))
                    if not DRY:
                        os.remove(path)
                    continue
                # ya es el nombre canónico .es.srt -> nada que hacer
                if re.search(r'\.es\.srt$', f, re.I):
                    kept += 1
                    continue
                target = canonical_target(path)
                if os.path.exists(target):
                    # ya hay un .es.srt: se conserva el canónico y se dropea la variante
                    collisions += 1
                    removed += 1
                    hi_list.append(os.path.relpath(path, '/mnt/media') + '  (duplicado, ya existe .es.srt)')
                    if not DRY:
                        os.remove(path)
                    continue
                renamed += 1
                rename_list.append((os.path.relpath(path, '/mnt/media'),
                                    os.path.relpath(target, '/mnt/media')))
                if not DRY:
                    os.rename(path, target)

    log(f"SDH/HI o duplicados eliminados: {removed}")
    for h in hi_list:
        log(f"   - {h}")
    log(f"variantes renombradas a .es.srt: {renamed}")
    for a, b in rename_list[:40]:
        log(f"   {a}  ->  {b}")
    log(f".es.srt canónicos ya en su sitio: {kept}")

    if DRY:
        log("(dry-run: no se tocó nada ni se avisó a Bazarr)")
        return

    # ── avisarle a Bazarr que relea el disco ──
    log("")
    log("Avisando a Bazarr (scan-disk de películas y series)...")
    key = ces.API_KEY
    scanned = 0
    try:
        data = ces.get_json(f"{ces.BAZARR_URL}/api/movies", {"limit": 2000})
        for m in (data or {}).get('data', []):
            rid = m.get('radarrId')
            if not rid:
                continue
            try:
                ces.api_patch(f"{ces.BAZARR_URL}/api/movies",
                              {"radarrid": rid, "action": "scan-disk"})
                scanned += 1
            except Exception:
                pass
    except Exception as e:
        log(f"  error listando películas: {e}")
    try:
        data = ces.get_json(f"{ces.BAZARR_URL}/api/series", {"limit": 2000})
        for s in (data or {}).get('data', []):
            sid = s.get('sonarrSeriesId')
            if not sid:
                continue
            try:
                ces.api_patch(f"{ces.BAZARR_URL}/api/series",
                              {"seriesid": sid, "action": "scan-disk"})
                scanned += 1
            except Exception:
                pass
    except Exception as e:
        log(f"  error listando series: {e}")
    log(f"scan-disk enviado a {scanned} elementos")

    # reporte final de wanted
    try:
        w = ces.get_json(f"{ces.BAZARR_URL}/api/movies/wanted",
                         {"start": 0, "length": 500}) or {}
        log(f"wanted movies tras el rescan: {w.get('total', 0)}")
    except Exception:
        pass
    try:
        w = ces.get_json(f"{ces.BAZARR_URL}/api/episodes/wanted",
                         {"start": 0, "length": 500}) or {}
        log(f"wanted episodes tras el rescan: {w.get('total', 0)}")
    except Exception:
        pass


if __name__ == '__main__':
    main()
