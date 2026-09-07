#!/usr/bin/env bash
set -Eeuo pipefail

SRC_ROOT="${SRC_ROOT:-/mnt/media2}"
DST_ROOT="${DST_ROOT:-/mnt/media3}"
LOG="${REBALANCE_LOG:-$HOME/.local/state/rebalance.log}"

umask 022
mkdir -p "$(dirname "$LOG")"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

for subdir in movies series; do
  src="$SRC_ROOT/$subdir"
  dst="$DST_ROOT/$subdir"
  [[ -d "$src" ]] || { log "WARN: $src no existe; omito"; continue; }
  mkdir -p "$dst"
  log "=== Comienzo $subdir ==="
  while IFS= read -r -d '' folder; do
    name="$(basename "$folder")"
    log "Moviendo: $subdir/$name"
    if rsync -a --info=stats1 --info=progress0 "$folder/" "$dst/$name/" >> "$LOG" 2>&1; then
      rm -rf "$folder"
      log "OK: $subdir/$name movido"
    else
      log "ERROR: rsync fallo en $subdir/$name; conservo el original"
    fi
  done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  log "=== Fin $subdir ==="
done

log "=== Rebalanceo finalizado ==="
df -h /mnt/media2 /mnt/media3 >> "$LOG"
