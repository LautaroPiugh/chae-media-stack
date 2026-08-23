#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${MEDIA_UPDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BOT_DIR="$ROOT/jellyfin-whatsapp-bot"
UPDATER="$ROOT/scripts/update-media-stack.sh"
HEALTH_CHECK="$ROOT/scripts/health-check.sh"
MEDIA_STATUS="$ROOT/scripts/media-status.sh"
STATE_DIR="${MEDIA_UPDATE_STATE_DIR:-$HOME/.local/state/chae-media-update}"
STATE_FILE="$STATE_DIR/current.json"
LOCK_FILE="$STATE_DIR/queue.lock"
LOG_DIR="$ROOT/logs"
MODE="${1:-}"
JOB_ID="${2:-}"
APPROVED_COMMIT="${3:-}"
APPROVED_TREE_HASH="${4:-}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/media2/backups/stack}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-30}"
WHATSAPP_NOTIFY_URL="${WHATSAPP_NOTIFY_URL:-http://127.0.0.1:3555/notify/system-update}"
WHATSAPP_NOTIFY_TOKEN="${WHATSAPP_UPDATE_NOTIFY_TOKEN:-${WHATSAPP_NOTIFY_TOKEN:-}}"
SERVICES=(flaresolverr prowlarr sonarr radarr bazarr jellyseerr jellyfin subgen tdarr)
declare -Ar BACKUP_KEYS=(
  [flaresolverr]=''
  [prowlarr]='prowlarr'
  [sonarr]='sonarr'
  [radarr]='radarr'
  [bazarr]='bazarr'
  [jellyseerr]='jellyseerr'
  [jellyfin]='jellyfin'
  [subgen]=''
  [tdarr]='tdarr'
)

started_at=''
git_before=''
git_after=''
phase='idle'
current=''
message=''
completed_json='[]'
candidate_image=''
candidate_root=''
old_bot_image_id=''
bot_replaced=0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'falta el comando requerido: %s\n' "$1" >&2
    return 1
  }
}

write_state() {
  local status="$1"
  local finished_at="${2:-}"
  local temp_file

  mkdir -p "$STATE_DIR"
  temp_file="$(mktemp "$STATE_DIR/.current.XXXXXX")"
  jq -n \
    --arg id "$JOB_ID" \
    --arg status "$status" \
    --arg phase "$phase" \
    --arg current "$current" \
    --arg message "$message" \
    --arg startedAt "$started_at" \
    --arg updatedAt "$(date --iso-8601=seconds)" \
    --arg finishedAt "$finished_at" \
    --arg gitBefore "$git_before" \
    --arg gitAfter "$git_after" \
    --argjson completed "$completed_json" \
    --argjson services "$(printf '%s\n' "${SERVICES[@]}" | jq -R . | jq -s .)" \
    '{
      id: $id,
      status: $status,
      phase: $phase,
      current: $current,
      message: $message,
      startedAt: $startedAt,
      updatedAt: $updatedAt,
      finishedAt: $finishedAt,
      gitBefore: $gitBefore,
      gitAfter: $gitAfter,
      completed: $completed,
      services: $services
    }' > "$temp_file"
  mv -f -- "$temp_file" "$STATE_FILE"
}

notify_whatsapp() {
  local text="$1"

  [[ -n "$WHATSAPP_NOTIFY_TOKEN" && "$WHATSAPP_NOTIFY_TOKEN" != CHANGEME* ]] || return 0
  curl -fsS -X POST "$WHATSAPP_NOTIFY_URL" \
    -H 'Content-Type: application/json' \
    -H "x-update-token: $WHATSAPP_NOTIFY_TOKEN" \
    -d "$(jq -nc --arg message "$text" '{message: $message}')" >/dev/null \
    || log 'No se pudo enviar la notificacion de WhatsApp'
}

fail() {
  local reason="$1"

  if [[ "$MODE" != 'run' ]]; then
    printf '%s\n' "$reason" >&2
    exit 1
  fi
  phase='failed'
  message="$reason"
  write_state 'failed' "$(date --iso-8601=seconds)"
  notify_whatsapp "Actualizacion del sistema fallida. Trabajo: $JOB_ID. Fase: ${current:-$phase}. Motivo: $reason"
  log "ERROR: $reason"
  if [[ -n "$candidate_image" ]]; then
    docker image rm "$candidate_image" >/dev/null 2>&1 || true
  fi
  rollback_bot
  cleanup_candidate_root
  exit 1
}

cleanup_candidate_root() {
  [[ -n "$candidate_root" && "$candidate_root" != "$ROOT" ]] || return 0
  if git -C "$ROOT" worktree list --porcelain | while IFS= read -r line; do
    [[ "$line" == "worktree $candidate_root" ]] && exit 0
  done; then
    git -C "$ROOT" worktree remove --force "$candidate_root" >/dev/null 2>&1 || true
  else
    rm -rf -- "$candidate_root"
  fi
}

rollback_bot() {
  [[ "$bot_replaced" == '1' && -n "$old_bot_image_id" ]] || return 0
  log 'Restaurando la imagen anterior del bot'
  docker image tag "$old_bot_image_id" jellyfin-whatsapp-bot:latest \
    || return 1
  docker compose -f "$BOT_DIR/docker-compose.yml" up -d --no-deps --force-recreate --no-build jellyfin-whatsapp-bot \
    || return 1
  wait_for_bot || return 1
  bot_replaced=0
}

on_error() {
  local line="$1"
  local exit_code="$2"

  trap - ERR
  fail "fallo inesperado en la linea $line (codigo $exit_code)"
}

latest_backup() {
  local key="$1"
  local latest=''
  local file

  for file in "$BACKUP_DIR/configs/${key}-"*.tar.gz; do
    [[ -f "$file" ]] || continue
    if [[ -z "$latest" || "$file" -nt "$latest" ]]; then
      latest="$file"
    fi
  done
  printf '%s' "$latest"
}

local_tree_hash() {
  local path

  {
    git -C "$ROOT" diff --binary HEAD --
    while IFS= read -r -d '' path; do
      printf 'untracked:%s:' "$path"
      if [[ -f "$ROOT/$path" ]]; then
        stat -c '%a:' "$ROOT/$path"
        sha256sum "$ROOT/$path"
      fi
    done < <(git -C "$ROOT" ls-files --others --exclude-standard -z | sort -z)
  } | sha256sum | cut -d' ' -f1
}

validate_preview() {
  local service
  local key
  local backup
  local max_age_seconds=$((BACKUP_MAX_AGE_HOURS * 3600))
  local remote_commit
  local dirty='false'
  local tree_hash

  require_cmd docker
  require_cmd git
  require_cmd jq
  require_cmd tar
  [[ -x "$UPDATER" && -x "$HEALTH_CHECK" && -x "$MEDIA_STATUS" ]] \
    || fail 'faltan scripts operativos ejecutables'
  [[ "$($MEDIA_STATUS 2>/dev/null || true)" == 'healthy' ]] \
    || fail 'las monturas media no estan saludables'
  [[ "$(docker inspect --format '{{.State.Running}}' watchtower 2>/dev/null || true)" != 'true' ]] \
    || fail 'Watchtower esta activo'
  for attempt in 1 2 3; do
    "$HEALTH_CHECK" >/dev/null && break
    [[ "$attempt" -eq 3 ]] && fail 'el health-check global no es saludable'
    sleep 5
  done

  git_before="$(git -C "$ROOT" rev-parse HEAD)"
  remote_commit="$(git -C "$ROOT" ls-remote origin refs/heads/main | cut -f1)"
  [[ "$remote_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'no se pudo consultar origin/main'
  git_after="$remote_commit"
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    dirty='true'
  fi
  [[ -z "$(git -C "$ROOT" status --porcelain -- 'services/*/docker-compose.yml')" ]] \
    || fail 'hay Compose de servicios modificados localmente; no existe un rollback seguro'
  tree_hash="$(local_tree_hash)"
  if [[ "$git_before" != "$git_after" && "$dirty" == 'true' ]]; then
    fail 'origin/main tiene cambios pero el arbol local no esta limpio'
  fi

  for service in "${SERVICES[@]}"; do
    docker compose -f "$ROOT/services/$service/docker-compose.yml" config --quiet \
      || fail "Compose invalido para $service"
    key="${BACKUP_KEYS[$service]}"
    if [[ -n "$key" ]]; then
      backup="$(latest_backup "$key")"
      [[ -n "$backup" && -s "$backup" ]] || fail "no hay backup para $service"
      (( $(date +%s) - $(stat -c %Y "$backup") <= max_age_seconds )) \
        || fail "el backup de $service supera ${BACKUP_MAX_AGE_HOURS}h"
      tar -tzf "$backup" >/dev/null || fail "el backup de $service no es valido"
    fi
  done

  jq -n \
    --arg current "$git_before" \
    --arg remote "$git_after" \
    --argjson dirty "$dirty" \
    --arg treeHash "$tree_hash" \
    --argjson services "$(printf '%s\n' "${SERVICES[@]}" | jq -R . | jq -s .)" \
    '{ok: true, git: {current: $current, remote: $remote, dirty: $dirty, treeHash: $treeHash}, services: $services, botRestart: true}'
}

prepare_git_and_bot() {
  local remote_commit
  local service

  phase='git'
  current='origin/main'
  message='Verificando el commit Git aprobado'
  write_state 'running'
  git_before="$(git -C "$ROOT" rev-parse HEAD)"
  [[ "$(local_tree_hash)" == "$APPROVED_TREE_HASH" ]] \
    || fail 'el arbol local cambio despues de la confirmacion; solicite un codigo nuevo'
  git -C "$ROOT" fetch --quiet origin main || fail 'git fetch origin/main fallo'
  remote_commit="$(git -C "$ROOT" rev-parse origin/main)"
  [[ "$remote_commit" == "$APPROVED_COMMIT" ]] \
    || fail 'origin/main cambio despues de la confirmacion; solicite un codigo nuevo'
  git -C "$ROOT" merge-base --is-ancestor HEAD origin/main \
    || fail 'la rama local y origin/main han divergido'
  if [[ "$git_before" != "$remote_commit" ]]; then
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
      || fail 'hay cambios locales; no se mezclaran con una actualizacion remota'
    candidate_root="$STATE_DIR/worktree-$JOB_ID"
    git -C "$ROOT" worktree add --detach "$candidate_root" "$APPROVED_COMMIT" \
      || fail 'no se pudo preparar el worktree del commit aprobado'
  else
    candidate_root="$STATE_DIR/snapshot-$JOB_ID"
    mkdir -p "$candidate_root"
    git -C "$ROOT" ls-files --cached --others --exclude-standard -z \
      | tar --null -C "$ROOT" -T - -cf - \
      | tar -C "$candidate_root" -xf - \
      || fail 'no se pudo crear una copia inmutable del arbol aprobado'
    [[ "$(local_tree_hash)" == "$APPROVED_TREE_HASH" ]] \
      || fail 'el arbol local cambio mientras se preparaba; solicite un codigo nuevo'
  fi
  git_after="$APPROVED_COMMIT"

  for service in "${SERVICES[@]}"; do
    docker compose -f "$candidate_root/services/$service/docker-compose.yml" config --quiet \
      || fail "el Compose aprobado es invalido para $service"
  done

  phase='bot-build'
  current='jellyfin-whatsapp-bot'
  message='Ejecutando pruebas y construyendo la imagen candidata del bot'
  write_state 'running'
  candidate_image="jellyfin-whatsapp-bot:update-$JOB_ID"
  docker build --pull --tag "$candidate_image" "$candidate_root/jellyfin-whatsapp-bot" \
    || fail 'no se pudo construir la imagen candidata del bot'
  docker run --rm --entrypoint pnpm "$candidate_image" test \
    || fail 'fallaron las pruebas de la imagen candidata del bot'
}

update_services() {
  local service

  phase='services'
  for service in "${SERVICES[@]}"; do
    current="$service"
    message="Actualizando $service"
    write_state 'running'
    if ! DRY_RUN=0 \
      CONFIRM_UPDATE="$service" \
      WHATSAPP_NOTIFY_ENABLED=0 \
      REFRESH_DASHBOARD_ENABLED=0 \
      UPDATE_ORCHESTRATED=1 \
      UPDATE_COMPOSE_ROOT="$candidate_root" \
      UPDATE_COMPOSE_PROJECT_ROOT="$ROOT" \
      UPDATE_ROLLBACK_COMPOSE_ROOT="$ROOT" \
      UPDATE_STATE_FILE="$STATE_DIR/service-$service.state" \
      "$UPDATER" service "$service"; then
      fail "fallo la actualizacion de $service; la cola fue detenida"
    fi
    completed_json="$(jq -nc --argjson existing "$completed_json" --arg service "$service" '$existing + [$service]')"
    write_state 'running'
  done
}

apply_approved_git() {
  phase='git-apply'
  current='origin/main'
  message='Aplicando el commit Git aprobado'
  write_state 'running'
  if [[ "$git_before" != "$APPROVED_COMMIT" ]]; then
    git -C "$ROOT" merge --ff-only "$APPROVED_COMMIT" \
      || fail 'el bot fue restaurado porque Git no pudo avanzar al commit aprobado'
  fi
}

wait_for_bot() {
  local attempt
  local response

  [[ -n "$WHATSAPP_NOTIFY_TOKEN" && "$WHATSAPP_NOTIFY_TOKEN" != CHANGEME* ]] \
    || return 1
  for attempt in $(seq 1 60); do
    response="$(curl -fsS --max-time 3 \
      -H "x-update-token: $WHATSAPP_NOTIFY_TOKEN" \
      http://127.0.0.1:3555/update-ready 2>/dev/null || true)"
    if [[ "$(jq -r '.whatsappConnected // false' <<<"$response" 2>/dev/null || true)" == 'true' ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

replace_bot() {
  local candidate_compose="$candidate_root/jellyfin-whatsapp-bot/docker-compose.yml"

  phase='bot-restart'
  current='jellyfin-whatsapp-bot'
  message='Reiniciando el bot con la imagen candidata'
  write_state 'running'
  old_bot_image_id="$(docker inspect --format '{{.Image}}' jellyfin-whatsapp-bot 2>/dev/null)" \
    || fail 'no se pudo identificar la imagen anterior del bot'
  docker image tag "$candidate_image" jellyfin-whatsapp-bot:latest \
    || fail 'no se pudo promover la imagen candidata del bot'
  bot_replaced=1
  if ! docker compose --project-directory "$BOT_DIR" -f "$candidate_compose" up -d --no-deps --force-recreate --no-build jellyfin-whatsapp-bot \
    || ! wait_for_bot; then
    log 'La imagen candidata no quedo lista; iniciando rollback del bot'
    rollback_bot || fail 'fallo el bot candidato y tambien su rollback'
    fail 'el bot candidato no reconecto; se restauro la imagen anterior'
  fi
  docker image rm "$candidate_image" >/dev/null 2>&1 || true
}

run_update() {
  [[ "$JOB_ID" =~ ^[0-9a-f]{16,32}$ ]] || {
    printf 'identificador de trabajo invalido\n' >&2
    exit 2
  }
  [[ "$APPROVED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'commit aprobado invalido\n' >&2
    exit 2
  }
  [[ "$APPROVED_TREE_HASH" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'huella aprobada invalida\n' >&2
    exit 2
  }

  mkdir -p "$STATE_DIR" "$LOG_DIR"
  if [[ -n "${UPDATE_QUEUE_LOCK_FD:-}" && -e "/proc/$$/fd/$UPDATE_QUEUE_LOCK_FD" ]]; then
    eval "exec 9>&$UPDATE_QUEUE_LOCK_FD"
  else
    exec 9>"$LOCK_FILE"
    flock -n 9 || {
      printf 'ya hay una cola de actualizacion en ejecucion\n' >&2
      exit 3
    }
  fi
  exec > >(tee -a "$LOG_DIR/media-stack-job-$JOB_ID.log") 2>&1
  trap 'on_error "$LINENO" "$?"' ERR
  require_cmd curl
  require_cmd docker
  require_cmd git
  require_cmd jq
  started_at="$(date --iso-8601=seconds)"
  phase='preflight'
  message='Validando el servidor'
  write_state 'running'
  validate_preview >/dev/null
  prepare_git_and_bot
  update_services
  replace_bot
  apply_approved_git

  phase='dashboard'
  current='stack-dashboard'
  message='Actualizando el dashboard final'
  write_state 'running'
  "$ROOT/scripts/generate-stack-dashboard-data.sh" \
    || log 'WARN: no se pudo refrescar el dashboard final'

  if [[ "$git_before" != "$git_after" ]]; then
    phase='broker-reload'
    current='media-update-broker'
    message='Programando la recarga del broker aprobado'
    write_state 'running'
    require_cmd systemd-run
    install -m 644 "$ROOT/scripts/systemd/media-update-broker.service" \
      "$HOME/.config/systemd/user/media-update-broker.service" \
      || fail 'no se pudo instalar la unidad nueva del broker'
    systemctl --user daemon-reload \
      || fail 'no se pudo recargar systemd para el broker'
    systemd-run --user \
      --unit="media-update-broker-restart-$JOB_ID" \
      --on-active=5s \
      /usr/bin/systemctl --user restart media-update-broker.service >/dev/null \
      || fail 'no se pudo programar la recarga del broker'
  fi

  trap - ERR
  phase='completed'
  current=''
  message='Git, servicios Docker y bot actualizados correctamente'
  write_state 'completed' "$(date --iso-8601=seconds)"
  notify_whatsapp "Actualizacion del sistema completada. Trabajo: $JOB_ID. Servicios: ${SERVICES[*]}. Git: ${git_before:0:8} -> ${git_after:0:8}."
  log "$message"
  cleanup_candidate_root
}

case "$MODE" in
  preview)
    JOB_ID='preview'
    started_at="$(date --iso-8601=seconds)"
    validate_preview
    ;;
  run)
    run_update
    ;;
  *)
    printf 'Uso: %s preview | run <job-id> <commit-aprobado> <huella-local>\n' "$0" >&2
    exit 2
    ;;
esac
