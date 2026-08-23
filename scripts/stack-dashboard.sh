#!/usr/bin/env bash
# Dashboard completo del stack para popup de tmux (prefix + H).
set -u

JSON="${XDG_CACHE_HOME:-$HOME/.cache}/stack-dashboard/stack-data.json"
RECOVERY_DIR="${MEDIA_MOUNT_STATE_DIR:-/home/chae/.local/state/media-mount-recovery}"
WD_LOG="/var/log/media-pool-watchdog.log"
REC_LOG="$RECOVERY_DIR/recovery.log"

G='\033[32m'; R='\033[31m'; Y='\33[33m'; B='\033[36m'; D='\033[2m'; N='\033[0m'

echo -e "${B}═════════ CHAE MEDIA STACK ═════════${N} $(date '+%a %d/%m %H:%M')"

# ---------- servicios ----------
if [[ ! -r "$JSON" ]]; then
  echo -e "${R}Sin JSON de dashboard (${JSON})${N}"
else
  TMPDIR_D="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_D"' EXIT

  python3 - "$JSON" >"$TMPDIR_D/list" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d.get('services', []):
    if s.get('container') == 'watchtower':
        continue
    print('|'.join([
        s.get('name','?'), s.get('container','?'), s.get('portLabel','-'),
        s.get('url',''), str(s.get('up', False)), s.get('statusLabel','?'),
        s.get('category','?'),
    ]))
PYEOF

  # chequeo HTTP en vivo, en paralelo (2s max por servicio)
  while IFS='|' read -r name ctr port url up st cat; do
    [[ -n "$url" ]] || continue
    (
      curl_args=(-s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3)
      [[ "$url" == https://* ]] && curl_args+=(--insecure)
      code=$(curl "${curl_args[@]}" "${url/192.168.1.100/127.0.0.1}" 2>/dev/null || echo 000)
      printf '%s' "$code" > "$TMPDIR_D/http.$ctr"
    ) &
  done < "$TMPDIR_D/list"
  wait

  printf '\n%s\n' "SERVICIOS"
  while IFS='|' read -r name ctr port url up st cat; do
    if [[ -z "$url" ]]; then
      if [[ "$up" == "True" ]]; then mark="${G}●${N}"; extra="corriendo"; else mark="${R}✗${N}"; extra="CAIDO"; fi
    else
      code="$(cat "$TMPDIR_D/http.$ctr" 2>/dev/null || echo 000)"
      if [[ "$code" =~ ^2|^3 ]]; then
        mark="${G}●${N}"; extra="http $code"
      elif [[ "$up" == "True" ]]; then
        [[ "$code" == "000" ]] && mark="${Y}◐${N}" || mark="${Y}◐${N}"; extra="http $code"
      else
        mark="${R}✗${N}"; extra="$st"
      fi
    fi
    printf " %b %-14s \033[2m%-22s\033[0m %-6s %b\n" "$mark" "$name" "$ctr" "$port" "$extra"
  done < "$TMPDIR_D/list"

  # ---------- almacenamiento ----------
  printf '\n%s\n' "ALMACENAMIENTO"
  python3 - "$JSON" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
seen = set()
for x in d.get('storage', []):
    mp = x.get('mountPoint')
    if mp in seen:
        continue
    seen.add(mp)
    pct = x.get('usePercent', '?')
    free = round(x.get('availableBytes', 0) / 1073741824)
    bar_len = 20
    filled = int(round(pct * bar_len / 100)) if isinstance(pct, int) else 0
    color = '\033[32m' if pct < 80 else ('\033[33m' if pct < 90 else '\033[31m')
    print(' \033[2m%-22s\033[0m [%s%s\033[0m%s] %3s%%  %sG libres' % (
        x.get('label', mp), color, '█' * filled, '·' * (bar_len - filled), pct, free))
PYEOF

  rm -rf "$TMPDIR_D"; trap - EXIT
fi

# ---------- sistema ----------
printf '\n%s\n' "SISTEMA"
free -h --si | awk 'NR==2{printf " RAM %s usados de %s", $3, $2} NR==3{printf " | swap %s/%s", $3, $2} END{print ""}'
printf ' carga: %s | uptime: %s\n' "$(uptime | sed -E 's/.*load average: ([^,]*).*/\1/')" "$(uptime -p | sed 's/up //')"

# ---------- monturas y watchdog ----------
printf '\n%s\n' "MONTURAS Y WATCHDOG"
state="$(cat "$RECOVERY_DIR/last_state" 2>/dev/null || echo unknown)"
if [[ "$state" == healthy ]]; then printf " monturas: ${G}healthy${N}\n"; else printf " monturas: ${Y}%s${N}\n" "$state"; fi
if systemctl is-active --quiet media-pool-watchdog.timer 2>/dev/null; then
  next="$(systemctl show media-pool-watchdog.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
  printf " watchdog: ${G}activo${N} (cada 2 min)\n"
else
  printf " watchdog: ${R}INACTIVO${N}\n"
fi
last_wd="$(tail -n 1 "$WD_LOG" 2>/dev/null || true)"
[[ -n "$last_wd" ]] && printf " ${D}%s${N}\n" "$last_wd"

recent_stops="$(grep -c 'Deteniendo' "$REC_LOG" 2>/dev/null || echo 0)"
printf " paradas protectivas (histórico): %s\n" "$recent_stops"

printf '\n%s\n' "ÚLTIMOS EVENTOS (recovery)"
tail -n 4 "$REC_LOG" 2>/dev/null | grep '^\[' | tail -n 3 | sed 's/^/ /'

printf '\n%bCOMANDOS:%b U=update-all M=update-media S=update-sys H=dashboard L=logs R=reparar-monturas\n' "$B" "$N"
