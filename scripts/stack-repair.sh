#!/usr/bin/env bash
# Reparación manual de monturas + contenedores para popup de tmux (prefix + R).
set -u

WD_LOG="/var/log/media-pool-watchdog.log"
B='\033[36m'; G='\033[32m'; Y='\033[33m'; N='\033[0m'

echo -e "${B}═══ REPARACIÓN MANUAL DE MONTURAS ═══${N}"
echo

echo -e "${B}── 1/3: watchdog del pool (remount si hace falta) ──${N}"
if systemctl start media-pool-watchdog.service 2>&1; then
  echo -e " ${G}unidad ejecutada sin error${N}"
else
  echo -e " ${Y}no se pudo lanzar la unidad (¿permiso polkit?); el timer lo intentará solo en ≤2 min${N}"
fi

echo
echo -e "${B}── 2/3: recovery de contenedores ──${N}"
if /home/chae/scripts/media-mount-recovery.sh; then
  echo -e " ${G}recovery OK${N}"
else
  rc=$?
  echo -e " ${Y}recovery devolvió $rc (normal si las monturas siguen mal o ya estaba todo arriba)${N}"
fi

sleep 1
echo
echo -e "${B}── 3/3: estado resultante ──${N}"
findmnt /mnt/media >/dev/null 2>&1 && echo -e " pool /mnt/media: ${G}montado${N}" || echo -e " pool /mnt/media: ${Y}NO montado${N}"
mountpoint -q /mnt/media1 && mountpoint -q /mnt/media2 \
  && echo -e " ramas media1/media2: ${G}montadas${N}" || echo -e " ramas: ${Y}alguna caída${N}"

state="$(cat "${MEDIA_MOUNT_STATE_DIR:-/home/chae/.local/state/media-mount-recovery}/last_state" 2>/dev/null || echo unknown)"
echo -e " estado recovery: $state"

echo
echo -e "${Y}Última acción del watchdog:${N}"
tail -n 2 "$WD_LOG" 2>/dev/null | sed 's/^/ /'
