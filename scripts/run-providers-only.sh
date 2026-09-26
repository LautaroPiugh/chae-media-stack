#!/usr/bin/env bash
# run-providers-only.sh — descarga subtítulos ES SOLO con los providers de Bazarr+
# (subx, opensubtitlescom, subtitulamostv, addic7ed, subdl, subsource,
# embeddedsubtitles y opensubtitles/.org vía FlareSolverr).
#
# No toca OpenSubtitles.com (cuota de 5/día), no traduce con DeepL/Gemini y no
# cae a whisper: lo que no se pueda descargar por providers queda pendiente.
#
# Uso:  nohup bash run-providers-only.sh > /dev/null 2>&1 &
#       tail -f /home/chae/stack/logs/providers-only.log
set -u

cd /home/chae/stack/scripts

LOG_DIR=/home/chae/stack/logs
LOG="$LOG_DIR/providers-only.log"
export PROVIDERS_ONLY=1

mkdir -p "$LOG_DIR"
exec >>"$LOG" 2>&1

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "════════════════════════════════════════════════════════"
log "SOLO PROVIDERS DE BAZARR+ — sin OpenSubtitles.com, sin traducir, sin whisper"
log "corrida $(date '+%Y-%m-%d %H:%M:%S')"
log "════════════════════════════════════════════════════════"

python3 check_es_subs.py || log "corrida terminada con código $?"

log "════════════════════════════════════════════════════════"
log "NORMALIZACIÓN — quita duplicados, unifica nombres a .es.srt, avisa a Bazarr"
log "════════════════════════════════════════════════════════"
python3 normalize-es-subs.py || log "normalización terminada con código $?"

log "════════════════════════════════════════════════════════"
log "TERMINADO $(date '+%Y-%m-%d %H:%M:%S')"
log "════════════════════════════════════════════════════════"
