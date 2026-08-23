#!/usr/bin/env bash
# Segmentos extra para la barra de tmux, basados en el JSON cacheado
# (generado cada 5 min por generate-stack-dashboard-data.sh).
set -euo pipefail

JSON="${XDG_CACHE_HOME:-$HOME/.cache}/stack-dashboard/stack-data.json"
RECOVERY_STATE="${MEDIA_MOUNT_STATE_DIR:-/home/chae/.local/state/media-mount-recovery}/last_state"

GREEN='#[fg=colour114]'
YELLOW='#[fg=colour179]'
RED='#[fg=colour203]'
GREY='#[fg=colour245]'
RESET='#[fg=default]'

if [[ ! -r "$JSON" ]]; then
  printf ' %sdash:sin datos%s' "$RED" "$RESET"
  exit 0
fi

read -r SRV_UP SRV_TOT STALE POOL_PCT FREE_GB <<EOF
$(python3 - "$JSON" <<'PYEOF'
import json, sys, time
d = json.load(open(sys.argv[1]))
s = d.get('summary', {})
svcs = [x for x in d.get('services', []) if x.get('container') != 'watchtower']
up = sum(1 for x in svcs if x.get('up') and (not x.get('url') or x.get('httpOk')))
tot = len(svcs)
gen = d.get('generatedAt', '')
stale = 1
try:
    from datetime import datetime
    t = datetime.fromisoformat(gen.replace('+00:00', '+0000')).timestamp()
    stale = 1 if (time.time() - t) > 900 else 0
except Exception:
    pass
pct = next((x.get('usePercent') for x in d.get('storage', []) if x.get('path') == '/mnt/media'), '?')
free = next((round(x.get('availableBytes', 0) / 1073741824) for x in d.get('storage', []) if x.get('path') == '/mnt/media'), '?')
print(up, tot, stale, pct, free)
PYEOF
)
EOF

srv_color="$GREEN"
[[ "$SRV_UP" == "$SRV_TOT" ]] || srv_color="$YELLOW"
(( SRV_UP < SRV_TOT - 2 )) && srv_color="$RED"

pool_color="$GREEN"
if [[ "$POOL_PCT" =~ ^[0-9]+$ ]]; then
  (( POOL_PCT >= 90 )) && pool_color="$RED" || { (( POOL_PCT >= 80 )) && pool_color="$YELLOW"; }
else
  pool_color="$RED"
fi

dash_color="$GREEN"
(( STALE == 1 )) && dash_color="$GREY"

wdog_color="$GREEN"
wdog_label="wdog:ok"
if ! systemctl is-active --quiet media-pool-watchdog.timer 2>/dev/null; then
  wdog_color="$RED"
  wdog_label="wdog:OFF"
fi

mount_color="$GREEN"
mount_label="mnt:ok"
state="$(cat "$RECOVERY_STATE" 2>/dev/null || echo unknown)"
case "$state" in
  healthy) ;;
  missing) mount_color="$YELLOW"; mount_label="mnt:wait" ;;
  *)       mount_color="$RED";    mount_label="mnt:$state" ;;
esac

printf ' %ssrv:%s/%s %spool:%s%%%s(%sG) %s%s %s%s%s' \
  "$srv_color" "$SRV_UP" "$SRV_TOT" \
  "$pool_color" "$POOL_PCT" "$RESET" "$FREE_GB" \
  "$wdog_color" "$wdog_label" \
  "$mount_color" "$mount_label" "$RESET"
