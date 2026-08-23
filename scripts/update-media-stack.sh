#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${UPDATE_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ROOT="$PROJECT_DIR"
COMPOSE_ROOT="${UPDATE_COMPOSE_ROOT:-$ROOT}"
COMPOSE_PROJECT_ROOT="${UPDATE_COMPOSE_PROJECT_ROOT:-$COMPOSE_ROOT}"
ROLLBACK_COMPOSE_ROOT="${UPDATE_ROLLBACK_COMPOSE_ROOT:-$COMPOSE_ROOT}"
LOG_DIR="$ROOT/logs"
LOG_FILE="$LOG_DIR/media-stack-update.log"
STATE_FILE="${UPDATE_STATE_FILE:-$HOME/.cache/media-stack-update.state}"
LOCK_FILE="${UPDATE_LOCK_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/chae-media-update/queue.lock}"
UPDATE_ORCHESTRATED="${UPDATE_ORCHESTRATED:-0}"
STACK_DASHBOARD_SCRIPT="$ROOT/scripts/generate-stack-dashboard-data.sh"
HEALTH_CHECK_SCRIPT="$ROOT/scripts/health-check.sh"
MEDIA_STATUS_SCRIPT="$ROOT/scripts/media-status.sh"
BACKUP_DIR="${BACKUP_DIR:-/mnt/media2/backups/stack}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-30}"
DRY_RUN="${DRY_RUN:-1}"
CONFIRM_UPDATE="${CONFIRM_UPDATE:-}"
UPDATE_PORTAINER="${UPDATE_PORTAINER:-0}"
PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:2.39.5}"
PORTAINER_BACKUP_FILE="${PORTAINER_BACKUP_FILE:-}"
WHATSAPP_NOTIFY_URL="${WHATSAPP_NOTIFY_URL:-http://127.0.0.1:3555/notify/system-update}"
WHATSAPP_NOTIFY_TOKEN="${WHATSAPP_NOTIFY_TOKEN:-CHANGEME}"
WHATSAPP_NOTIFY_ENABLED="${WHATSAPP_NOTIFY_ENABLED:-1}"
REFRESH_DASHBOARD_ENABLED="${REFRESH_DASHBOARD_ENABLED:-1}"
MODE="${1:-help}"
TARGET="${2:-}"

declare -Ar UPDATE_DIRS=(
  [prowlarr]="$COMPOSE_ROOT/services/prowlarr"
  [sonarr]="$COMPOSE_ROOT/services/sonarr"
  [radarr]="$COMPOSE_ROOT/services/radarr"
  [bazarr]="$COMPOSE_ROOT/services/bazarr"
  [jellyfin]="$COMPOSE_ROOT/services/jellyfin"
  [flaresolverr]="$COMPOSE_ROOT/services/flaresolverr"
  [subgen]="$COMPOSE_ROOT/services/subgen"
  [jellyseerr]="$COMPOSE_ROOT/services/jellyseerr"
  [tdarr]="$COMPOSE_ROOT/services/tdarr"
)

declare -Ar UPDATE_SERVICES=(
  [prowlarr]='prowlarr'
  [sonarr]='sonarr'
  [radarr]='radarr'
  [bazarr]='bazarr'
  [jellyfin]='jellyfin'
  [flaresolverr]='flaresolverr'
  [subgen]='subgenai'
  [jellyseerr]='jellyseerr'
  [tdarr]='tdarr tdarr-node'
)

declare -Ar BACKUP_KEYS=(
  [prowlarr]='prowlarr'
  [sonarr]='sonarr'
  [radarr]='radarr'
  [bazarr]='bazarr'
  [jellyfin]='jellyfin'
  [flaresolverr]=''
  [subgen]=''
  [jellyseerr]='jellyseerr'
  [tdarr]='tdarr'
)

declare -Ar READY_URLS=(
  [prowlarr]='http://127.0.0.1:9696/'
  [sonarr]='http://127.0.0.1:8989/'
  [radarr]='http://127.0.0.1:7878/'
  [bazarr]='http://127.0.0.1:6767/'
  [jellyfin]='http://127.0.0.1:8096/'
  [flaresolverr]='http://127.0.0.1:8191/'
  [subgen]='http://127.0.0.1:9000/'
  [jellyseerr]='http://127.0.0.1:5055/'
  [tdarr]='http://127.0.0.1:8265/'
)

declare -Ar READY_TIMEOUTS=(
  [prowlarr]=180
  [sonarr]=180
  [radarr]=180
  [bazarr]=420
  [jellyfin]=240
  [flaresolverr]=300
  [subgen]=180
  [jellyseerr]=240
  [tdarr]=300
)

DENYLIST=(
  postgres
  portainer
  watchtower
  cloudflared
  jellyfin-whatsapp-bot
  adguard
  qbittorrent
  homepage
  uptime-kuma
  maintainerr
  nginx-proxy-manager
)

status='failed'
summary=''
logging_ready=0
failure_notified=0

timestamp() {
  date '+%F %T'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso seguro:
  update-media-stack.sh list
  DRY_RUN=1 update-media-stack.sh service <servicio>
  DRY_RUN=0 CONFIRM_UPDATE=<servicio> update-media-stack.sh service <servicio>

Vista previa de toda la allowlist (nunca actualiza en lote):
  DRY_RUN=1 update-media-stack.sh media

Portainer requiere gates y backup adicionales:
  DRY_RUN=1 update-media-stack.sh portainer
  DRY_RUN=0 UPDATE_PORTAINER=1 CONFIRM_UPDATE=portainer \
    PORTAINER_BACKUP_FILE=/ruta/portainer-data.tar.gz \
    update-media-stack.sh portainer

DRY_RUN vale 1 por defecto. Los modos all/system no ejecutan actualizaciones.
EOF
}

write_state() {
  local temp_file

  mkdir -p "$(dirname "$STATE_FILE")"
  temp_file="$(mktemp "${STATE_FILE}.XXXXXX")"
  {
    printf 'last_run=%s\n' "$(date +%s)"
    printf 'last_status=%s\n' "$status"
    printf 'last_mode=%s\n' "$MODE"
    printf 'last_target=%s\n' "$TARGET"
  } > "$temp_file"
  mv -f -- "$temp_file" "$STATE_FILE"
}

notify_whatsapp_raw() {
  local message="$1"

  [[ "$WHATSAPP_NOTIFY_ENABLED" == '1' ]] || return 0
  if [[ -z "$WHATSAPP_NOTIFY_TOKEN" || "$WHATSAPP_NOTIFY_TOKEN" == 'CHANGEME' ]]; then
    return 0
  fi
  curl -fsS -X POST "$WHATSAPP_NOTIFY_URL" \
    -H 'Content-Type: application/json' \
    -H "x-update-token: $WHATSAPP_NOTIFY_TOKEN" \
    -d "$(printf '{\"message\":%s}' "$(printf '%s' "$message" | jq -Rs .)")" >/dev/null \
    || log 'WhatsApp notification failed'
}

on_exit() {
  local exit_code="$1"

  [[ "$logging_ready" == '1' ]] || return 0
  if [[ "$exit_code" -ne 0 ]]; then
    status='failed'
    summary="Update failed: mode=$MODE target=${TARGET:-none}"
    if [[ "$DRY_RUN" == '0' && "$failure_notified" == '0' ]]; then
      failure_notified=1
      notify_whatsapp_raw "$summary"
    fi
  fi
  write_state
}

setup_logging() {
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
  logging_ready=1
  trap 'on_exit $?' EXIT
}

acquire_lock() {
  [[ "$UPDATE_ORCHESTRATED" == '1' ]] && return 0
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 8>"$LOCK_FILE"
  flock -n 8 || die 'ya hay otra actualizacion de servicio en ejecucion'
}

print_cmd() {
  printf '[%s] +' "$(timestamp)"
  printf ' %q' "$@"
  printf '\n'
}

run_cmd() {
  print_cmd "$@"
  if [[ "$DRY_RUN" == '1' ]]; then
    return 0
  fi
  "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "falta el comando requerido: $1"
}

is_denied() {
  local requested="$1"
  local denied

  for denied in "${DENYLIST[@]}"; do
    [[ "$requested" == "$denied" ]] && return 0
  done
  return 1
}

list_policy() {
  printf 'Allowlist actualizable manualmente:\n'
  printf '  %s\n' "${!UPDATE_DIRS[@]}" | sort
  printf '\nDenylist de seguridad:\n'
  printf '  %s\n' "${DENYLIST[@]}"
  printf '\nWatchtower permanece deshabilitado y este script no lo inicia ni recrea.\n'
}

validate_settings() {
  [[ "$DRY_RUN" == '0' || "$DRY_RUN" == '1' ]] || die 'DRY_RUN debe ser 0 o 1'
  [[ "$UPDATE_PORTAINER" == '0' || "$UPDATE_PORTAINER" == '1' ]] \
    || die 'UPDATE_PORTAINER debe ser 0 o 1'
  [[ "$BACKUP_MAX_AGE_HOURS" =~ ^[0-9]+$ && "$BACKUP_MAX_AGE_HOURS" -gt 0 ]] \
    || die 'BACKUP_MAX_AGE_HOURS debe ser un entero positivo'
}

require_confirmation() {
  local expected="$1"

  [[ "$DRY_RUN" == '1' ]] && return 0
  [[ "$CONFIRM_UPDATE" == "$expected" ]] \
    || die "confirmacion requerida: CONFIRM_UPDATE=$expected"
}

assert_watchtower_stopped() {
  local running

  running="$(docker inspect --format '{{.State.Running}}' watchtower 2>/dev/null || true)"
  [[ "$running" != 'true' ]] || die 'Watchtower esta activo; detengalo antes de actualizar'
}

check_media_mounts() {
  local media_status

  [[ -x "$MEDIA_STATUS_SCRIPT" ]] || die "falta $MEDIA_STATUS_SCRIPT"
  media_status="$($MEDIA_STATUS_SCRIPT 2>/dev/null || true)"
  [[ "$media_status" == 'healthy' ]] \
    || die 'las monturas media estan missing; no se ejecutaran actualizaciones'
  log 'Monturas media: healthy'
}

run_global_health_check() {
  local attempt

  [[ -x "$HEALTH_CHECK_SCRIPT" ]] || die "falta $HEALTH_CHECK_SCRIPT"
  for attempt in 1 2 3; do
    "$HEALTH_CHECK_SCRIPT" && return 0
    [[ "$attempt" -eq 3 ]] || sleep 5
  done
  return 1
}

validate_backup_file() {
  local file="$1"
  local label="$2"
  local now
  local modified
  local max_age_seconds

  [[ -n "$file" && -f "$file" && -s "$file" ]] \
    || die "no hay backup valido para $label: ${file:-no configurado}"

  now="$(date +%s)"
  modified="$(stat -c %Y "$file")"
  max_age_seconds=$((BACKUP_MAX_AGE_HOURS * 3600))
  (( now - modified <= max_age_seconds )) \
    || die "el backup de $label supera ${BACKUP_MAX_AGE_HOURS}h: $file"

  case "$file" in
    *.tar.gz|*.tgz)
      tar -tzf "$file" >/dev/null || die "backup tar invalido para $label: $file"
      ;;
    *.sql.gz)
      gzip -t "$file" || die "backup gzip invalido para $label: $file"
      ;;
  esac
  log "Backup reciente validado para $label: $file"
}

check_recent_service_backup() {
  local target="$1"
  local backup_key="${BACKUP_KEYS[$target]-}"
  local latest=''
  local file

  if [[ -z "$backup_key" ]]; then
    log "Servicio sin estado respaldado por el stack: $target"
    return 0
  fi

  for file in "$BACKUP_DIR/configs/${backup_key}-"*.tar.gz; do
    [[ -f "$file" ]] || continue
    if [[ -z "$latest" || "$file" -nt "$latest" ]]; then
      latest="$file"
    fi
  done
  validate_backup_file "$latest" "$target"
}

assert_container_safe_for_update() {
  local container_id="$1"
  local service="$2"
  local running
  local socket_mount

  running="$(docker inspect --format '{{.State.Running}}' "$container_id")"
  [[ "$running" == 'true' ]] || die "el servicio no esta running: $service"

  socket_mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}yes{{end}}{{end}}' "$container_id")"
  [[ "$socket_mount" != 'yes' ]] \
    || die "servicio bloqueado por montar docker.sock: $service"
}

wait_for_compose_services() {
  local compose_file="$1"
  local project_dir="$2"
  shift 2
  local -a services=("$@")
  local attempt
  local service
  local container_id
  local running
  local health
  local ready

  for attempt in $(seq 1 45); do
    ready=1
    for service in "${services[@]}"; do
      container_id="$(docker compose --project-directory "$project_dir" -f "$compose_file" ps -q "$service")"
      if [[ -z "$container_id" ]]; then
        ready=0
        break
      fi
      running="$(docker inspect --format '{{.State.Running}}' "$container_id")"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
      if [[ "$running" != 'true' || "$health" == 'unhealthy' || "$health" == 'starting' ]]; then
        ready=0
        break
      fi
    done
    [[ "$ready" -eq 1 ]] && return 0
    sleep 2
  done
  return 1
}

wait_for_target_endpoint() {
  local target="$1"
  local url="${READY_URLS[$target]-}"
  local timeout_seconds="${READY_TIMEOUTS[$target]-180}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local code

  [[ -n "$url" ]] || return 0
  log "Esperando readiness HTTP de $target (maximo ${timeout_seconds}s)"
  while (( $(date +%s) < deadline )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^[0-9]+$ && "$code" -ge 200 && "$code" -lt 400 ]]; then
      log "Readiness HTTP de $target: OK ($code)"
      return 0
    fi
    sleep 5
  done
  log "Readiness HTTP de $target: timeout"
  return 1
}

rollback_compose_services() {
  local target="$1"
  local compose_file="$ROLLBACK_COMPOSE_ROOT/services/$target/docker-compose.yml"
  local project_dir="$ROOT/services/$target"
  shift
  local -a services=("$@")
  local service

  log 'Iniciando rollback del objetivo'
  for service in "${services[@]}"; do
    docker image tag "${OLD_IMAGE_IDS[$service]}" "${OLD_IMAGE_REFS[$service]}"
  done
  docker compose --project-directory "$project_dir" -f "$compose_file" up -d --no-deps --force-recreate "${services[@]}"
  wait_for_compose_services "$compose_file" "$project_dir" "${services[@]}" \
    && wait_for_target_endpoint "$target"
}

restore_portainer() {
  local rollback_name="$1"
  local attempt

  docker rm -f portainer >/dev/null 2>&1 || true
  docker rename "$rollback_name" portainer
  docker start portainer >/dev/null
  for attempt in $(seq 1 30); do
    if curl --insecure --fail --silent https://127.0.0.1:9443/api/system/status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

update_allowed_service() {
  local target="$1"
  local dir
  local compose_file
  local service
  local container_id
  local -a services=()
  declare -gA OLD_IMAGE_IDS=()
  declare -gA OLD_IMAGE_REFS=()

  [[ -n "$target" ]] || die 'falta el servicio objetivo'
  if is_denied "$target"; then
    die "servicio bloqueado por denylist: $target"
  fi
  [[ -n "${UPDATE_DIRS[$target]-}" ]] || die "servicio fuera de allowlist: $target"

  dir="${UPDATE_DIRS[$target]}"
  compose_file="$dir/docker-compose.yml"
  project_dir="$ROOT/services/$target"
  read -r -a services <<< "${UPDATE_SERVICES[$target]}"

  [[ -f "$compose_file" ]] || die "no existe el Compose de $target: $compose_file"
  docker compose --project-directory "$project_dir" -f "$compose_file" config --quiet
  check_media_mounts
  assert_watchtower_stopped
  check_recent_service_backup "$target"
  run_global_health_check

  for service in "${services[@]}"; do
    container_id="$(docker compose --project-directory "$project_dir" -f "$compose_file" ps -q "$service")"
    [[ -n "$container_id" ]] || die "Compose no administra un contenedor running para $service"
    assert_container_safe_for_update "$container_id" "$service"
    OLD_IMAGE_IDS["$service"]="$(docker inspect --format '{{.Image}}' "$container_id")"
    OLD_IMAGE_REFS["$service"]="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
    [[ "${OLD_IMAGE_REFS[$service]}" != sha256:* ]] \
      || die "no se puede preparar rollback de una referencia por digest: $service"
  done

  require_confirmation "$target"
  if [[ "$DRY_RUN" == '1' ]]; then
    run_cmd docker compose --project-directory "$project_dir" -f "$compose_file" pull "${services[@]}"
    run_cmd docker compose --project-directory "$project_dir" -f "$compose_file" up -d --no-deps "${services[@]}"
    status='dry-run'
    return 0
  fi

  run_cmd docker compose --project-directory "$project_dir" -f "$compose_file" pull "${services[@]}"
  if ! run_cmd docker compose --project-directory "$project_dir" -f "$compose_file" up -d --no-deps "${services[@]}"; then
    rollback_compose_services "$target" "${services[@]}" \
      || die "fallo la actualizacion y tambien el rollback de $target"
    die "fallo la actualizacion; $target fue restaurado"
  fi

  if ! wait_for_compose_services "$compose_file" "$project_dir" "${services[@]}" \
    || ! wait_for_target_endpoint "$target" \
    || ! run_global_health_check; then
    rollback_compose_services "$target" "${services[@]}" \
      || die "fallo el health-check y tambien el rollback de $target"
    die "fallo el health-check; $target fue restaurado"
  fi

  status='ok'
}

update_portainer() {
  local rollback_name="portainer-pre-update-$(date '+%Y%m%d-%H%M%S')"
  local restart_policy
  local ready=0
  local attempt

  [[ "$PORTAINER_IMAGE" != *:latest ]] || die 'PORTAINER_IMAGE no puede usar latest'
  check_media_mounts
  assert_watchtower_stopped
  run_global_health_check

  if [[ "$DRY_RUN" == '0' ]]; then
    [[ "$UPDATE_PORTAINER" == '1' ]] || die 'Portainer requiere UPDATE_PORTAINER=1'
    require_confirmation 'portainer'
    validate_backup_file "$PORTAINER_BACKUP_FILE" 'portainer_data'
  else
    log 'DRY_RUN: una actualizacion real exigira UPDATE_PORTAINER=1, CONFIRM_UPDATE=portainer y PORTAINER_BACKUP_FILE'
  fi

  [[ "$(docker inspect --format '{{.State.Running}}' portainer 2>/dev/null || true)" == 'true' ]] \
    || die 'Portainer no esta running'
  [[ "$(docker port portainer 9443/tcp)" == '127.0.0.1:9443' ]] \
    || die 'Portainer no tiene el bind seguro 127.0.0.1:9443'
  [[ "$(docker inspect --format '{{range .Mounts}}{{if and (eq .Destination "/data") (eq .Name "portainer_data")}}yes{{end}}{{end}}' portainer)" == 'yes' ]] \
    || die 'Portainer no usa el volumen esperado portainer_data'
  [[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}yes{{end}}{{end}}' portainer)" == 'yes' ]] \
    || die 'Portainer no tiene el socket Docker esperado'

  restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' portainer)"
  if docker inspect "$rollback_name" >/dev/null 2>&1; then
    die "ya existe el contenedor de rollback: $rollback_name"
  fi
  if [[ "$DRY_RUN" == '1' ]]; then
    run_cmd docker pull "$PORTAINER_IMAGE"
    run_cmd docker stop portainer
    run_cmd docker rename portainer "$rollback_name"
    run_cmd docker run -d --name portainer \
      --restart "$restart_policy" \
      --network bridge \
      --publish 127.0.0.1:9443:9443 \
      --volume /var/run/docker.sock:/var/run/docker.sock \
      --volume portainer_data:/data \
      "$PORTAINER_IMAGE"
    status='dry-run'
    return 0
  fi

  docker pull "$PORTAINER_IMAGE"
  docker stop portainer
  if ! docker rename portainer "$rollback_name"; then
    docker start portainer >/dev/null || true
    die 'no se pudo preparar el contenedor de rollback de Portainer'
  fi
  if ! docker run -d --name portainer \
    --restart "$restart_policy" \
    --network bridge \
    --publish 127.0.0.1:9443:9443 \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume portainer_data:/data \
    "$PORTAINER_IMAGE"; then
    restore_portainer "$rollback_name" \
      || die 'fallo la recreacion de Portainer y tambien el rollback'
    die 'fallo la recreacion de Portainer; se restauro el contenedor anterior'
  fi

  for attempt in $(seq 1 30); do
    if curl --insecure --fail --silent https://127.0.0.1:9443/api/system/status >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    restore_portainer "$rollback_name" \
      || die 'fallo el health-check de Portainer y tambien el rollback'
    die 'Portainer no supero el health-check; se restauro el contenedor anterior'
  fi

  if [[ "$(docker port portainer 9443/tcp)" != '127.0.0.1:9443' ]] \
    || ! run_global_health_check; then
    restore_portainer "$rollback_name" \
      || die 'fallo la validacion final de Portainer y tambien el rollback'
    die 'Portainer no supero la validacion final; se restauro el contenedor anterior'
  fi
  status='ok'
  log "Rollback conservado en el contenedor: $rollback_name"
}

refresh_dashboard_cache() {
  [[ "$DRY_RUN" == '0' && "$status" == 'ok' && "$REFRESH_DASHBOARD_ENABLED" == '1' ]] || return 0
  if [[ -x "$STACK_DASHBOARD_SCRIPT" ]]; then
    if ! "$STACK_DASHBOARD_SCRIPT"; then
      log 'WARN: no se pudo refrescar el cache del dashboard; la actualizacion del servicio sigue siendo valida'
    fi
  fi
  return 0
}

notify_whatsapp() {
  local message="$1"

  [[ "$DRY_RUN" == '0' && "$status" == 'ok' ]] || return 0
  if [[ -z "$WHATSAPP_NOTIFY_TOKEN" || "$WHATSAPP_NOTIFY_TOKEN" == 'CHANGEME' ]]; then
    log 'Skipping WhatsApp notification: token no configurado'
    return 0
  fi

  notify_whatsapp_raw "$message"
}

preview_allowlist() {
  local target

  [[ "$DRY_RUN" == '1' ]] || die 'las actualizaciones en lote estan bloqueadas; use service <servicio>'
  for target in "${!UPDATE_DIRS[@]}"; do
    update_allowed_service "$target"
  done
  status='dry-run'
}

main() {
  validate_settings
  require_cmd docker
  require_cmd flock
  require_cmd curl
  require_cmd jq
  require_cmd tar
  require_cmd gzip

  case "$MODE" in
    help|-h|--help)
      usage
      return 0
      ;;
    list)
      list_policy
      return 0
      ;;
  esac

  setup_logging
  acquire_lock
  log "Starting safe update workflow: mode=$MODE target=${TARGET:-none} dry_run=$DRY_RUN"

  case "$MODE" in
    service)
      update_allowed_service "$TARGET"
      ;;
    media|all)
      [[ "$MODE" != 'all' ]] || log 'System package updates are disabled; previewing media allowlist only'
      preview_allowlist
      ;;
    portainer)
      update_portainer
      ;;
    system)
      die 'las actualizaciones del sistema estan bloqueadas en este script'
      ;;
    *)
      usage
      die "modo desconocido: $MODE"
      ;;
  esac

  summary="Update workflow: mode=$MODE target=${TARGET:-none} status=$status"
  log "$summary"
  refresh_dashboard_cache
  notify_whatsapp "$summary"
  log 'Safe update workflow completed'
}

main "$@"
