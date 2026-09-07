#!/usr/bin/env bash
set -Eeuo pipefail

MEDIA1_PATH="${MEDIA1_PATH:-/mnt/media1}"
MEDIA2_PATH="${MEDIA2_PATH:-/mnt/media2}"
MEDIA_POOL_PATH="${MEDIA_POOL_PATH:-/mnt/media}"
MEDIA1_UUID="${MEDIA1_UUID:-E41C8ED01C8E9CE4}"
MEDIA2_UUID="${MEDIA2_UUID:-3FD22A422077368D}"
MEDIA3_PATH="${MEDIA3_PATH:-/mnt/media3}"
MEDIA3_UUID="${MEDIA3_UUID:-f5b48469-5ece-4e75-a90d-7ff6a93c4dfe}"
MEDIA4_PATH="${MEDIA4_PATH:-/mnt/media4}"
MEDIA4_UUID="${MEDIA4_UUID:-a4325f7b-fd22-4a64-8f1e-fd90483740c5}"
DRY_RUN="${DRY_RUN:-0}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-1}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
START_TIMEOUT="${START_TIMEOUT:-30}"
RECOVERY_RETRY_SECONDS="${RECOVERY_RETRY_SECONDS:-300}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${MEDIA_MOUNT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/media-mount-recovery}"
STATE_FILE="$STATE_DIR/last_state"
STOPPED_FILE="$STATE_DIR/stopped-containers"
LAST_ATTEMPT_FILE="$STATE_DIR/last-recovery-attempt"
LOG_FILE="${MEDIA_RECOVERY_LOG_FILE:-$STATE_DIR/recovery.log}"
LOCK_FILE="${MEDIA_MOUNT_LOCK_FILE:-$STATE_DIR/mount-operations.lock}"
HEALTH_REASON='not checked'

umask 077
if [[ "$EUID" -eq 0 ]]; then
  printf 'ERROR: media-mount-recovery.sh debe ejecutarse como el usuario del stack, no como root\n' >&2
  exit 2
fi
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local message="[$(timestamp)] $*"
  if [[ "$DRY_RUN" == '1' ]]; then
    printf '%s\n' "$message"
  else
    printf '%s\n' "$message" >> "$LOG_FILE"
  fi
}

write_atomic() {
  local destination="$1"
  local value="$2"
  local temporary

  temporary="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  printf '%s\n' "$value" > "$temporary"
  mv -- "$temporary" "$destination"
}

is_rw_mount() {
  local path="$1"
  local options
  options="$(findmnt -rn -o OPTIONS --target "$path" 2>/dev/null || true)"
  [[ ",$options," == *,rw,* ]]
}

branch_is_healthy() {
  local path="$1"
  local expected_uuid="$2"
  local current_uuid

  [[ -d "$path" ]] || { HEALTH_REASON="$path no existe"; return 1; }
  [[ -e "/dev/disk/by-uuid/$expected_uuid" ]] || { HEALTH_REASON="no esta presente UUID=$expected_uuid"; return 1; }
  mountpoint -q "$path" || { HEALTH_REASON="$path no esta montado"; return 1; }
  current_uuid="$(findmnt -rn -o UUID --target "$path" 2>/dev/null || true)"
  [[ "$current_uuid" == "$expected_uuid" ]] || {
    HEALTH_REASON="$path usa UUID=${current_uuid:-desconocido}, esperado UUID=$expected_uuid"
    return 1
  }
  is_rw_mount "$path" || { HEALTH_REASON="$path no esta montado rw"; return 1; }
}

media_is_healthy() {
  local command_line
  local executable
  local argument
  local branches_found
  local mountpoint_found
  local fs_type
  local pool_process_found=0
  local required
  local -a arguments=()

  branch_is_healthy "$MEDIA1_PATH" "$MEDIA1_UUID" || return 1
  branch_is_healthy "$MEDIA2_PATH" "$MEDIA2_UUID" || return 1
  branch_is_healthy "$MEDIA3_PATH" "$MEDIA3_UUID" || return 1
  branch_is_healthy "$MEDIA4_PATH" "$MEDIA4_UUID" || return 1
  [[ -d "$MEDIA_POOL_PATH" ]] || { HEALTH_REASON="$MEDIA_POOL_PATH no existe"; return 1; }
  mountpoint -q "$MEDIA_POOL_PATH" || { HEALTH_REASON="$MEDIA_POOL_PATH no esta montado"; return 1; }
  fs_type="$(findmnt -rn -o FSTYPE --target "$MEDIA_POOL_PATH" 2>/dev/null || true)"
  [[ "$fs_type" == 'fuse.mergerfs' ]] || {
    HEALTH_REASON="$MEDIA_POOL_PATH usa ${fs_type:-un filesystem desconocido}, no fuse.mergerfs"
    return 1
  }
  for command_line in /proc/[0-9]*/cmdline; do
    arguments=()
    mapfile -d '' -t arguments < "$command_line" 2>/dev/null || continue
    [[ "${#arguments[@]}" -ge 3 ]] || continue
    executable="${arguments[0]##*/}"
    [[ "$executable" == 'mergerfs' ]] || continue
    branches_found=0
    mountpoint_found=0
    for argument in "${arguments[@]:1}"; do
      [[ "$argument" == "$MEDIA1_PATH:$MEDIA2_PATH:$MEDIA3_PATH:$MEDIA4_PATH" ]] && branches_found=1
      [[ "$argument" == "$MEDIA_POOL_PATH" ]] && mountpoint_found=1
    done
    if [[ "$branches_found" -eq 1 && "$mountpoint_found" -eq 1 ]]; then
      pool_process_found=1
      break
    fi
  done
  [[ "$pool_process_found" -eq 1 ]] || {
    HEALTH_REASON="$MEDIA_POOL_PATH no usa las ramas esperadas $MEDIA1_PATH:$MEDIA2_PATH:$MEDIA3_PATH:$MEDIA4_PATH"
    return 1
  }
  is_rw_mount "$MEDIA_POOL_PATH" || { HEALTH_REASON="$MEDIA_POOL_PATH no esta montado rw"; return 1; }

  for required in movies series downloads; do
    [[ -d "$MEDIA_POOL_PATH/$required" ]] || {
      HEALTH_REASON="falta $MEDIA_POOL_PATH/$required"
      return 1
    }
  done
  HEALTH_REASON='all media mounts are healthy'
}

get_running_media_consumers() {
  local -n result="$1"
  local container_id
  local container_ids
  local mounts
  local name
  local source
  local -A seen=()

  result=()
  docker info >/dev/null 2>&1 || return 1
  container_ids="$(docker ps -q)" || return 1

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    name="$(docker inspect --format '{{.Name}}' "$container_id")" || return 1
    name="${name#/}"
    [[ -n "$name" ]] || return 1
    mounts="$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$container_id")" || return 1

    while IFS= read -r source; do
      if [[ "$source" == "$MEDIA_POOL_PATH" || "$source" == "$MEDIA_POOL_PATH/"* \
        || "$source" == "$MEDIA1_PATH" || "$source" == "$MEDIA1_PATH/"* \
        || "$source" == "$MEDIA2_PATH" || "$source" == "$MEDIA2_PATH/"* \
        || "$source" == "$MEDIA3_PATH" || "$source" == "$MEDIA3_PATH/"* \
        || "$source" == "$MEDIA4_PATH" || "$source" == "$MEDIA4_PATH/"* ]]; then
        if [[ -z "${seen[$name]:-}" ]]; then
          result+=("$name")
          seen["$name"]=1
        fi
        break
      fi
    done <<< "$mounts"
  done <<< "$container_ids"
}

container_exists() {
  local error

  docker info >/dev/null 2>&1 || return 2
  if error="$(docker inspect "$1" 2>&1)"; then
    return 0
  fi
  docker info >/dev/null 2>&1 || return 2
  case "$error" in
    *'No such object:'*|*'No such container:'*) return 1 ;;
    *) return 2 ;;
  esac
}

container_is_running() {
  local error
  local state
  if state="$(docker inspect --format '{{.State.Running}}' "$1" 2>&1)"; then
    [[ "$state" == 'true' ]]
    return
  fi
  error="$state"
  docker info >/dev/null 2>&1 || return 2
  case "$error" in
    *'No such object:'*|*'No such container:'*) return 1 ;;
    *) return 2 ;;
  esac
}

remember_stopped_container() {
  local container="$1"
  local temporary
  local -A names=()
  local existing

  if [[ -f "$STOPPED_FILE" ]]; then
    while IFS= read -r existing; do
      [[ -n "$existing" ]] && names["$existing"]=1
    done < "$STOPPED_FILE"
  fi
  names["$container"]=1

  temporary="$(mktemp "$STATE_DIR/.stopped.XXXXXX")" || return 1
  printf '%s\n' "${!names[@]}" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -- "$temporary" "$STOPPED_FILE" || { rm -f -- "$temporary"; return 1; }
}

stop_active_consumers() {
  local consumers=()
  local remaining_consumers=()
  local container
  local failed=0

  get_running_media_consumers consumers || {
    log "ERROR: no se pudo consultar Docker; no se asume que no hay consumidores"
    return 1
  }
  if [[ "${#consumers[@]}" -gt 0 && "$STOP_ON_FAILURE" != '1' ]]; then
    log "ERROR: hay consumidores activos pero STOP_ON_FAILURE=0: ${consumers[*]}"
    return 1
  fi

  for container in "${consumers[@]}"; do
    log "Deteniendo $container porque las monturas no estan sanas: $HEALTH_REASON"
    if ! remember_stopped_container "$container"; then
      log "ERROR: no se pudo registrar $container; no se intentara detenerlo"
      failed=1
      continue
    fi
    if docker stop --time "$STOP_TIMEOUT" "$container" >> "$LOG_FILE" 2>&1; then
      :
    else
      log "ERROR: no se pudo detener $container"
      failed=1
    fi
  done
  if ! get_running_media_consumers remaining_consumers; then
    log "ERROR: no se pudo repetir el inventario Docker tras detener consumidores"
    return 1
  fi
  if [[ "${#remaining_consumers[@]}" -gt 0 ]]; then
    log "ERROR: siguen activos consumidores de medios: ${remaining_consumers[*]}"
    return 1
  fi
  return "$failed"
}

wait_until_running() {
  local container="$1"
  local deadline=$((SECONDS + START_TIMEOUT))

  while (( SECONDS < deadline )); do
    container_is_running "$container" && return 0
    sleep 1
  done
  container_is_running "$container"
}

retry_window_elapsed() {
  local last_attempt=0
  local now

  [[ -f "$LAST_ATTEMPT_FILE" ]] && last_attempt="$(<"$LAST_ATTEMPT_FILE")"
  [[ "$last_attempt" =~ ^[0-9]+$ ]] || last_attempt=0
  now="$(date +%s)"
  (( now - last_attempt >= RECOVERY_RETRY_SECONDS ))
}

recover_stopped_containers() {
  local containers=()
  local started=()
  local container
  local exists_status
  local failed=0
  local rollback_failed
  local running_status

  [[ -s "$STOPPED_FILE" ]] || return 0
  mapfile -t containers < "$STOPPED_FILE"
  [[ "${#containers[@]}" -gt 0 ]] || return 0

  write_atomic "$STATE_FILE" 'recovering'
  write_atomic "$LAST_ATTEMPT_FILE" "$(date +%s)"

  for container in "${containers[@]}"; do
    media_is_healthy || {
      log "ERROR: se aborto la recuperacion antes de iniciar $container: $HEALTH_REASON"
      failed=1
      break
    }
    if container_exists "$container"; then
      :
    else
      exists_status=$?
      if [[ "$exists_status" -eq 2 ]]; then
        log "ERROR: Docker dejo de responder durante la recuperacion"
        failed=1
        break
      fi
      log "WARN: el contenedor registrado ya no existe: $container"
      continue
    fi
    if container_is_running "$container"; then
      log "$container ya estaba running; no se reinicia"
      continue
    fi

    log "Iniciando contenedor detenido por la perdida de montura: $container"
    if ! docker start "$container" >> "$LOG_FILE" 2>&1; then
      log "ERROR: no se pudo iniciar $container"
      failed=1
      break
    fi
    started+=("$container")
    if ! wait_until_running "$container"; then
      log "ERROR: $container no quedo en estado running"
      failed=1
      break
    fi
  done

  if ! media_is_healthy; then
    log "ERROR: las monturas dejaron de estar sanas durante la recuperacion: $HEALTH_REASON"
    if stop_active_consumers; then
      write_atomic "$STATE_FILE" 'missing'
    else
      write_atomic "$STATE_FILE" 'rollback_failed'
    fi
    return 1
  fi

  if [[ "$failed" -ne 0 ]]; then
    rollback_failed=0
    for container in "${started[@]}"; do
      if container_is_running "$container"; then
        log "Deteniendo $container porque la recuperacion no pudo completarse de forma integra"
        if ! docker stop --time "$STOP_TIMEOUT" "$container" >> "$LOG_FILE" 2>&1; then
          log "ERROR: fallo el rollback de $container"
          rollback_failed=1
        else
          if container_is_running "$container"; then
            log "ERROR: $container continua running tras el rollback"
            rollback_failed=1
          else
            running_status=$?
            if [[ "$running_status" -eq 2 ]]; then
              log "ERROR: Docker fallo al verificar el rollback de $container"
              rollback_failed=1
            fi
          fi
        fi
      else
        running_status=$?
        if [[ "$running_status" -eq 2 ]]; then
          log "ERROR: Docker fallo durante el rollback de $container"
          rollback_failed=1
        fi
      fi
    done
    if [[ "$rollback_failed" -ne 0 ]]; then
      write_atomic "$STATE_FILE" 'rollback_failed'
    else
      write_atomic "$STATE_FILE" 'recovery_failed'
    fi
    return 1
  fi

  rm -f -- "$STOPPED_FILE" "$LAST_ATTEMPT_FILE"
  write_atomic "$STATE_FILE" 'healthy'
  log "Recuperacion completada; todos los contenedores registrados quedaron running"
}

[[ "$DRY_RUN" == '0' || "$DRY_RUN" == '1' ]] || { printf 'DRY_RUN debe ser 0 o 1\n' >&2; exit 2; }
[[ "$STOP_ON_FAILURE" == '0' || "$STOP_ON_FAILURE" == '1' ]] || { printf 'STOP_ON_FAILURE debe ser 0 o 1\n' >&2; exit 2; }
[[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || { printf 'STOP_TIMEOUT debe ser un entero\n' >&2; exit 2; }
[[ "$START_TIMEOUT" =~ ^[0-9]+$ ]] || { printf 'START_TIMEOUT debe ser un entero\n' >&2; exit 2; }
[[ "$RECOVERY_RETRY_SECONDS" =~ ^[0-9]+$ ]] || { printf 'RECOVERY_RETRY_SECONDS debe ser un entero\n' >&2; exit 2; }

for command in findmnt mountpoint mktemp mv flock docker; do
  command -v "$command" >/dev/null 2>&1 || { log "ERROR: comando requerido no encontrado: $command"; exit 2; }
done

if [[ "$DRY_RUN" != '1' ]]; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "WARN: otra operacion de monturas esta en ejecucion"
    exit 75
  fi
fi

if media_is_healthy; then
  current_state='healthy'
else
  current_state='missing'
fi

last_state='unknown'
[[ -f "$STATE_FILE" ]] && last_state="$(<"$STATE_FILE")"

if [[ "$DRY_RUN" == '1' ]]; then
  log "DRY_RUN: estado actual=$current_state estado anterior=$last_state"
  log "DRY_RUN: motivo=$HEALTH_REASON"
  if [[ "$current_state" == 'missing' ]]; then
    dry_consumers=()
    get_running_media_consumers dry_consumers || {
      log "ERROR: no se pudo consultar Docker de forma confiable"
      exit 2
    }
    if [[ "${#dry_consumers[@]}" -gt 0 ]]; then
      log "DRY_RUN: detendria consumidores activos: ${dry_consumers[*]}"
    fi
    exit 1
  fi
  if [[ -s "$STOPPED_FILE" ]]; then
    mapfile -t dry_stopped < "$STOPPED_FILE"
    log "DRY_RUN: iniciaria contenedores registrados: ${dry_stopped[*]}"
  fi
  exit 0
fi

if [[ "$current_state" == 'missing' ]]; then
  if ! stop_active_consumers; then
    write_atomic "$STATE_FILE" 'protection_failed'
    log "ERROR: no se pudieron detener todos los consumidores"
    exit 1
  fi
  write_atomic "$STATE_FILE" 'missing'
  if [[ "$last_state" != 'missing' ]]; then
    log "Estado de monturas: $last_state -> missing ($HEALTH_REASON)"
  fi
  exit 1
fi

if [[ "$last_state" == 'recovery_failed' || "$last_state" == 'rollback_failed' ]] \
  && ! retry_window_elapsed; then
  log "Recuperacion en espera por backoff de ${RECOVERY_RETRY_SECONDS}s"
  exit 1
fi

if [[ -s "$STOPPED_FILE" ]]; then
  recover_stopped_containers
  exit $?
fi

if [[ "$last_state" != 'healthy' ]]; then
  write_atomic "$STATE_FILE" 'healthy'
  log "Estado de monturas: $last_state -> healthy; no habia contenedores pendientes de iniciar"
fi

exit 0
