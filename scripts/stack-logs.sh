#!/usr/bin/env bash
# Visor de logs del stack para popup de tmux (prefix + L).
set -u

WD_LOG="/var/log/media-pool-watchdog.log"
REC_LOG="${MEDIA_MOUNT_STATE_DIR:-/home/chae/.local/state/media-mount-recovery}/recovery.log"
REC_STATE="${MEDIA_MOUNT_STATE_DIR:-/home/chae/.local/state/media-mount-recovery}/last_state"
UPD_LOG="/home/chae/scripts/check_es_subs.log"

B='\033[36m'; N='\033[0m'; D='\033[2m'

echo -e "${B}═══ WATCHDOG DEL POOL (últimas 12 líneas) ═══${N}"
tail -n 12 "$WD_LOG" 2>/dev/null | sed 's/^/ /' || echo ' (vacío)'

echo
echo -e "${B}═══ RECOVERY DE CONTENEDORES (últimas 14 líneas) ═══${N}"
tail -n 14 "$REC_LOG" 2>/dev/null | sed 's/^/ /' || echo ' (vacío)'

echo
state="$(cat "$REC_STATE" 2>/dev/null || echo unknown)"
echo -e "${D} estado actual de monturas: ${state}${N}"
echo -e "${D} refresco: pulsa H de nuevo o cierra y reabre el popup${N}"
