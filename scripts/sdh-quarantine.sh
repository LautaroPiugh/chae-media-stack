#!/usr/bin/env bash
# Mueve subtitos para sordos (SDH/HI/CC) de la biblioteca a una carpeta de cuarentena.
# Reversible: preserva la estructura relativa bajo /mnt/media.
#
# Uso:
#   sdh-quarantine.sh            # dry-run (solo lista)
#   sdh-quarantine.sh --apply    # mueve los archivos a la cuarentena
set -euo pipefail

MEDIA_ROOT="${MEDIA_ROOT:-/mnt/media}"
QUARANTINE_DIR="${SDH_QUARANTINE_DIR:-/mnt/media2/backups/sdh-quarantine}"
APPLY='0'
[[ "${1:-}" == '--apply' ]] && APPLY='1'

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

PATTERN='[.\-_ ](sdh|cc|hi)[.\-_ ]|[.\-_ ](sdh|cc|hi)$|^(sdh|cc|hi)[.\-_ ]|\[(sdh|cc|hi)\]|\((sdh|cc|hi)\)|\.hi\.|\.cc\.|hearing'

mapfile -t FILES < <(
  find "$MEDIA_ROOT/movies" "$MEDIA_ROOT/series" "$MEDIA_ROOT/anime" \
    -type f \( -iname '*.srt' -o -iname '*.ass' -o -iname '*.ssa' -o -iname '*.vtt' \) 2>/dev/null \
    | grep -iE "$PATTERN" | sort
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  log "No se encontraron subs SDH en la biblioteca"
  exit 0
fi

moved=0
last_resort=0
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  dir="$(dirname "$f")"
  # ¿es el unico sub ES del video? (avisar: al moverlo queda sin ES hasta que el pipeline baje uno nuevo)
  siblings_es="$({ find "$dir" -maxdepth 1 -type f \( -iname '*.es*.srt' -o -iname '*.ea*.srt' -o -iname '*latin*.srt' \) 2>/dev/null | grep -ivE "$PATTERN" || true; } | wc -l | tr -d ' ')"
  is_hi_es="$(printf '%s' "$base" | grep -ciE '\.(es|ea|sp)' || true)"
  note=''
  if [[ "$is_hi_es" -gt 0 && "$siblings_es" == '0' ]]; then
    note="  [ULTIMO RECURSO ES: no hay otro sub ES no-SDH en la carpeta]"
    last_resort=$((last_resort + 1))
  fi

  if [[ "$APPLY" == '1' ]]; then
    rel="${f#"$MEDIA_ROOT"/}"
    dest="$QUARANTINE_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    mv -n "$f" "$dest"
    chmod 600 "$dest" 2>/dev/null || true
    log "MOVIDO: $rel$note"
  else
    log "ENCONTRADO: ${f#"$MEDIA_ROOT"/}$note"
  fi
  moved=$((moved + 1))
done

if [[ "$APPLY" == '1' ]]; then
  log "Cuarentena completada: $moved archivos movidos a $QUARANTINE_DIR ($last_resort eran ultimo recurso ES)"
  log "Restaurar: mv $QUARANTINE_DIR/<ruta> $MEDIA_ROOT/<ruta>"
else
  log "DRY-RUN: $moved archivos SDH encontrados ($last_resort ultimo recurso ES). Ejecutar con --apply para moverlos."
fi
