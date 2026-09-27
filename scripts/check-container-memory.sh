#!/usr/bin/env bash
# Memory watchdog for a single container.
#
# Usage: check-container-memory.sh [container] [threshold_mib]
#   defaults: chae-qbittorrent  1024
#
# Alerts (once per unhealthy streak) when the container RSS crosses the
# threshold, and once more when it recovers. State is kept in XDG_STATE_HOME
# so repeated runs stay quiet instead of spamming the notify channel.
set -uo pipefail

CONTAINER="${1:-chae-qbittorrent}"
THRESHOLD_MIB="${2:-1024}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/container-memory"
STATE_FILE="$STATE_DIR/${CONTAINER}.state"
ENV_FILE="$(dirname "$(dirname "$(readlink -f "$0")")")/scripts/check_es_subs.env"

log() { logger -t container-memory -- "$*"; echo "$(date '+%F %T') $*" >>"$STATE_DIR/log" 2>/dev/null; }

mkdir -p "$STATE_DIR" || exit 0

# --- previous state -----------------------------------------------------------
prev="unknown"
[ -f "$STATE_FILE" ] && prev="$(cat "$STATE_FILE" 2>/dev/null)"

# --- current usage ------------------------------------------------------------
# docker stats is the source of truth: it reports the cgroup accounting, which
# includes page cache the container caused. RSS from ps/ does not.
usage_line=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER" 2>/dev/null)
if [ -z "$usage_line" ]; then
    # container stopped or missing: reset so a fresh start re-alerts cleanly
    [ "$prev" != "down" ] && { echo "down" >"$STATE_FILE"; log "$CONTAINER not running (stats unavailable)"; }
    exit 0
fi

# docker stats already reports IEC units ("66.74MiB"), so MiB needs no scaling.
# Strip the unit with awk: numfmt does not accept the "iB" spelling docker emits.
used_mib=$(awk '
    /^ *[0-9.]+/ {
        v = $1 + 0
        if      ($1 ~ /[Kk]i?B$/) v /= 1024
        else if ($1 ~ /[Gg]i?B$/) v *= 1024
        printf "%d", v
        exit
    }' <<<"$usage_line")
case "$used_mib" in
    ''|*[!0-9]*) log "$CONTAINER: could not parse '$usage_line'"; exit 0 ;;
esac

# --- state transition ---------------------------------------------------------
if [ "$used_mib" -ge "$THRESHOLD_MIB" ]; then
    cur="high"
else
    cur="ok"
fi

[ "$cur" = "$prev" ] && exit 0

notify() {
    [ -f "$ENV_FILE" ] || return 0
    # shellcheck disable=SC1090
    NOTIFY_URL=$(grep -E '^NOTIFY_URL=' "$ENV_FILE" | cut -d= -f2-)
    NOTIFY_SECRET=$(grep -E '^NOTIFY_SECRET=' "$ENV_FILE" | cut -d= -f2-)
    [ -z "$NOTIFY_URL" ] && return 0
    curl -s -m 10 -X POST "$NOTIFY_URL" \
        -H "x-update-token: $NOTIFY_SECRET" \
        -H 'Content-Type: application/json' \
        -d "$(printf '{"message":%s}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")")" \
        >/dev/null 2>&1
}

if [ "$cur" = "high" ]; then
    msg="$CONTAINER at ${used_mib} MiB (threshold ${THRESHOLD_MIB} MiB) - likely a memory leak. Restart: docker restart $CONTAINER"
    log "HIGH: $msg"
    notify "$msg"
else
    msg="$CONTAINER back to ${used_mib} MiB (was over ${THRESHOLD_MIB} MiB)"
    log "OK: $msg"
    notify "$msg"
fi

echo "$cur" >"$STATE_FILE"
