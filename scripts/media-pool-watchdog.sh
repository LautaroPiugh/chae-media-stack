#!/usr/bin/env bash
# Watchdog del pool de medios: remonta ramas caídas y el pool mergerfs.
# Corre como root vía media-pool-watchdog.service (timer cada 2 min) o a mano:
#   sudo systemctl start media-pool-watchdog.service
#   sudo bash /home/chae/stack/scripts/media-pool-watchdog.sh
set -u

LOG="${MEDIA_POOL_WATCHDOG_LOG:-/var/log/media-pool-watchdog.log}"
CONFIG="${MEDIA_BRANCHES_CONFIG:-/home/chae/stack/.media-branches.conf}"
LOCK_FILE="${MEDIA_POOL_WATCHDOG_LOCK:-/run/media-pool-watchdog.lock}"
MERGERFS_OPTS='defaults,allow_other,use_ino,cache.files=off,category.create=mfs,minfreespace=20G'

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG"; }

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

config_get() {
  local key="$1"
  [[ -f "$CONFIG" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG"
}

if [[ ! -f "$CONFIG" ]]; then
  log "ERROR: falta $CONFIG"
  exit 2
fi

POOL="$(config_get MEDIA_POOL)"
POOL="${POOL:-/mnt/media}"
branches_raw="$(config_get MEDIA_BRANCHES)"
uuids_raw="$(config_get MEDIA_UUIDS)"
if [[ -z "$branches_raw" || -z "$uuids_raw" ]]; then
  log "ERROR: $CONFIG incompleto"
  exit 2
fi
IFS=':' read -ra BRANCHES <<< "$branches_raw"
IFS=':' read -ra UUIDS <<< "$uuids_raw"
if [[ "${#BRANCHES[@]}" -eq 0 || "${#BRANCHES[@]}" -ne "${#UUIDS[@]}" ]]; then
  log "ERROR: ramas y UUIDs no coinciden en $CONFIG"
  exit 2
fi

mounted_something=0
for i in "${!BRANCHES[@]}"; do
  path="${BRANCHES[$i]}"
  uuid="${UUIDS[$i]}"
  mkdir -p "$path"

  if mountpoint -q "$path"; then
    current="$(findmnt -rn -o UUID --target "$path" 2>/dev/null || true)"
    if [[ "$current" != "$uuid" ]]; then
      log "WARN: $path montado con UUID=${current:-?}, esperado $uuid (no se remonta solo)"
    fi
    continue
  fi

  if [[ ! -e "/dev/disk/by-uuid/$uuid" ]]; then
    log "WARN: $path no esta montado y falta el dispositivo UUID=$uuid"
    continue
  fi

  log "Remontando $path (UUID=$uuid)"
  if mount "$path" 2>>"$LOG"; then
    mounted_something=1
    log "OK: $path montado"
  else
    log "ERROR: no se pudo montar $path"
  fi
done

mkdir -p "$POOL"

if ! mountpoint -q "$POOL"; then
  fs="$(findmnt -rn -o FSTYPE --target "$POOL" 2>/dev/null || true)"
  log "Remontando pool $POOL"
  if mount "$POOL" 2>>"$LOG"; then
    log "OK: pool $POOL montado (${fs:-fs desconocido} -> $(findmnt -rn -o FSTYPE --target "$POOL" 2>/dev/null || echo '?'))"
  else
    requires=""
    for b in "${BRANCHES[@]}"; do
      requires+=",x-systemd.requires-mounts-for=$b"
    done
    log "fstab no monto $POOL; intentando mergerfs explicito"
    if mount -t fuse.mergerfs -o "${MERGERFS_OPTS},fsname=media${requires}" "$branches_raw" "$POOL" 2>>"$LOG"; then
      log "OK: pool $POOL montado con mergerfs explicito"
    else
      log "ERROR: no se pudo montar el pool $POOL"
    fi
  fi
elif [[ "$mounted_something" -eq 1 ]]; then
  if umount "$POOL" 2>>"$LOG"; then
    if mount "$POOL" 2>>"$LOG"; then
      log "OK: pool $POOL remontado para ver las ramas recien montadas"
    else
      log "ERROR: se umounteo $POOL pero no se pudo volver a montar"
    fi
  else
    log "WARN: $POOL ocupado, no se remonta (vista posiblemente vieja hasta el proximo ciclo)"
  fi
fi

exit 0
