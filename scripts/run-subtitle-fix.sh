#!/usr/bin/env bash
# run-subtitle-fix.sh — descarga los subtítulos ES que faltan o están rotos.
#
# Orden (lo mejor primero, tal como lo pidió el usuario):
#   FASE A  descarga de un sub ES real   → providers de Bazarr (7) + OpenSubtitles
#   FASE B  traducción del inglés        → solo si no había ES descargable
#   FASE C  whisper                      → solo si no hay ni ES ni inglés
#
# Las condiciones se mantienen en todo el camino: nunca SDH/HI/CC, español/español
# latam, score mínimo, y QA del sub antes de aceptarlo (sub_qa).
#
# Uso:  nohup bash run-subtitle-fix.sh > /dev/null 2>&1 &
#       tail -f /home/chae/stack/logs/subtitle-fix.log
set -u

cd /home/chae/stack/scripts

LOG_DIR=/home/chae/stack/logs
LOG="$LOG_DIR/subtitle-fix.log"
# cuota propia de OpenSubtitles (la real del servicio es 1000/día)
export OS_DAILY_LIMIT="${OS_DAILY_LIMIT:-250}"

mkdir -p "$LOG_DIR"
exec >>"$LOG" 2>&1

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "════════════════════════════════════════════════════════"
log "SUBTÍTULOS ES — descarga primero, traductor solo si es imposible"
log "OS_DAILY_LIMIT=$OS_DAILY_LIMIT · corrida $(date '+%Y-%m-%d %H:%M:%S')"
log "════════════════════════════════════════════════════════"

log "FASE ÚNICA — check_es_subs.py (A descarga · B traduce · C whisper)"
python3 check_es_subs.py || log "corrida terminada con código $?"

log "════════════════════════════════════════════════════════"
log "NORMALIZACIÓN — borra SDH/HI, renombra .es-MX.srt -> .es.srt, avisa a Bazarr"
log "════════════════════════════════════════════════════════"
python3 normalize-es-subs.py || log "normalización terminada con código $?"

log "════════════════════════════════════════════════════════"
log "AUDITORÍA FINAL"
log "════════════════════════════════════════════════════════"
python3 fix_subs_whisper.py audit /mnt/media | tail -25

log "════════════════════════════════════════════════════════"
log "TERMINADO $(date '+%Y-%m-%d %H:%M:%S')"
log "════════════════════════════════════════════════════════"
