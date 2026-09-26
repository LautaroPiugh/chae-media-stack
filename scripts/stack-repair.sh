#!/usr/bin/env bash
# Reparación manual de monturas + contenedores para popup de tmux (prefix + R).
set -u

WD_LOG="/var/log/media-pool-watchdog.log"
B='\033[36m'; G='\033[32m'; Y='\033[33m'; N='\033[0m'

echo -e "${B}═══ REPARACIÓN MANUAL DE MONTURAS ═══${N}"
echo

echo -e "${B}── 1/3: watchdog del pool (remount si hace falta) ──${N}"
# systemctl start de una unidad del sistema pasa por polkit, no por sudo;
# por eso usamos sudo (hay una regla NOPASSWD para esta unidad exacta).
if sudo /usr/bin/systemctl start media-pool-watchdog.service 2>&1; then
  echo -e " ${G}unidad ejecutada sin error${N}"
else
  echo -e " ${Y}no se pudo lanzar la unidad (¿sudoers/polkit?); el timer lo intentará solo en ≤2 min${N}"
fi

echo
echo -e "${B}── 2/3: recovery de contenedores ──${N}"
if /home/chae/stack/scripts/media-mount-recovery.sh; then
  echo -e " ${G}recovery OK${N}"
else
  rc=$?
  echo -e " ${Y}recovery devolvió $rc (normal si las monturas siguen mal o ya estaba todo arriba)${N}"
fi

sleep 1
echo
echo -e "${B}── 3/3: estado resultante ──${N}"
findmnt /mnt/media >/dev/null 2>&1 && echo -e " pool /mnt/media: ${G}montado${N}" || echo -e " pool /mnt/media: ${Y}NO montado${N}"
CONFIG_FILE="${MEDIA_BRANCHES_CONFIG:-/home/chae/stack/.media-branches.conf}"
branches_raw="$(awk -F= '$1=="MEDIA_BRANCHES"{print substr($0, index($0,"=")+1); exit}' "$CONFIG_FILE" 2>/dev/null || true)"
if [[ -n "$branches_raw" ]]; then
  IFS=':' read -ra _branches <<< "$branches_raw"
  all_up=1
  for _b in "${_branches[@]}"; do
    mountpoint -q "$_b" || { all_up=0; echo -e "   $_b: ${Y}NO montada${N}"; }
  done
  [[ "$all_up" -eq 1 ]] && echo -e " ramas ($(echo "$branches_raw" | tr ':' ' ')): ${G}montadas${N}"
else
  echo -e " ramas: ${Y}sin config ($CONFIG_FILE)${N}"
fi

state="$(cat "${MEDIA_MOUNT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/media-mount-recovery}/last_state" 2>/dev/null || echo unknown)"
echo -e " estado recovery: $state"

echo
echo -e "${Y}Última acción del watchdog:${N}"
tail -n 2 "$WD_LOG" 2>/dev/null | sed 's/^/ /'
