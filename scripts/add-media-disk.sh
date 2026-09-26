#!/usr/bin/env bash
# add-media-disk.sh — agrega un disco nuevo al pool de medios como la próxima rama mediaN.
#
# Uso:
#   sudo bash /home/chae/stack/scripts/add-media-disk.sh /dev/disk/by-path/XXXX
#   sudo bash /home/chae/stack/scripts/add-media-disk.sh /dev/disk/by-id/XXXX
#
# Pasá el path ESTABLE (by-path o by-id), no un /dev/sdX: los sdX cambian entre
# reboots. El script resuelve y te muestra el disco real antes de tocar nada.
#
# Formatea el disco (GPT+ext4, label mediaN), lo agrega a la config de ramas,
# al fstab y al drop-in de docker, y remonta el pool con la rama nueva.
set -Eeuo pipefail

# Política de seguridad compartida con fix-media-mounts.sh. Es la MISMA función:
# si una partición está montada, ABORTA. No desmonta y sigue.
# shellcheck source=lib/media-disk-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/media-disk-guard.sh"

POOL_PATH='/mnt/media'
STACK_DIR='/home/chae/stack'
CONFIG_PATH="$STACK_DIR/.media-branches.conf"
FSTAB='/etc/fstab'
DROPIN='/etc/systemd/system/docker.service.d/media-mounts.conf'
GPT_LINUX_TYPE='0FC63DAF-8483-4772-8E79-3D69D8477DE4'
MERGERFS_OPTS='defaults,allow_other,use_ino,cache.files=off,category.create=mfs,minfreespace=20G'
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

B='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
log()  { printf "${B}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf "${G}  ✔ %s${N}\n" "$*"; }
warn() { printf "${Y}  ⚠ %s${N}\n" "$*"; }
die()  { printf "${R}ERROR: %s${N}\n" "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "correr como root: sudo bash $0 /dev/disk/by-path/XXXX"
[[ -f "$CONFIG_PATH" ]] || die "falta $CONFIG_PATH (correr antes fix-media-mounts.sh)"

DEV_ARG="${1:-}"
[[ -n "$DEV_ARG" ]] || die "uso: sudo bash $0 /dev/disk/by-path/XXXX"
[[ -e "$DEV_ARG" ]] || die "no existe $DEV_ARG"
DEV="$(readlink -f "$DEV_ARG")" || die "no se resuelve $DEV_ARG"
# Un archivo regular, un directorio o una partición suelta: no es un disco.
[[ -b "$DEV" ]] || die "$DEV no es un dispositivo de bloque — pasá el disco entero (/dev/disk/by-path/...), no una partición"

# ── banner: mostrame qué disco es, en serio, antes de que escriba nada ──
printf '\n'
log "Disco candidato:"
show_device_banner "$DEV_ARG" || die "no pude leer $DEV_ARG — abortando sin tocar nada"

# ── el guard compartido, antes de cualquier escritura ──
assert_safe_to_wipe "$DEV" \
  || die "guard de seguridad: $DEV NO se puede formatear (ver el motivo arriba).
    Si estaba montado y el desmontaje es intencional, desmontalo vos primero y volvé a correr."

# cargar config actual
get() { awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG_PATH"; }
BRANCHES_JOINED="$(get MEDIA_BRANCHES)"
UUIDS_JOINED="$(get MEDIA_UUIDS)"
POOL_PATH_CFG="$(get MEDIA_POOL)"
[[ -n "$BRANCHES_JOINED" && -n "$UUIDS_JOINED" ]] || die "$CONFIG_PATH incompleto"
POOL_PATH="${POOL_PATH_CFG:-$POOL_PATH}"
IFS=':' read -ra BRANCHES <<< "$BRANCHES_JOINED"
IFS=':' read -ra UUIDS <<< "$UUIDS_JOINED"

# próximo número de rama libre
next_num=1
while :; do
  used=0
  for b in "${BRANCHES[@]}"; do
    [[ "$b" == "/mnt/media$next_num" ]] && used=1
  done
  [[ "$used" -eq 0 ]] && break
  next_num=$((next_num + 1))
done
LABEL="media$next_num"
MOUNT="/mnt/media$next_num"
[[ "$next_num" -le 99 ]] || die "demasiadas ramas"

printf '%s' "$Y"
printf 'Voy a FORMATEAR %s (%s) como GPT+ext4 con label %s y montarlo en %s.\n' \
  "$DEV_ARG" "$DEV" "$LABEL" "$MOUNT"
printf 'Todo lo que está en ese disco se pierde.\n'
printf 'Escribí %sAGREGAR%s para continuar (Ctrl-C aborta): ' "$R" "$N"
read -r answer
[[ "$answer" == 'AGREGAR' ]] || die "abortado — NADA quedó modificado"

log "Formateando $LABEL"
wipefs -a "$DEV" >/dev/null 2>&1 || true
printf 'label: gpt\n,,%s\n' "$GPT_LINUX_TYPE" | sfdisk --wipe always "$DEV" >/dev/null \
  || die "sfdisk falló"
partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

PART=""
for cand in "${DEV}-part1" "${DEV}1" "${DEV}p1"; do
  [[ -b "$cand" ]] && { PART="$cand"; break; }
done
base="$(basename "$DEV")"
[[ -n "$PART" ]] || { [[ -b "/dev/${base}1" ]] && PART="/dev/${base}1"; }
[[ -n "$PART" ]] || die "no apareció la partición de $DEV"

mkfs.ext4 -F -L "$LABEL" -m 0 "$PART" >/dev/null
UUID="$(blkid -s UUID -o value "$PART")"
ok "$LABEL en $PART (UUID=$UUID)"

BRANCHES+=("$MOUNT")
UUIDS+=("$UUID")
NEW_BRANCHES="$(IFS=:; echo "${BRANCHES[*]}")"
NEW_UUIDS="$(IFS=:; echo "${UUIDS[*]}")"

log "Actualizando $CONFIG_PATH"
cat > "$CONFIG_PATH" <<EOF
# Ramas del pool de medios — generado por fix-media-mounts.sh / add-media-disk.sh el $(date -Iseconds)
# MEDIA_POOL      punto de montaje del pool mergerfs
# MEDIA_BRANCHES  puntos de montaje de las ramas, separados por ':'
# MEDIA_UUIDS     UUIDs de las ramas, mismo orden, separados por ':'
MEDIA_POOL=$POOL_PATH
MEDIA_BRANCHES=$NEW_BRANCHES
MEDIA_UUIDS=$NEW_UUIDS
EOF
chmod 644 "$CONFIG_PATH"
ok "config: ${#BRANCHES[@]} ramas"

log "Actualizando $FSTAB"
cp "$FSTAB" "${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
require_joined=''
for b in "${BRANCHES[@]}"; do
  require_joined+=",x-systemd.requires-mounts-for=$b"
done
awk '
  /^# BEGIN media-pool/ { skip=1; next }
  /^# END media-pool/   { skip=0; next }
  skip                  { next }
  /\/mnt\/media/        { next }
  /^# Discos multimedia/{ next }
  { print }
' "$FSTAB" > "${FSTAB}.new"
{
  cat "${FSTAB}.new"
  echo ''
  echo '# BEGIN media-pool (generado por fix-media-mounts.sh)'
  for i in "${!BRANCHES[@]}"; do
    echo "UUID=${UUIDS[$i]} ${BRANCHES[$i]} ext4 defaults,nofail 0 2"
  done
  echo "${NEW_BRANCHES} $POOL_PATH fuse.mergerfs ${MERGERFS_OPTS},fsname=media${require_joined} 0 0"
  echo '# END media-pool'
} > "${FSTAB}.new2"
mv "${FSTAB}.new2" "$FSTAB"
rm -f "${FSTAB}.new"
ok "fstab: ${#BRANCHES[@]} ramas"

if [[ -f "$DROPIN" ]]; then
  log "Actualizando drop-in de docker"
  {
    echo '[Unit]'
    args=''
    for b in "${BRANCHES[@]}"; do
      args+=" $b"
    done
    echo "RequiresMountsFor=${args# } $POOL_PATH"
    for b in "${BRANCHES[@]}"; do
      echo "ConditionPathIsMountPoint=$b"
    done
    echo "ConditionPathIsMountPoint=$POOL_PATH"
  } > "$DROPIN"
  ok "drop-in: ${#BRANCHES[@]} ramas"
fi

log "Montando $MOUNT"
mkdir -p "$MOUNT"
chmod 755 "$MOUNT"
mount "$MOUNT" || die "no pude montar $MOUNT"
mkdir -p "$MOUNT"/{movies,series,anime,music,downloads/incomplete,downloads/torrents,backups}
chown "$PUID:$PGID" "$MOUNT"
find "$MOUNT" \( -not -user "$PUID" -o -not -group "$PGID" \) -exec chown "$PUID:$PGID" {} + 2>/dev/null || true
ok "$MOUNT montado con estructura base"

log "Remontando el pool con la rama nueva"
umount "$POOL_PATH" || die "no pude desmontar $POOL_PATH (¿ocupado?)"
mount "$POOL_PATH" || die "no pude volver a montar $POOL_PATH"
ok "pool remontado: $(findmnt -rn -o SOURCE --target "$POOL_PATH")"

printf '\n%s═══ Listo ═══%s\n' "$G" "$N"
df -h "$POOL_PATH" "${BRANCHES[@]}" | sed 's/^/  /'
warn "si docker no está corriendo: sudo systemctl start docker && $STACK_DIR/scripts/start-stack.sh"
