# shellcheck shell=bash
# media-disk-guard.sh — helpers compartidos para operar discos del media stack.
#
# FUENTE ÚNICA de la política de seguridad. La usan:
#   - fix-media-mounts.sh     (raíz)      formatea los discos nuevos → media1/media2
#   - scripts/add-media-disk.sh           agrega una rama nueva al pool
#
# Existe para que no haya dos políticas distintas de "me parece que este disco
# está libre": el guard DIE si algo está montado. Desmontar y seguir NO es una
# opción — un disco con algo montado tiene datos que alguien está usando.
#
# No ejecutar este archivo: se sourcea.

# Identificadores estables del hardware. by-path (puerto físico) es el único
# confiable: los dos gabinetes USB reportan el MISMO serial, así que by-id
# colisiona entre ellos. by-id solo sirve para el disco del sistema, que es
# ATA y tiene serial único.
SYS_BY_ID='ata-HS-SSD-WAVE_S__240G_FZ8257638'
SYS_BY_PATH='pci-0000:00:17.0-ata-4'

# Tamaño del disco del sistema. Es un backstop: si alguien reacomoda los IDs,
# que el tamaño no cierre igual.
SYS_SIZE_VARIANTS=('223,6G' '223.6G' '224G' '240G')

# ───────────────────────── resolución de dispositivos ─────────────────────────

# byid <id> — imprime el path estable. Prueba by-path primero (puerto físico),
# después by-id. Nunca devuelve un /dev/sdX pelado.
byid() {
  local id="$1" cand
  for cand in "/dev/disk/by-path/$id" "/dev/disk/by-id/$id"; do
    [[ -e "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

# real_dev <id> — path real (/dev/sdX) de un id estable, o falla.
real_dev() {
  local p
  p="$(byid "$1")" || return 1
  readlink -f "$p"
}

# resolve_system_dev — path real del disco del sistema, identificado por by-id
# y/o by-path. Falla si no resuelve.
resolve_system_dev() {
  local p
  for p in "/dev/disk/by-id/$SYS_BY_ID" "/dev/disk/by-path/$SYS_BY_PATH"; do
    if [[ -e "$p" ]]; then
      readlink -f "$p"
      return 0
    fi
  done
  return 1
}

# disk_meta <id> — línea descriptiva de un disco por id estable.
disk_meta() {
  local id="$1" real size model serial
  if ! real="$(real_dev "$id")"; then
    printf '%s\t%s' "$id" 'NO PRESENTE'
    return 0
  fi
  size="$(lsblk -dn -o SIZE "$real" 2>/dev/null | xargs || echo '?')"
  model="$(lsblk -dn -o MODEL "$real" 2>/dev/null | xargs || echo '?')"
  serial="$(lsblk -dn -o SERIAL "$real" 2>/dev/null | xargs || echo '?')"
  printf '%s\t%s %s (SN %s) en %s' "$id" "$size" "$model" "$serial" "$real"
}

# ───────────────────────── el guard ─────────────────────────

# assert_safe_to_wipe <dev>
#
# Última línea de defensa antes de wipefs / sfdisk / mkfs. Verifica, en orden:
#   1. que el path resuelve a un dispositivo de bloque real
#   2. que NO es el disco del sistema (por by-id y por by-path)
#   3. que no tiene ninguna partición montada
#   4. que no monta /, /boot ni /boot/efi
#   5. que no es un PV de LVM
#   6. que no tiene el tamaño del disco del sistema
#
# Ante cualquier duda ABORTA. No hay forma de continuar desde acá.
assert_safe_to_wipe() {
  local dev="${1:-}" real sys_dev m src pk size v
  [[ -n "$dev" ]] || { printf 'assert_safe_to_wipe: falta el dispositivo\n' >&2; return 1; }

  real="$(readlink -f "$dev" 2>/dev/null || true)"
  [[ -n "$real" ]] || { printf 'PELIGRO: no se resuelve %s\n' "$dev" >&2; return 1; }
  [[ -b "$real" ]] || { printf 'PELIGRO: %s no es un dispositivo de bloque\n' "$real" >&2; return 1; }

  # 2. que no sea el disco del sistema
  if sys_dev="$(resolve_system_dev)"; then
    if [[ "$real" == "$sys_dev" ]]; then
      printf 'PELIGRO: %s ES el disco del sistema (%s)\n' "$real" "$sys_dev" >&2
      return 1
    fi
  fi

  # 3. que no tenga ninguna partición montada — ABORTAR, nunca desmontar
  local p
  for p in "$real" "${real}"[0-9]* "${real}"p[0-9]*; do
    [[ -b "$p" ]] || continue
    src="$(findmnt -rn -o TARGET -S "$p" 2>/dev/null || true)"
    if [[ -n "$src" ]]; then
      printf 'PELIGRO: %s está montado en %s — no lo voy a tocar (desmontalo vos si es intencional)\n' "$p" "$src" >&2
      return 1
    fi
  done

  # 4. que no monte /, /boot ni /boot/efi
  for m in / /boot /boot/efi; do
    src="$(findmnt -n -o SOURCE "$m" 2>/dev/null || true)"
    [[ -n "$src" ]] || continue
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 | tr -d ' ')"
    if [[ "$pk" == "$(basename "$real")" ]]; then
      printf 'PELIGRO: %s contiene %s (%s) — no lo voy a formatear\n' "$real" "$m" "$src" >&2
      return 1
    fi
  done

  # 5. que no sea un PV de LVM
  for p in "$real" "${real}"[0-9]* "${real}"p[0-9]*; do
    [[ -b "$p" ]] || continue
    if [[ "$(blkid -s TYPE -o value "$p" 2>/dev/null || true)" == 'LVM2_member' ]]; then
      printf 'PELIGRO: %s es un PV de LVM — no lo voy a tocar\n' "$p" >&2
      return 1
    fi
  done

  # 6. backstop por tamaño
  size="$(lsblk -dn -o SIZE "$real" 2>/dev/null | xargs || echo '?')"
  for v in "${SYS_SIZE_VARIANTS[@]}"; do
    if [[ "$size" == "$v" ]]; then
      printf 'PELIGRO: %s mide %s (tamaño del disco del sistema) — aborto\n' "$real" "$size" >&2
      return 1
    fi
  done

  return 0
}

# show_device_banner <dev> — imprime a pantalla qué dispositivo se va a tocar.
# Obligatorio antes de cualquier operación destructiva: la persona tiene que ver
# el disco resuelto, no un sdX que puede cambiar en el próximo reboot.
show_device_banner() {
  local dev="$1" real size model serial fstype
  real="$(readlink -f "$dev" 2>/dev/null || true)"
  if [[ -z "$real" || ! -b "$real" ]]; then
    printf '  (no se pudo leer %s)\n' "$dev"
    return 1
  fi
  size="$(lsblk -dn -o SIZE "$real" 2>/dev/null | xargs || echo '?')"
  model="$(lsblk -dn -o MODEL "$real" 2>/dev/null | xargs || echo '?')"
  serial="$(lsblk -dn -o SERIAL "$real" 2>/dev/null || echo '?')"
  printf '  path estable : %s\n' "$dev"
  printf '  dispositivo  : %s\n' "$real"
  printf '  modelo/serial: %s (SN %s)\n' "$model" "$serial"
  printf '  tamaño       : %s\n' "$size"
  printf '  particiones  :\n'
  lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$real" 2>/dev/null | sed 's/^/                 /' \
    || printf '                 (sin particiones)\n'
  fstype="$(blkid -s TYPE -o value "$real" 2>/dev/null || true)"
  [[ -n "$fstype" ]] && printf '  tipo actual  : %s (se va a BORRAR)\n' "$fstype"
  return 0
}
