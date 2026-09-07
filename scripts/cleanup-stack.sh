#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="$HOME/services"
STATE_DIR="${CLEANUP_STATE_DIR:-$HOME/.local/state/cleanup-stack}"
LOG_FILE="$STATE_DIR/cleanup.log"
LOCK_FILE="$STATE_DIR/cleanup.lock"
LAST_RUN_FILE="$STATE_DIR/last-run.json"
DRY_RUN="${DRY_RUN:-0}"
NOTIFY_ENABLED="${CLEANUP_NOTIFY_ENABLED:-1}"
NOTIFY_URL="${CLEANUP_NOTIFY_URL:-http://127.0.0.1:3555/notify/system-update}"
BOT_ENV_FILE="${CLEANUP_BOT_ENV_FILE:-$HOME/services/jellyfin-whatsapp-bot/.env}"

umask 022
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"; }

notify_whatsapp() {
  local message="$1" token=''
  [[ "$NOTIFY_ENABLED" == '1' && "$DRY_RUN" == '0' ]] || return 0
  [[ -f "$BOT_ENV_FILE" ]] || return 0
  token="$(sed -n 's/^WHATSAPP_UPDATE_NOTIFY_TOKEN=//p' "$BOT_ENV_FILE" | head -n 1)"
  [[ -z "$token" ]] && return 0
  curl -fsS --connect-timeout 5 --max-time 15 -X POST "$NOTIFY_URL" \
    -H "x-update-token: $token" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg message "$message" '{message: $message}')" >/dev/null 2>&1 \
    || log "WARN: no se pudo enviar la notificacion WhatsApp"
}

human_size() {
  local bytes=$1
  LC_ALL=C awk -v b="$bytes" 'BEGIN{
    if (b >= 1073741824) printf "%.1fG", b/1073741824;
    else if (b >= 1048576) printf "%.0fM", b/1048576;
    else printf "%dB", b;
  }'
}

dir_bytes() {
  du -sb "$1" 2>/dev/null | awk '{print $1+0}'
}

purge_dir_contents() {
  local label="$1" dir="$2"
  local before=0 after=0 freed=0
  if [[ ! -d "$dir" ]]; then
    log "$label: no existe ($dir); omitido"
    echo "$label:omitido:no_existe"
    return 0
  fi
  before="$(dir_bytes "$dir")"
  if [[ "$DRY_RUN" == '1' ]]; then
    echo "$label:dry:$before"
    log "$label (dry-run): $dir ocupa $(human_size "$before")"
    return 0
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>>"$LOG_FILE" || true
  after="$(dir_bytes "$dir")"
  freed=$(( before > after ? before - after : 0 ))
  echo "$label:limpio:$freed"
  log "$label: liberados $(human_size "$freed") de $dir"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "ERROR: ya hay una limpieza en ejecucion"
  exit 75
fi

log "=== Inicio limpieza del stack (dry_run=$DRY_RUN) ==="
RESULT_LINES=()
RESULT_LINES+=("$(purge_dir_contents 'PapeleraNTFS_media1' '/mnt/media1/$RECYCLE.BIN')")
RESULT_LINES+=("$(purge_dir_contents 'PapeleraNTFS_media2' '/mnt/media2/$RECYCLE.BIN')")
RESULT_LINES+=("$(purge_dir_contents 'PapeleraNTFS_media3' '/mnt/media3/$RECYCLE.BIN')")
RESULT_LINES+=("$(purge_dir_contents 'Cache_Jellyfin' "$STACK_DIR/jellyfin/config/cache/transcodes")")
RESULT_LINES+=("$(purge_dir_contents 'Log_Jellyfin' "$STACK_DIR/jellyfin/config/log")")
RESULT_LINES+=("$(purge_dir_contents 'Cache_Tdarr' "$STACK_DIR/tdarr/cache")")

DOCKER_FREED=0
if [[ "$DRY_RUN" == '0' ]]; then
  if command -v docker >/dev/null 2>&1; then
    if DOCKER_OUT=$(docker image prune -f 2>&1); then
      DOCKER_HUMAN=$(printf '%s\n' "$DOCKER_OUT" | sed -n 's/^Total reclaimed space: //p' | tail -n 1)
      if [[ -n "${DOCKER_HUMAN:-}" ]]; then
        DOCKER_FREED=$(numfmt --from=auto "$DOCKER_HUMAN" 2>/dev/null || echo 0)
      fi
      log "Docker imagenes colgantes: liberados $(human_size "$DOCKER_FREED")"
      RESULT_LINES+=("Docker:dangling:$DOCKER_FREED")
    else
      log "WARN: docker image prune fallo"
      RESULT_LINES+=("Docker:error:0")
    fi
  fi
else
  RESULT_LINES+=("Docker:dry:0")
fi

TOTAL_FREED=0
for line in "${RESULT_LINES[@]}"; do
  value="$(awk -F: '{print $3}' <<< "$line")"
  [[ "$value" =~ ^[0-9]+$ ]] && TOTAL_FREED=$(( TOTAL_FREED + value ))
done

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg ts "$(date -Iseconds)" \
    --arg dry "$DRY_RUN" \
    --arg freed "$TOTAL_FREED" \
    --arg freedHuman "$(human_size "$TOTAL_FREED")" \
    --arg details "$(printf '%s\n' "${RESULT_LINES[@]}" | jq -Rsc 'split("\n") | map(select(length>0)) | map(split(":")) | map({name:.[0], action:.[1], bytes:((.[2] // "0") | if test("^[0-9]+$") then tonumber else 0 end)})')" \
    '{timestamp:$ts, dryRun:($dry=="1"), freedBytes:($freed|tonumber), freedHuman:$freedHuman, details:($details|fromjson)}' \
    > "$LAST_RUN_FILE.tmp" && mv "$LAST_RUN_FILE.tmp" "$LAST_RUN_FILE"
fi

log "Limpieza finalizada: liberados $(human_size "$TOTAL_FREED") en total"
if [[ "$DRY_RUN" == '0' ]]; then
  notify_whatsapp "🧹 Limpieza del stack completada: $(human_size "$TOTAL_FREED") liberados ($(date '+%H:%M'))"
fi

for line in "${RESULT_LINES[@]}"; do printf '%s\n' "$line"; done
printf 'TOTAL:%s:%s\n' "$TOTAL_FREED" "$(human_size "$TOTAL_FREED")"
exit 0
