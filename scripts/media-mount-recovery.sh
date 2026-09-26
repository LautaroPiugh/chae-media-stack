#!/usr/bin/env bash
set -Eeuo pipefail

MEDIA_POOL_PATH="${MEDIA_POOL_PATH:-/mnt/media}"
CONFIG_FILE="${MEDIA_BRANCHES_CONFIG:-/home/chae/stack/.media-branches.conf}"
DRY_RUN="${DRY_RUN:-0}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-1}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
START_TIMEOUT="${START_TIMEOUT:-30}"
RECOVERY_RETRY_SECONDS="${RECOVERY_RETRY_SECONDS:-300}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${MEDIA_MOUNT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/media-mount-recovery}"
FSTAB="${MEDIA_FSTAB:-/etc/fstab}"
STATE_FILE="$STATE_DIR/last_state"
STOPPED_FILE="$STATE_DIR/stopped-containers"
LAST_ATTEMPT_FILE="$STATE_DIR/last-recovery-attempt"
LOG_FILE="${MEDIA_RECOVERY_LOG_FILE:-$STATE_DIR/recovery.log}"
LOCK_FILE="${MEDIA_MOUNT_LOCK_FILE:-$STATE_DIR/mount-operations.lock}"
HEALTH_REASON='not checked'
BRANCH_PATHS=()
BRANCH_UUIDS=()
EXPECTED_BRANCHES=''

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

config_get() {
  local key="$1"
  [[ -f "$CONFIG_FILE" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG_FILE"
}

# Inventario persistente esperado: qué dice /etc/fstab.
#
# Es la referencia dura porque fstab y .media-branches.conf los regenera juntos
# el mismo script (fix-media-mounts.sh / add-media-disk.sh). Si discrepan,
# la config esta corrupta.
#
# NO se valida acá que el dispositivo exista: que el disco este fisicamente
# ausente es degradacion operativa, y la detecta branch_is_healthy. Acá solo
# se valida coherencia estructural.
declare -A FSTAB_BRANCH_UUID=()

load_fstab_inventory() {
  local uuid target
  # declare -gA y no solo declare -A arriba: si un caller asigno la variable
  # como array indexada, ${arr[/mnt/media1]} explota con "arithmetic syntax
  # error". Redeclararla aqui la hace autonoma de quien la invoque.
  declare -gA FSTAB_BRANCH_UUID=()
  if [[ ! -r "$FSTAB" ]]; then
    log "ERROR: no se puede leer $FSTAB — no puedo validar la configuracion"
    return 1
  fi
  # "|| [[ -n ${uuid:-} ]]" para no perder la ultima linea si el archivo no
  # termina en newline: sin eso la ultima rama se cae del inventario y el
  # cruce con la conf falla con un error que no dice la causa real.
  while read -r uuid target _ || [[ -n "${uuid:-}" ]]; do
    [[ "$uuid" == UUID=* ]] || continue
    [[ "$target" =~ ^/mnt/media[0-9]+$ ]] || continue
    uuid="${uuid#UUID=}"
    if [[ -n "${FSTAB_BRANCH_UUID[$target]:-}" ]]; then
      log "ERROR: $FSTAB declara $target dos veces (${FSTAB_BRANCH_UUID[$target]} y $uuid)"
      return 1
    fi
    FSTAB_BRANCH_UUID["$target"]="$uuid"
  done < "$FSTAB"
  if [[ "${#FSTAB_BRANCH_UUID[@]}" -eq 0 ]]; then
    log "ERROR: $FSTAB no declara ninguna rama /mnt/mediaN"
    return 1
  fi
}

# Valida la forma de las listas y su correspondencia con fstab.
# Cualquier contradicción estructural es config inválida: ERROR persistido y
# return 1, para que main haga exit 2 sin tocar un contenedor.
load_media_config() {
  local branches_raw uuids_raw
  local i path uuid
  local -A seen_paths=()
  local -A seen_uuids=()

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: falta $CONFIG_FILE (generar con: sudo bash /home/chae/stack/fix-media-mounts.sh)"
    return 1
  fi
  branches_raw="$(config_get MEDIA_BRANCHES || true)"
  uuids_raw="$(config_get MEDIA_UUIDS || true)"
  if [[ -z "$branches_raw" || -z "$uuids_raw" ]]; then
    log "ERROR: $CONFIG_FILE sin MEDIA_BRANCHES/MEDIA_UUIDS"
    return 1
  fi
  IFS=':' read -ra BRANCH_PATHS <<< "$branches_raw"
  IFS=':' read -ra BRANCH_UUIDS <<< "$uuids_raw"

  if [[ "${#BRANCH_PATHS[@]}" -eq 0 || "${#BRANCH_UUIDS[@]}" -eq 0 ]]; then
    log "ERROR: $CONFIG_FILE declara una lista vacia (paths=${#BRANCH_PATHS[@]} uuids=${#BRANCH_UUIDS[@]})"
    return 1
  fi
  if [[ "${#BRANCH_PATHS[@]}" -ne "${#BRANCH_UUIDS[@]}" ]]; then
    log "ERROR: $CONFIG_FILE rutas y UUIDs no coinciden (${#BRANCH_PATHS[@]} vs ${#BRANCH_UUIDS[@]})"
    return 1
  fi

  load_fstab_inventory || return 1

  for i in "${!BRANCH_PATHS[@]}"; do
    path="${BRANCH_PATHS[$i]}"
    uuid="${BRANCH_UUIDS[$i]}"

    # namespace esperado
    if [[ ! "$path" =~ ^/mnt/media[0-9]+$ ]]; then
      log "ERROR: $CONFIG_FILE declara una ruta fuera del namespace esperado: $path"
      return 1
    fi
    # forma de UUID
    if [[ ! "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      log "ERROR: $CONFIG_FILE declara un UUID con formato invalido para $path: $uuid"
      return 1
    fi
    # duplicados
    if [[ -n "${seen_paths[$path]:-}" ]]; then
      log "ERROR: $CONFIG_FILE repite la ruta $path"
      return 1
    fi
    seen_paths["$path"]=1
    if [[ -n "${seen_uuids[$uuid]:-}" ]]; then
      log "ERROR: $CONFIG_FILE repite el UUID $uuid (en $path y ${seen_uuids[$uuid]})"
      return 1
    fi
    seen_uuids["$uuid"]="$path"
    # correspondencia con el inventario persistente
    if [[ -z "${FSTAB_BRANCH_UUID[$path]:-}" ]]; then
      log "ERROR: $CONFIG_FILE declara $path pero $FSTAB no lo monta"
      return 1
    fi
    if [[ "${FSTAB_BRANCH_UUID[$path]}" != "$uuid" ]]; then
      log "ERROR: $path declara UUID=$uuid en $CONFIG_FILE pero $FSTAB dice ${FSTAB_BRANCH_UUID[$path]}"
      return 1
    fi
  done

  # al revés: toda rama de fstab tiene que estar declarada en la config
  for path in "${!FSTAB_BRANCH_UUID[@]}"; do
    if [[ -z "${seen_paths[$path]:-}" ]]; then
      log "ERROR: $FSTAB monta $path pero $CONFIG_FILE no la declara"
      return 1
    fi
  done

  EXPECTED_BRANCHES="$branches_raw"
  return 0
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
  local i
  local -a arguments=()

  for i in "${!BRANCH_PATHS[@]}"; do
    branch_is_healthy "${BRANCH_PATHS[$i]}" "${BRANCH_UUIDS[$i]}" || return 1
  done
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
      [[ "$argument" == "$EXPECTED_BRANCHES" ]] && branches_found=1
      [[ "$argument" == "$MEDIA_POOL_PATH" ]] && mountpoint_found=1
    done
    if [[ "$branches_found" -eq 1 && "$mountpoint_found" -eq 1 ]]; then
      pool_process_found=1
      break
    fi
  done
  [[ "$pool_process_found" -eq 1 ]] || {
    HEALTH_REASON="$MEDIA_POOL_PATH no usa las ramas esperadas $EXPECTED_BRANCHES"
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
  local branch
  local matched
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
      [[ -n "$source" ]] || continue
      matched=0
      if [[ "$source" == "$MEDIA_POOL_PATH" || "$source" == "$MEDIA_POOL_PATH/"* ]]; then
        matched=1
      else
        for branch in "${BRANCH_PATHS[@]}"; do
          if [[ "$source" == "$branch" || "$source" == "$branch/"* ]]; then
            matched=1
            break
          fi
        done
      fi
      if [[ "$matched" -eq 1 ]]; then
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

for command in findmnt mountpoint mktemp mv flock docker awk; do
  command -v "$command" >/dev/null 2>&1 || { log "ERROR: comando requerido no encontrado: $command"; exit 2; }
done

load_media_config || exit 2

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
