#!/usr/bin/env bash
set -Eeuo pipefail

MEDIA1_PATH="${MEDIA1_PATH:-/mnt/media1}"
MEDIA2_PATH="${MEDIA2_PATH:-/mnt/media2}"
MEDIA_POOL_PATH="${MEDIA_POOL_PATH:-/mnt/media}"
MEDIA1_UUID="${MEDIA1_UUID:-E41C8ED01C8E9CE4}"
MEDIA2_UUID="${MEDIA2_UUID:-3FD22A422077368D}"
BRANCH_FS_TYPE="${BRANCH_FS_TYPE:-ntfs-3g}"
BRANCH_MOUNT_OPTIONS="${BRANCH_MOUNT_OPTIONS:-rw,uid=1000,gid=1000,umask=002}"
MERGERFS_OPTIONS="${MERGERFS_OPTIONS:-rw,allow_other,use_ino,cache.files=off,category.create=mfs,minfreespace=20G,fsname=media}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
START_TIMEOUT="${START_TIMEOUT:-30}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${MEDIA_MOUNT_STATE_DIR:-$PROJECT_DIR/.local/state/media-mount-recovery}"
LOG_FILE="${FIX_MEDIA_LOG_FILE:-$STATE_DIR/fix-media-mounts.log}"
LOCK_FILE="${MEDIA_MOUNT_LOCK_FILE:-$STATE_DIR/mount-operations.lock}"
STOPPED_FILE="$STATE_DIR/stopped-containers"
HEALTH_REASON='not checked'
REPAIR_COMPLETE=0
START_ATTEMPTED=0
STOPPED_CONTAINERS=()
STARTED_CONTAINERS=()

umask 077
if [[ "$EUID" -eq 0 ]]; then
  printf 'ERROR: ejecute este script como usuario normal; el script solicitara sudo cuando sea necesario\n' >&2
  exit 2
fi
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local message="[$(timestamp)] $*"
  printf '%s\n' "$message"
  printf '%s\n' "$message" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "comando requerido no encontrado: $1"
}

run_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_root_access() {
  if [[ "$EUID" -ne 0 ]]; then
    log "Validando privilegios sudo antes de detener servicios..."
    sudo -v || die "se requieren privilegios sudo"
  fi
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

pool_is_healthy() {
  local fs_type
  local required

  [[ -d "$MEDIA_POOL_PATH" ]] || { HEALTH_REASON="$MEDIA_POOL_PATH no existe"; return 1; }
  mountpoint -q "$MEDIA_POOL_PATH" || { HEALTH_REASON="$MEDIA_POOL_PATH no esta montado"; return 1; }
  fs_type="$(findmnt -rn -o FSTYPE --target "$MEDIA_POOL_PATH" 2>/dev/null || true)"
  [[ "$fs_type" == 'fuse.mergerfs' ]] || {
    HEALTH_REASON="$MEDIA_POOL_PATH usa ${fs_type:-un filesystem desconocido}, no fuse.mergerfs"
    return 1
  }
  pool_has_expected_branches || return 1
  is_rw_mount "$MEDIA_POOL_PATH" || { HEALTH_REASON="$MEDIA_POOL_PATH no esta montado rw"; return 1; }

  for required in movies series downloads; do
    [[ -d "$MEDIA_POOL_PATH/$required" ]] || {
      HEALTH_REASON="falta $MEDIA_POOL_PATH/$required"
      return 1
    }
  done
}

pool_has_expected_branches() {
  local command_line
  local executable
  local argument
  local branches_found
  local mountpoint_found
  local -a arguments=()

  for command_line in /proc/[0-9]*/cmdline; do
    arguments=()
    mapfile -d '' -t arguments < "$command_line" 2>/dev/null || continue
    [[ "${#arguments[@]}" -ge 3 ]] || continue
    executable="${arguments[0]##*/}"
    [[ "$executable" == 'mergerfs' ]] || continue
    branches_found=0
    mountpoint_found=0
    for argument in "${arguments[@]:1}"; do
      [[ "$argument" == "$MEDIA1_PATH:$MEDIA2_PATH" ]] && branches_found=1
      [[ "$argument" == "$MEDIA_POOL_PATH" ]] && mountpoint_found=1
    done
    if [[ "$branches_found" -eq 1 && "$mountpoint_found" -eq 1 ]]; then
      return 0
    fi
  done

  HEALTH_REASON="$MEDIA_POOL_PATH no usa las ramas esperadas $MEDIA1_PATH:$MEDIA2_PATH"
  return 1
}

media_is_healthy() {
  command -v mergerfs >/dev/null 2>&1 || { HEALTH_REASON='mergerfs no esta instalado'; return 1; }
  branch_is_healthy "$MEDIA1_PATH" "$MEDIA1_UUID" || return 1
  branch_is_healthy "$MEDIA2_PATH" "$MEDIA2_UUID" || return 1
  pool_is_healthy || return 1
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
        || "$source" == "$MEDIA2_PATH" || "$source" == "$MEDIA2_PATH/"* ]]; then
        if [[ -z "${seen[$name]:-}" ]]; then
          result+=("$name")
          seen["$name"]=1
        fi
        break
      fi
    done <<< "$mounts"
  done <<< "$container_ids"
}

show_mount() {
  local path="$1"
  local details
  details="$(findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS --target "$path" 2>/dev/null || true)"
  if [[ -n "$details" ]]; then
    log "$details"
  else
    log "$path: no montado"
  fi
}

show_diagnostics() {
  local consumers=()
  local media1_device='ausente'
  local media2_device='ausente'

  [[ -e "/dev/disk/by-uuid/$MEDIA1_UUID" ]] && media1_device="$(readlink -f "/dev/disk/by-uuid/$MEDIA1_UUID")"
  [[ -e "/dev/disk/by-uuid/$MEDIA2_UUID" ]] && media2_device="$(readlink -f "/dev/disk/by-uuid/$MEDIA2_UUID")"

  log "Estado de monturas:"
  show_mount "$MEDIA1_PATH"
  show_mount "$MEDIA2_PATH"
  show_mount "$MEDIA_POOL_PATH"
  log "Disco 1: UUID=$MEDIA1_UUID dispositivo=$media1_device"
  log "Disco 2: UUID=$MEDIA2_UUID dispositivo=$media2_device"

  get_running_media_consumers consumers || die "no se pudo consultar Docker de forma confiable"
  if [[ "${#consumers[@]}" -gt 0 ]]; then
    log "Contenedores activos con binds de medios: ${consumers[*]}"
  else
    log "No se detectaron contenedores activos con binds de medios"
  fi
}

print_repair_plan() {
  local consumers=()
  get_running_media_consumers consumers || die "no se pudo consultar Docker de forma confiable"

  log "Plan seguro de reparacion:"
  if [[ "${#consumers[@]}" -gt 0 ]]; then
    log "DRY_RUN: detendria: ${consumers[*]}"
  fi
  if mountpoint -q "$MEDIA_POOL_PATH"; then
    log "DRY_RUN: desmontaria primero el pool mergerfs $MEDIA_POOL_PATH"
  fi
  if ! branch_is_healthy "$MEDIA1_PATH" "$MEDIA1_UUID"; then
    mountpoint -q "$MEDIA1_PATH" && log "DRY_RUN: desmontaria la fuente incorrecta de $MEDIA1_PATH"
    log "DRY_RUN: montaria UUID=$MEDIA1_UUID en $MEDIA1_PATH con $BRANCH_MOUNT_OPTIONS"
  fi
  if ! branch_is_healthy "$MEDIA2_PATH" "$MEDIA2_UUID"; then
    mountpoint -q "$MEDIA2_PATH" && log "DRY_RUN: desmontaria la fuente incorrecta de $MEDIA2_PATH"
    log "DRY_RUN: montaria UUID=$MEDIA2_UUID en $MEDIA2_PATH con $BRANCH_MOUNT_OPTIONS"
  fi
  log "DRY_RUN: crearia el pool $MEDIA1_PATH:$MEDIA2_PATH en $MEDIA_POOL_PATH con $MERGERFS_OPTIONS"
  if [[ "${#consumers[@]}" -gt 0 ]]; then
    log "DRY_RUN: iniciaria nuevamente solo: ${consumers[*]}"
  fi
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
  local existing
  local temporary
  local -A names=()

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

forget_stopped_containers() {
  local existing
  local stopped
  local temporary
  local -A remove=()
  local -a keep=()

  [[ -f "$STOPPED_FILE" ]] || return 0
  for stopped in "$@"; do
    remove["$stopped"]=1
  done
  while IFS= read -r existing; do
    [[ -n "$existing" && -z "${remove[$existing]:-}" ]] && keep+=("$existing")
  done < "$STOPPED_FILE"

  if [[ "${#keep[@]}" -eq 0 ]]; then
    rm -f -- "$STOPPED_FILE"
    return
  fi
  temporary="$(mktemp "$STATE_DIR/.stopped.XXXXXX")" || return 1
  printf '%s\n' "${keep[@]}" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -- "$temporary" "$STOPPED_FILE" || { rm -f -- "$temporary"; return 1; }
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

rollback_started_containers() {
  local container
  local failed=0
  local running_status

  for container in "${STARTED_CONTAINERS[@]}"; do
    if container_is_running "$container"; then
      log "Deteniendo $container porque la secuencia de inicio no se valido completa"
      if ! docker stop --time "$STOP_TIMEOUT" "$container" >> "$LOG_FILE" 2>&1; then
        log "ERROR: fallo el rollback de $container"
        failed=1
      else
        if container_is_running "$container"; then
          log "ERROR: $container continua running tras el rollback"
          failed=1
        else
          running_status=$?
          if [[ "$running_status" -eq 2 ]]; then
            log "ERROR: Docker fallo al verificar el rollback de $container"
            failed=1
          fi
        fi
      fi
    else
      running_status=$?
      if [[ "$running_status" -eq 2 ]]; then
        log "ERROR: Docker fallo durante el rollback de $container"
        failed=1
      fi
    fi
  done
  return "$failed"
}

assert_path_not_busy() {
  local path="$1"
  local error_file
  local output
  local status

  error_file="$(mktemp "$STATE_DIR/.fuser.XXXXXX")"
  if output="$(run_root fuser -m "$path" 2>"$error_file")"; then
    rm -f -- "$error_file"
    die "$path sigue ocupado por procesos: $output"
  else
    status=$?
  fi
  if [[ "$status" -ne 1 || -s "$error_file" ]]; then
    fuser_error="$(<"$error_file")"
    rm -f -- "$error_file"
    die "no se pudo comprobar si $path esta ocupado: ${fuser_error:-fuser exit $status}"
  fi
  rm -f -- "$error_file"
}

start_stopped_containers() {
  local container
  local failed=0

  [[ "${#STOPPED_CONTAINERS[@]}" -gt 0 ]] || return 0
  START_ATTEMPTED=1
  STARTED_CONTAINERS=()
  media_is_healthy || {
    log "ERROR: no se reinician contenedores porque las monturas no estan sanas: $HEALTH_REASON"
    return 1
  }

  for container in "${STOPPED_CONTAINERS[@]}"; do
    if ! media_is_healthy; then
      log "ERROR: las monturas dejaron de estar sanas antes de iniciar $container: $HEALTH_REASON"
      failed=1
      break
    fi
    if container_is_running "$container"; then
      continue
    fi
    log "Iniciando contenedor previamente detenido: $container"
    if ! docker start "$container" >> "$LOG_FILE" 2>&1; then
      log "ERROR: no se pudo iniciar $container"
      failed=1
      break
    fi
    STARTED_CONTAINERS+=("$container")
    if ! wait_until_running "$container"; then
      log "ERROR: $container no quedo en estado running"
      failed=1
      break
    fi
  done

  if ! media_is_healthy; then
    log "ERROR: las monturas no estan sanas al finalizar la secuencia: $HEALTH_REASON"
    failed=1
  fi
  if [[ "$failed" -ne 0 ]]; then
    rollback_started_containers || log "ERROR: rollback incompleto; el journal se conserva"
    return 1
  fi

  forget_stopped_containers "${STOPPED_CONTAINERS[@]}" || {
    log "ERROR: no se pudo actualizar el journal de contenedores"
    rollback_started_containers || log "ERROR: rollback incompleto; el journal se conserva"
    return 1
  }
  return 0
}

on_exit() {
  local status=$?

  if [[ "$status" -ne 0 && "$DRY_RUN" == '0' && "$REPAIR_COMPLETE" -eq 0 \
    && "${#STOPPED_CONTAINERS[@]}" -gt 0 ]]; then
    if [[ "$START_ATTEMPTED" -eq 0 ]] && media_is_healthy; then
      log "La reparacion fallo, pero las monturas estan sanas; restaurando contenedores detenidos"
      start_stopped_containers || true
    elif [[ "$START_ATTEMPTED" -ne 0 ]]; then
      log "La secuencia de inicio fallo; el journal se conserva para recuperacion posterior"
    else
      log "La reparacion fallo y las monturas no estan sanas; los contenedores quedan detenidos"
      log "Motivo: $HEALTH_REASON"
    fi
  fi
}

trap on_exit EXIT

[[ "$DRY_RUN" == '0' || "$DRY_RUN" == '1' ]] || die "DRY_RUN debe ser 0 o 1"
[[ "$FORCE" == '0' || "$FORCE" == '1' ]] || die "FORCE debe ser 0 o 1"
[[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || die "STOP_TIMEOUT debe ser un entero"
[[ "$START_TIMEOUT" =~ ^[0-9]+$ ]] || die "START_TIMEOUT debe ser un entero"

for command in findmnt mountpoint readlink mergerfs flock docker fuser mktemp mv; do
  require_cmd "$command"
done

docker info >/dev/null 2>&1 || die "Docker no esta accesible; se rechaza asumir que no hay consumidores"

exec 9>"$LOCK_FILE"
flock -n 9 || die "otra operacion de monturas esta en ejecucion"

show_diagnostics
if media_is_healthy; then
  log "OK: las monturas ya estan sanas; no se realiza ninguna accion"
  exit 0
fi

log "Estado no saludable: $HEALTH_REASON"

if mountpoint -q "$MEDIA_POOL_PATH"; then
  pool_type="$(findmnt -rn -o FSTYPE --target "$MEDIA_POOL_PATH" 2>/dev/null || true)"
  [[ "$pool_type" == 'fuse.mergerfs' ]] \
    || die "se rechaza desmontar $MEDIA_POOL_PATH porque contiene $pool_type, no mergerfs"
fi

prerequisite_error=''
for path in "$MEDIA1_PATH" "$MEDIA2_PATH" "$MEDIA_POOL_PATH"; do
  if [[ ! -d "$path" ]]; then
    prerequisite_error="el mountpoint requerido no existe: $path"
    break
  fi
done
[[ -n "$prerequisite_error" || -e "/dev/disk/by-uuid/$MEDIA1_UUID" ]] \
  || prerequisite_error="no esta presente UUID=$MEDIA1_UUID"
[[ -n "$prerequisite_error" || -e "/dev/disk/by-uuid/$MEDIA2_UUID" ]] \
  || prerequisite_error="no esta presente UUID=$MEDIA2_UUID"

if [[ -n "$prerequisite_error" ]]; then
  if [[ "$DRY_RUN" == '1' ]]; then
    log "DRY_RUN BLOQUEADO: $prerequisite_error"
    log "No se desmontaria ni detendria nada hasta resolver este requisito"
    exit 1
  fi
  die "$prerequisite_error"
fi

if [[ "$DRY_RUN" == '1' ]]; then
  print_repair_plan
  log "DRY_RUN completado; no se modificaron contenedores ni monturas"
  exit 0
fi

if [[ "$FORCE" != '1' ]]; then
  die "modo diagnostico: use DRY_RUN=1 para ver el plan y FORCE=1 para ejecutar cambios"
fi

ensure_root_access

active_consumers=()
get_running_media_consumers active_consumers || die "no se pudo consultar Docker; no se desmontara nada"
for container in "${active_consumers[@]}"; do
  log "Deteniendo consumidor de medios: $container"
  remember_stopped_container "$container" || die "no se pudo registrar $container antes de detenerlo"
  if docker stop --time "$STOP_TIMEOUT" "$container" >> "$LOG_FILE" 2>&1; then
    STOPPED_CONTAINERS+=("$container")
  else
    die "no se pudo detener $container; no se desmontara nada"
  fi
done

docker info >/dev/null 2>&1 || die "Docker dejo de responder; no se desmontara nada"

for container in "${STOPPED_CONTAINERS[@]}"; do
  if container_is_running "$container"; then
    die "$container continua ejecutandose"
  else
    container_status=$?
    [[ "$container_status" -ne 2 ]] || die "Docker fallo al verificar $container"
  fi
done
docker info >/dev/null 2>&1 || die "Docker dejo de responder durante la verificacion; no se desmontara nada"

remaining_consumers=()
get_running_media_consumers remaining_consumers || die "no se pudo repetir el inventario Docker"
[[ "${#remaining_consumers[@]}" -eq 0 ]] \
  || die "aparecieron consumidores antes de desmontar: ${remaining_consumers[*]}"

if mountpoint -q "$MEDIA_POOL_PATH"; then
  assert_path_not_busy "$MEDIA_POOL_PATH"
  log "Desmontando pool mergerfs: $MEDIA_POOL_PATH"
  run_root umount "$MEDIA_POOL_PATH" || die "fallo umount de $MEDIA_POOL_PATH"
  mountpoint -q "$MEDIA_POOL_PATH" && die "$MEDIA_POOL_PATH continua montado"
fi

if ! branch_is_healthy "$MEDIA1_PATH" "$MEDIA1_UUID"; then
  if mountpoint -q "$MEDIA1_PATH"; then
    assert_path_not_busy "$MEDIA1_PATH"
    log "Desmontando fuente incorrecta de $MEDIA1_PATH"
    run_root umount "$MEDIA1_PATH" || die "fallo umount de $MEDIA1_PATH"
  fi
  log "Montando UUID=$MEDIA1_UUID en $MEDIA1_PATH"
  run_root mount -t "$BRANCH_FS_TYPE" -o "$BRANCH_MOUNT_OPTIONS" "/dev/disk/by-uuid/$MEDIA1_UUID" "$MEDIA1_PATH" \
    || die "no se pudo montar $MEDIA1_PATH"
fi

if ! branch_is_healthy "$MEDIA2_PATH" "$MEDIA2_UUID"; then
  if mountpoint -q "$MEDIA2_PATH"; then
    assert_path_not_busy "$MEDIA2_PATH"
    log "Desmontando fuente incorrecta de $MEDIA2_PATH"
    run_root umount "$MEDIA2_PATH" || die "fallo umount de $MEDIA2_PATH"
  fi
  log "Montando UUID=$MEDIA2_UUID en $MEDIA2_PATH"
  run_root mount -t "$BRANCH_FS_TYPE" -o "$BRANCH_MOUNT_OPTIONS" "/dev/disk/by-uuid/$MEDIA2_UUID" "$MEDIA2_PATH" \
    || die "no se pudo montar $MEDIA2_PATH"
fi

branch_is_healthy "$MEDIA1_PATH" "$MEDIA1_UUID" || die "$HEALTH_REASON"
branch_is_healthy "$MEDIA2_PATH" "$MEDIA2_UUID" || die "$HEALTH_REASON"

log "Creando pool mergerfs en $MEDIA_POOL_PATH"
run_root mergerfs -o "$MERGERFS_OPTIONS" "$MEDIA1_PATH:$MEDIA2_PATH" "$MEDIA_POOL_PATH" \
  || die "no se pudo crear el pool mergerfs"

media_is_healthy || die "la verificacion final de monturas fallo: $HEALTH_REASON"
start_stopped_containers || die "una o mas aplicaciones no quedaron en estado running"

REPAIR_COMPLETE=1
log "Reparacion completada y validada; se restauraron solo los contenedores detenidos por este script"
