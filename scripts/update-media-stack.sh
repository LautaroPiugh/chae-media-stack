#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$PROJECT_DIR"
LOG_DIR="$ROOT/logs"
LOG_FILE="$LOG_DIR/media-stack-update.log"
STATE_FILE="$HOME/.cache/media-stack-update.state"
STACK_DASHBOARD_SCRIPT="$ROOT/scripts/generate-stack-dashboard-data.sh"
DRY_RUN="${DRY_RUN:-0}"
WHATSAPP_NOTIFY_URL="${WHATSAPP_NOTIFY_URL:-http://127.0.0.1:3555/notify/system-update}"
WHATSAPP_NOTIFY_TOKEN="${WHATSAPP_NOTIFY_TOKEN:-CHANGEME}"
MODE="${1:-all}"

COMPOSE_DIRS=(
  "$ROOT/services/postgres"
  "$ROOT/services/uptime-kuma"
  "$ROOT/services/qbittorrent"
  "$ROOT/services/prowlarr"
  "$ROOT/services/sonarr"
  "$ROOT/services/radarr"
  "$ROOT/services/bazarr"
  "$ROOT/services/jellyfin"
  "$ROOT/services/flaresolverr"
  "$ROOT/services/subgen"
  "$ROOT/services/jellyseerr"
  "$ROOT/jellyfin-whatsapp-bot"
  "$ROOT/jellyfin-whatsapp-notifier"
  "$ROOT/nginx-proxy-manager"
  "$ROOT/services/tdarr"
)

status="failed"
summary=''

timestamp() {
  date '+%F %T'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

write_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  {
    printf 'last_run=%s\n' "$(date +%s)"
    printf 'last_status=%s\n' "$status"
    printf 'last_mode=%s\n' "$MODE"
  } > "$STATE_FILE"
}

trap write_state EXIT

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

run_cmd() {
  log "+ $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

notify_whatsapp() {
  local message="$1"

  if [[ "$DRY_RUN" == "1" ]]; then
    log 'Skipping WhatsApp notification in DRY_RUN mode'
    return 0
  fi

  if [[ -z "$WHATSAPP_NOTIFY_TOKEN" ]]; then
    log 'Skipping WhatsApp notification: no token configured'
    return 0
  fi

  curl -fsS -X POST "$WHATSAPP_NOTIFY_URL" \
    -H 'Content-Type: application/json' \
    -H "x-update-token: $WHATSAPP_NOTIFY_TOKEN" \
    -d "$(printf '{\"message\":%s}' "$(printf '%s' "$message" | jq -Rs .)")" >/dev/null || \
    log 'WhatsApp notification failed'
}

compose_has_running_services() {
  local dir="$1"
  docker compose -f "$dir/docker-compose.yml" ps --services --status running 2>/dev/null | grep -q '.'
}

compose_uses_build() {
  local dir="$1"
  grep -q '^[[:space:]]*build:' "$dir/docker-compose.yml"
}

update_compose_project() {
  local dir="$1"
  local name

  name="$(basename "$dir")"
  if [[ ! -f "$dir/docker-compose.yml" ]]; then
    log "Skipping $name: docker-compose.yml not found"
    return 0
  fi

  if ! compose_has_running_services "$dir"; then
    log "Skipping $name: no running services in this compose project"
    return 0
  fi

  log "Updating compose project: $name"
  if compose_uses_build "$dir"; then
    run_cmd docker compose -f "$dir/docker-compose.yml" build --pull
    run_cmd docker compose -f "$dir/docker-compose.yml" up -d --force-recreate
  else
    run_cmd docker compose -f "$dir/docker-compose.yml" pull
    run_cmd docker compose -f "$dir/docker-compose.yml" up -d --remove-orphans
  fi
}

update_portainer() {
  if ! docker ps --format '{{.Names}}' | grep -qx 'portainer'; then
    log 'Skipping portainer: container not running'
    return 0
  fi

  log 'Updating standalone container: portainer'
  run_cmd docker pull portainer/portainer-ce:latest
  run_cmd docker stop portainer
  run_cmd docker rm portainer
  run_cmd docker run -d --name portainer \
    --restart unless-stopped \
    --network bridge \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
}

update_system_packages() {
  run_cmd sudo apt update
  run_cmd sudo apt upgrade -y
  run_cmd sudo apt autoremove -y
}

update_media_stack() {
  local dir

  for dir in "${COMPOSE_DIRS[@]}"; do
    update_compose_project "$dir"
  done

  update_portainer
}

refresh_dashboard_cache() {
  if [[ ! -x "$STACK_DASHBOARD_SCRIPT" ]]; then
    log "Skipping dashboard cache refresh: script not executable at $STACK_DASHBOARD_SCRIPT"
    return 0
  fi

  log 'Refreshing stack dashboard cache'
  run_cmd "$STACK_DASHBOARD_SCRIPT"
}

build_summary() {
  local count
  count="$(docker ps -q | wc -l | tr -d ' ')"
  summary=$(cat <<EOF
✅ Update completado
Modo: $MODE
Estado: $status
Contenedores up: $count
Hora: $(date '+%d/%m/%Y %H:%M')
EOF
)
}

main() {
  log 'Starting media stack update'
  if [[ "$DRY_RUN" == "1" ]]; then
    log 'Running in DRY_RUN mode'
  fi

  case "$MODE" in
    all)
      update_system_packages
      update_media_stack
      ;;
    system)
      update_system_packages
      ;;
    media)
      update_media_stack
      ;;
    *)
      log "Unknown mode: $MODE"
      log 'Use: all | system | media'
      exit 1
      ;;
  esac

  run_cmd docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  if [[ "$DRY_RUN" == "1" ]]; then
    status='dry-run'
  else
    status='ok'
  fi
  build_summary
  log "$summary"
  refresh_dashboard_cache
  notify_whatsapp "$summary"
  log 'Media stack update completed'
}

main "$@"
