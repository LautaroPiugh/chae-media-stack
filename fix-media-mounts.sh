#!/usr/bin/env bash
# fix-media-mounts.sh — repara el sistema de discos del media stack tras un
# intercambio de discos. Genera la config de ramas, el fstab, el drop-in de
# docker y deja montado el pool mergerfs.
#
# Uso:
#   sudo bash fix-media-mounts.sh                # reparación completa (pide confirmación)
#   sudo bash fix-media-mounts.sh --yes          # sin prompt (para corridas no interactivas)
#   sudo bash fix-media-mounts.sh --only-inspect # solo inspecciona sdf (read-only) y lista discos
#
# Lo que hace:
#   1. Lista discos por by-id (estable entre reboots)
#   2. Inspecciona sdf en read-only y deja el reporte en /mnt/.sdf-check
#   3. Formatea los discos nuevos como GPT+ext4 → media1 (sda) y media2 (sdb)
#   4. Escribe /home/chae/stack/.media-branches.conf (lo leen los scripts del stack)
#   5. Reescribe la sección de /etc/fstab (con backup) y el drop-in de docker
#   6. Monta media1..media4 y el pool mergerfs
#   7. Crea los directorios base y ajusta permisos a 1000:1000
#   8. Instala media-pool-watchdog (service + timer) y arranca docker
#
# NO toca: sde (sistema), sdc (media4, datos), sdd (media3, datos), sdf (solo lectura)
set -Eeuo pipefail

# Política de seguridad compartida con scripts/add-media-disk.sh.
# No reimplementar assert_safe_to_wipe acá: si divergen, uno de los dos_paths
# destructivos queda sin defensa.
# shellcheck source=scripts/lib/media-disk-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/media-disk-guard.sh"

# ───────────────────────── identificadores estables ─────────────────────────
# OJO: los dos discos USB nuevos son el MISMO modelo de gabinete y reportan el
# MISMO serial (DD564198338A1), así que /dev/disk/by-id/ colisiona entre ellos.
# Por eso los identificamos por /dev/disk/by-path/ (puerto físico, único) y
# además exigimos que el disco NO tenga nada montado antes de tocarlo.
# SYS_ID / SYS_BY_PATH viven en el guard compartido.
MEDIA3_ID='pci-0000:00:17.0-ata-3'                              # sdd — media3 (datos)
MEDIA4_ID='pci-0000:00:17.0-ata-2'                              # sdc — media4 (datos)
NEW1_ID='pci-0000:00:14.0-usb-0:3:1.0-scsi-0:0:0:0'             # sda — a formatear → media1
NEW2_ID='pci-0000:00:14.0-usb-0:4:1.0-scsi-0:0:0:0'             # sdb — a formatear → media2
SDF_ID='pci-0000:00:14.0-usb-0:8:1.0-scsi-0:0:0:0'              # sdf — solo inspeccionar
GPT_LINUX_TYPE='0FC63DAF-8483-4772-8E79-3D69D8477DE4'

POOL_PATH='/mnt/media'
BRANCH_PATHS=(/mnt/media1 /mnt/media2 /mnt/media3 /mnt/media4)
BRANCH_LABELS=(media1 media2 media3 media4)
# Disco que se formatea para cada rama ("" = no formatear, solo montar lo que ya hay)
BRANCH_NEW_IDS=("$NEW1_ID" "$NEW2_ID" "" "")
BRANCH_KEEP_IDS=("" "" "$MEDIA3_ID" "$MEDIA4_ID")
BRANCH_KEEP_UUIDS=("" "" 'f5b48469-5ece-4e75-a90d-7ff6a93c4dfe' 'a4325f7b-fd22-4a64-8f1e-fd90483740c5')

STACK_DIR='/home/chae/stack'
CONFIG_PATH="$STACK_DIR/.media-branches.conf"
FSTAB='/etc/fstab'
DROPIN_DIR='/etc/systemd/system/docker.service.d'
DROPIN="$DROPIN_DIR/media-mounts.conf"
UNIT_SRC="$STACK_DIR/scripts/systemd"
UNIT_DST='/etc/systemd/system'
SDF_CHECK='/mnt/.sdf-check'
MERGERFS_OPTS='defaults,allow_other,use_ino,cache.files=off,category.create=mfs,minfreespace=20G'
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

YES=0
ONLY_INSPECT=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --only-inspect|--inspect) ONLY_INSPECT=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) printf 'argumento desconocido: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ───────────────────────── helpers ─────────────────────────
B='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
log()  { printf "${B}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf "${G}  ✔ %s${N}\n" "$*"; }
warn() { printf "${Y}  ⚠ %s${N}\n" "$*"; }
die()  { printf "${R}ERROR: %s${N}\n" "$*" >&2; exit 1; }

show_inventory() {
  printf '\n%s═══ Discos presentes ═══%s\n' "$B" "$N"
  local role id
  # El disco del sistema se lista por su by-id, no por un sdX: hoy es sdg, y
  # fue sde hace poco. Lo que importa es el identificador estable.
  for role in "SISTEMA (no tocar):$SYS_BY_ID" \
              "media3 (datos):$MEDIA3_ID" \
              "media4 (datos):$MEDIA4_ID" \
              "NUEVO 1 → media1:$NEW1_ID" \
              "NUEVO 2 → media2:$NEW2_ID" \
              "sdf (solo inspección):$SDF_ID"; do
    id="${role#*:}"
    role="${role%%:*}"
    printf '  %-22s %s\n' "$role" "$(disk_meta "$id")"
  done
  printf '\n'
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "esto hay que correrlo como root: sudo bash $0"
}

confirm() {
  [[ "$YES" -eq 1 ]] && return 0
  local answer
  printf '%s\n' "$Y"
  printf 'ATENCION — esto va a:\n'
  printf '  1. Inspeccionar sdf en read-only (no se modifica)\n'
  printf '  2. FORMATEAR los discos nuevos 1 y 2 → media1 y media2 (GPT+ext4)\n'
  printf '  3. Reescribir la sección de %s (con backup)\n' "$FSTAB"
  printf '  4. Montar media1..media4 y el pool %s\n' "$POOL_PATH"
  printf '  5. Crear directorios base y ajustar permisos a %s:%s\n' "$PUID" "$PGID"
  printf '  6. Instalar media-pool-watchdog y arrancar docker\n'
  printf '%s\n' "$N"
  printf 'NO se toca: sde (sistema), sdc (media4), sdd (media3), sdf (solo lectura)\n\n'
  printf 'Los discos a formatear se identifican por by-path (puerto físico) y además\n'
  printf 'se verifica que no tengan NADA montado antes de tocarlos.\n\n'
  printf 'Escribí %sFORMATEAR%s para continuar (Ctrl-C aborta): ' "$R" "$N"
  read -r answer
  [[ "$answer" == 'FORMATEAR' ]] || die "abortado por el usuario"
}

# ───────────────────────── FASE 1: inspección de sdf ─────────────────────────
inspect_sdf() {
  log "FASE 1: inspección read-only de sdf"
  local sdf_dev sdf_part fstype uuid
  if ! sdf_dev="$(real_dev "$SDF_ID")"; then
    warn "sdf no está presente; sigo sin inspeccionar"
    return 0
  fi
  # sdf2 es la partición grande; puede venir como <dev>-part2 o <dev>2
  sdf_part=""
  for cand in "$(byid "$SDF_ID")-part2" "${sdf_dev}2" "${sdf_dev}p2"; do
    if [[ -b "$cand" ]]; then sdf_part="$cand"; break; fi
  done
  [[ -n "$sdf_part" ]] || { warn "no encontré la partición 2 de sdf ($sdf_dev); sigo"; return 0; }

  fstype="$(blkid -s TYPE -o value "$sdf_part" 2>/dev/null || echo '?')"
  uuid="$(blkid -s UUID -o value "$sdf_part" 2>/dev/null || echo '?')"
  log "  sdf2 = $sdf_part  tipo=$fstype  uuid=$uuid"

  mkdir -p "$SDF_CHECK"
  chmod 755 "$SDF_CHECK"
  if mountpoint -q "$SDF_CHECK"; then
    umount "$SDF_CHECK" 2>/dev/null || true
  fi
  if ! mount -o ro "$sdf_part" "$SDF_CHECK" 2>/dev/null; then
    warn "no pude montar $sdf_part en $SDF_CHECK (¿dirty?); pruebo con norecovery"
    mount -o ro,norecovery "$sdf_part" "$SDF_CHECK" 2>/dev/null \
      || { warn "tampoco con norecovery; dejo sdf sin montar"; return 0; }
  fi

  {
    echo "=== inspección de sdf2 ($sdf_part) $(date -Iseconds) ==="
    echo "--- df ---"
    df -h "$SDF_CHECK"
    echo "--- primer nivel ---"
    ls -la "$SDF_CHECK"
    echo "--- árbol (profundidad 2, hasta 200 entradas) ---"
    find "$SDF_CHECK" -mindepth 1 -maxdepth 2 -printf '%y %s %p\n' 2>/dev/null | head -200
    echo "--- ocupación por directorio de primer nivel ---"
    du -sh "$SDF_CHECK"/* "$SDF_CHECK"/.[!.]* 2>/dev/null | sort -h
    echo "--- total de archivos ---"
    find "$SDF_CHECK" -type f 2>/dev/null | wc -l
  } > /mnt/.sdf-reporte.txt 2>&1 || true

  ok "sdf montado read-only en $SDF_CHECK — reporte en /mnt/.sdf-reporte.txt"
  warn "decidí qué hacer con sdf (usarlo / formatearlo / dejarlo) y avisame"
  log "  (para desmontar: umount $SDF_CHECK)"
}

# ───────────────────────── FASE 2: formateo de nuevos ─────────────────────────
find_part() {
  # Devuelve el nodo de la partición de datos de un disco by-id (o el disco entero).
  local id="$1" dev
  dev="$(byid "$id")"
  for cand in "${dev}-part1" "$dev" ; do
    [[ -b "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  local base
  base="$(basename "$(real_dev "$id")")"
  for cand in "/dev/${base}1" "/dev/${base}p1"; do
    [[ -b "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

already_formatted() {
  local id="$1" want="$2" part
  part="$(find_part "$id")" || return 1
  [[ "$(blkid -s TYPE -o value "$part" 2>/dev/null || true)" == 'ext4' ]] || return 1
  [[ "$(blkid -s LABEL -o value "$part" 2>/dev/null || true)" == "$want" ]] || return 1
  return 0
}

format_new_disk() {
  local id="$1" label="$2" dev part
  LAST_FORMATTED_UUID=''
  if already_formatted "$id" "$label"; then
    part="$(find_part "$id")"
    LAST_FORMATTED_UUID="$(blkid -s UUID -o value "$part")"
    ok "$label ya está en $part (UUID=$LAST_FORMATTED_UUID); no lo formateo de nuevo"
    return 0
  fi

  dev="$(byid "$id")" || die "no existe un disco estable para el id $id"
  printf '\n'
  log "Disco a formatear para $label:"
  show_device_banner "$dev" || die "no pude leer $dev — abortando sin tocar nada"
  assert_safe_to_wipe "$dev" \
    || die "guard de seguridad: $dev NO se puede formatear (ver el motivo arriba)"
  log "Formateando $label en $dev ($(disk_meta "$id"))"

  # limpiar firmas viejas (NTFS/GPT/MBR) y crear GPT con una partición que ocupa todo
  wipefs -a "$dev" >/dev/null 2>&1 || true
  printf 'label: gpt\n,,%s\n' "$GPT_LINUX_TYPE" | sfdisk --wipe always "$dev" >/dev/null \
    || die "sfdisk falló en $dev"
  partprobe "$dev" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1

  part=""
  for cand in "${dev}-part1" "${dev}1"; do
    [[ -b "$cand" ]] && { part="$cand"; break; }
  done
  if [[ -z "$part" ]]; then
    local base
    base="$(basename "$(real_dev "$id")")"
    for cand in "/dev/${base}1" "/dev/${base}p1"; do
      [[ -b "$cand" ]] && { part="$cand"; break; }
    done
  fi
  [[ -n "$part" ]] || die "tras particionar $dev no apareció el nodo de partición"

  mkfs.ext4 -F -L "$label" -m 0 "$part" >/dev/null
  LAST_FORMATTED_UUID="$(blkid -s UUID -o value "$part")"
  ok "$label listo en $part (UUID=$LAST_FORMATTED_UUID)"
}

# ───────────────────────── FASE 3: config + fstab + drop-in ─────────────────────────
write_config() {
  local uuids_csv="$1"
  local branches_csv joined
  branches_csv="$(IFS=:; echo "${BRANCH_PATHS[*]}")"
  joined="$branches_csv"
  cat > "$CONFIG_PATH" <<EOF
# Ramas del pool de medios — generado por fix-media-mounts.sh el $(date -Iseconds)
# Actualizar al agregar/quitar discos:
#   sudo bash $STACK_DIR/scripts/add-media-disk.sh <disco>
#   sudo bash $STACK_DIR/fix-media-mounts.sh
#
# MEDIA_POOL      punto de montaje del pool mergerfs
# MEDIA_BRANCHES  puntos de montaje de las ramas, separados por ':'
# MEDIA_UUIDS     UUIDs de las ramas, mismo orden, separados por ':'
MEDIA_POOL=$POOL_PATH
MEDIA_BRANCHES=$joined
MEDIA_UUIDS=$uuids_csv
EOF
  chmod 644 "$CONFIG_PATH"
  ok "config de ramas en $CONFIG_PATH"
}

update_fstab() {
  local uuids_csv="$1"
  local backup
  backup="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$FSTAB" "$backup"
  ok "backup de fstab: $backup"

  local -a uuids=()
  IFS=':' read -ra uuids <<< "$uuids_csv"

  # quita bloque viejo + cualquier línea que monte en /mnt/media*
  awk '
    /^# BEGIN media-pool/ { skip=1; next }
    /^# END media-pool/   { skip=0; next }
    skip                  { next }
    /\/mnt\/media/        { next }
    /^# Discos multimedia/{ next }
    { print }
  ' "$FSTAB" > "${FSTAB}.new"

  local branches_joined require_joined i
  branches_joined="$(IFS=:; echo "${BRANCH_PATHS[*]}")"
  require_joined=''
  for i in "${!BRANCH_PATHS[@]}"; do
    require_joined+=",x-systemd.requires-mounts-for=${BRANCH_PATHS[$i]}"
  done
  {
    cat "${FSTAB}.new"
    echo ''
    echo '# BEGIN media-pool (generado por fix-media-mounts.sh)'
    for i in "${!BRANCH_PATHS[@]}"; do
      echo "UUID=${uuids[$i]} ${BRANCH_PATHS[$i]} ext4 defaults,nofail 0 2"
    done
    echo "${branches_joined} $POOL_PATH fuse.mergerfs ${MERGERFS_OPTS},fsname=media${require_joined} 0 0"
    echo '# END media-pool'
  } > "${FSTAB}.new2"
  mv "${FSTAB}.new2" "$FSTAB"
  rm -f "${FSTAB}.new"
  ok "fstab actualizado (${#BRANCH_PATHS[@]} ramas + mergerfs)"
}

update_dropin() {
  mkdir -p "$DROPIN_DIR"
  {
    echo '[Unit]'
    local args='' b
    for b in "${BRANCH_PATHS[@]}"; do
      args+=" $b"
    done
    echo "RequiresMountsFor=${args# } $POOL_PATH"
    for b in "${BRANCH_PATHS[@]}"; do
      echo "ConditionPathIsMountPoint=$b"
    done
    echo "ConditionPathIsMountPoint=$POOL_PATH"
  } > "$DROPIN"
  ok "drop-in de docker en $DROPIN"
}

# ───────────────────────── FASE 4: mounts ─────────────────────────
mount_all() {
  log "FASE 4: montaje de ramas y pool"

  if mountpoint -q "$POOL_PATH"; then
    log "  desmontando el pool viejo (mergerfs colgado sobre directorios vacíos)"
    umount "$POOL_PATH" || die "no pude desmontar $POOL_PATH (¿docker usándolo? probá: systemctl stop docker && $STACK_DIR/scripts/stop-stack.sh)"
  fi

  local i path
  for i in "${!BRANCH_PATHS[@]}"; do
    path="${BRANCH_PATHS[$i]}"
    mkdir -p "$path"
    chmod 755 "$path"
    if mountpoint -q "$path"; then
      ok "$path ya estaba montado"
      continue
    fi
    mount "$path" || die "no pude montar $path (revisar fstab)"
    ok "$path montado ($(findmnt -rn -o UUID --target "$path"))"
  done

  mkdir -p "$POOL_PATH"
  chmod 755 "$POOL_PATH"
  mount "$POOL_PATH" || die "no pude montar el pool $POOL_PATH"
  ok "pool $POOL_PATH montado (ramas: $(findmnt -rn -o SOURCE --target "$POOL_PATH"))"
}

# ───────────────────────── FASE 5: directorios + permisos ─────────────────────────
make_dirs() {
  log "FASE 5: directorios base y permisos"
  local i path
  for i in "${!BRANCH_PATHS[@]}"; do
    path="${BRANCH_PATHS[$i]}"
    mkdir -p "$path"/{movies,series,anime,music,downloads/incomplete,downloads/torrents,backups}
  done
  # rutas concretas que esperan los scripts del stack (son de rama, no del pool):
  #   media1 → espejo de backups, media2 → descargas + backups principales
  mkdir -p "${BRANCH_PATHS[0]}/backups/stack"
  mkdir -p "${BRANCH_PATHS[1]}/backups/stack"
  mkdir -p "${BRANCH_PATHS[1]}/downloads"
  mkdir -p "$POOL_PATH/backups/sdh-quarantine"

  for i in "${!BRANCH_PATHS[@]}"; do
    path="${BRANCH_PATHS[$i]}"
    log "  permisos de $path a $PUID:$PGID (sólo lo que no coincida)"
    chown "$PUID:$PGID" "$path"
    find "$path" \( -not -user "$PUID" -o -not -group "$PGID" \) -exec chown "$PUID:$PGID" {} + 2>/dev/null || true
  done
  chown -R "$PUID:$PGID" "${BRANCH_PATHS[0]}/backups" "${BRANCH_PATHS[1]}/backups" "${BRANCH_PATHS[1]}/downloads" 2>/dev/null || true
  ok "directorios y permisos listos"
}

# ───────────────────────── FASE 6: watchdog + docker ─────────────────────────
install_watchdog() {
  log "FASE 6: media-pool-watchdog + docker"
  install -m 644 "$UNIT_SRC/media-pool-watchdog.service" "$UNIT_DST/"
  install -m 644 "$UNIT_SRC/media-pool-watchdog.timer" "$UNIT_DST/"
  systemctl daemon-reload
  systemctl enable --now media-pool-watchdog.timer >/dev/null 2>&1 || true
  ok "media-pool-watchdog.service/.timer instalados (timer cada 2 min)"

  # permite disparar el watchdog desde tmux sin password
  if [[ ! -f /etc/sudoers.d/media-pool-watchdog ]]; then
    cat > /etc/sudoers.d/media-pool-watchdog <<'EOF'
# deja al usuario del stack disparar el watchdog de monturas
chae ALL=(root) NOPASSWD: /usr/bin/systemctl start media-pool-watchdog.service
EOF
    chmod 440 /etc/sudoers.d/media-pool-watchdog
    visudo -cf /etc/sudoers.d/media-pool-watchdog >/dev/null || {
      rm -f /etc/sudoers.d/media-pool-watchdog
      warn "sudoers descartado (visudo lo rechazó)"
    }
    ok "sudoers: systemctl start media-pool-watchdog sin password"
  fi

  systemctl start docker
  ok "docker arrancado ($(systemctl is-active docker))"
}

# ───────────────────────── main ─────────────────────────
require_root
show_inventory

if [[ "$ONLY_INSPECT" -eq 1 ]]; then
  inspect_sdf
  exit 0
fi

confirm
inspect_sdf

log "FASE 2: formateo de discos nuevos"
format_new_disk "$NEW1_ID" media1
NEW1_UUID="$LAST_FORMATTED_UUID"
format_new_disk "$NEW2_ID" media2
NEW2_UUID="$LAST_FORMATTED_UUID"
UUIDS_CSV="${NEW1_UUID}:${NEW2_UUID}:${BRANCH_KEEP_UUIDS[2]}:${BRANCH_KEEP_UUIDS[3]}"
ok "UUIDs: $UUIDS_CSV"

log "FASE 3: config + fstab + drop-in de docker"
write_config "$UUIDS_CSV"
update_fstab "$UUIDS_CSV"
update_dropin

mount_all
make_dirs
install_watchdog

printf '\n%s═══ Listo ═══%s\n' "$G" "$N"
df -h "$POOL_PATH" "${BRANCH_PATHS[@]}" | sed 's/^/  /'
printf '\n'
ok "pool montado. Scripts del stack ya leen $CONFIG_PATH"
warn "sdf quedó fuera del pool (mirá /mnt/.sdf-check y /mnt/.sdf-reporte.txt)"
printf '  Siguiente (como chae, no root):\n'
printf '    /home/chae/stack/scripts/media-mount-recovery.sh\n'
printf '    /home/chae/stack/scripts/start-stack.sh\n'
printf '    /home/chae/stack/scripts/health-check.sh\n'
