#!/usr/bin/env bash
# check-restore-sde.sh — VERIFICA y (si hace falta) RESTAURA la tabla de
# particiones GPT del disco del SISTEMA tras un wipefs accidental.
#
# Uso:  sudo bash check-restore-sde.sh
#
# ── Por qué este script NO usa /dev/sdX ────────────────────────────────
# El nombre dice "sde" y antes el disco del sistema era sde. Hoy es otro
# (por ejemplo sdg): los sdX se reasignan entre reboots según el orden de
# sondeo del kernel. Con un /dev/sde hardcodeado, este script terminaba
# mirando —y potencialmente reescribiendo— un disco de datos.
#
# Por eso resuelve el disco del sistema por su identificador estable
# (by-id del serial ATA, con by-path como segundo origen) y ADEMÁS lo
# verifica de tres formas independientes antes de escribir nada:
#
#   1. que el path resuelto exista y sea un dispositivo de bloque
#   2. que sea el disco que realmente monta / (PKNAME de la fuente de /)
#   3. que su tamaño sea el del disco del sistema
#
# Y antes de escribir, compara los offsets que el kernel tiene cacheados con
# la tabla que va a escribir. Si no coinciden, ABORTA: significaría que la
# tabla no corresponde a este disco.
#
# NO toca los datos dentro de las particiones (/, /boot, /boot/efi): solo
# reescribe el índice GPT con los offsets que el kernel todavía tiene.
set -Eeuo pipefail

STACK_DIR='/home/chae/stack'
# shellcheck source=scripts/lib/media-disk-guard.sh
source "$STACK_DIR/scripts/lib/media-disk-guard.sh"

# Tabla GPT del disco del sistema. Estos offsets están verificados contra
# /sys/block/<disco>/<part>/start (verificación en tiempo de ejecución).
GPT_TYPE_EFI='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'   # vfat  /boot/efi
GPT_TYPE_EXT4='0FC63DAF-8483-4772-8E79-3D69D8477DE4'  # ext4  /boot
GPT_TYPE_LVM='E6D6D379-F507-44C2-A23C-238F2A3DF928'   # LVM   /
GPT_UUID_EFI='8efc6ed6-931b-46b7-825a-2fa91aa76123'
GPT_UUID_EXT4='d59b8692-3f85-4ced-b21b-f4e95f152100'
GPT_UUID_LVM='ed906528-7f87-4b03-8c8e-aed598511839'
#    índice:inicio:tamaño
GPT_LAYOUT='1:2048:2201600
2:2203648:4194304
3:6397952:462460928'

B='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
log() { printf "${B}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$*"; }
ok()  { printf "${G}  ✔ %s${N}\n" "$*"; }
warn(){ printf "${Y}  ⚠ %s${N}\n" "$*"; }
die() { printf "${R}ERROR: %s${N}\n" "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "correr como root: sudo bash $0"

# ───────────────────────── resolución del disco ─────────────────────────

DEV="$(resolve_system_dev)" \
  || die "no encontré el disco del sistema (by-id $SYS_BY_ID ni by-path $SYS_BY_PATH)"

[[ -b "$DEV" ]] || die "$DEV no es un dispositivo de bloque"

BASE="$(basename "$DEV")"

# part_name <n> — nodo de partición, sea sdX1 o nvmexXp1.
part_name() {
  local n="$1"
  if [[ -b "/dev/${BASE}${n}" ]]; then printf '/dev/%s%s' "$BASE" "$n"; return 0; fi
  if [[ -b "/dev/${BASE}p${n}" ]]; then printf '/dev/%sp%s' "$BASE" "$n"; return 0; fi
  return 1
}

# ── verificación 2: que este disco sea el que monta / ──
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SRC" ]] || die "no pude leer la fuente de / —Abortando sin verificar nada"
ROOT_PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 | tr -d ' ')"
if [[ "$ROOT_PK" != "$BASE" ]]; then
  die "el disco resuelto ($DEV / $BASE) NO monta / — el que monta / es '$ROOT_PK'.
    Este script jamás debe escribir acá. Abortando."
fi
ok "verificado: $DEV monta / (fuente $ROOT_SRC, PKNAME $ROOT_PK)"

# ── verificación 3: backstop por tamaño ──
SYS_SIZE="$(lsblk -dn -o SIZE "$DEV" 2>/dev/null | xargs || echo '?')"
size_ok=0
for v in "${SYS_SIZE_VARIANTS[@]}"; do [[ "$SYS_SIZE" == "$v" ]] && size_ok=1; done
[[ "$size_ok" -eq 1 ]] \
  || die "$DEV mide $SYS_SIZE y no coincide con el tamaño del disco del sistema (${SYS_SIZE_VARIANTS[*]}).
    No sigo: si el identificador se movió, podría estar mirando otro disco."
ok "verificado: tamaño $SYS_SIZE"

printf '\n%s═══ 1. Disco del sistema resuelto ═══%s\n' "$B" "$N"
show_device_banner "$DEV" || die "no pude leer $DEV"
printf '  by-id       : %s\n' "$SYS_BY_ID"
printf '  by-path     : %s\n' "$SYS_BY_PATH"

printf '\n%s═══ 2. Estado actual ═══%s\n' "$B" "$N"
echo "--- sfdisk -d ---"
sfdisk -d "$DEV" 2>&1 || true
echo
echo "--- wipefs (firmas detectadas) ---"
wipefs "$DEV" 2>&1 || true
echo

echo "--- offsets que el kernel tiene en memoria ---"
KERNEL_LAYOUT=''
for n in 1 2 3; do
  s="$(cat "/sys/block/$BASE/$BASE${n}/start" 2>/dev/null || true)"
  z="$(cat "/sys/block/$BASE/$BASE${n}/size"  2>/dev/null || true)"
  [[ -n "$s" && -n "$z" ]] || { warn "no pude leer /sys ... ${BASE}${n}"; KERNEL_LAYOUT=''; break; }
  printf '  %s%s  start=%s  size=%s\n' "$BASE" "$n" "$s" "$z"
  KERNEL_LAYOUT+="$n:$s:$z"$'\n'
done
echo

if sfdisk -d "$DEV" 2>/dev/null | grep -q 'start='; then
  printf '%s═══ 3. Resultado ═══%s\n' "$B" "$N"
  ok "La tabla de particiones de $DEV está PRESENTE y sana. No hago nada."
  ok "No hace falta restaurar. Podés seguir con fix-media-mounts.sh."
  exit 0
fi

# ── verificación 4: la tabla tiene que corresponder a ESTE disco ──
if [[ -n "$KERNEL_LAYOUT" ]]; then
  if [[ "$KERNEL_LAYOUT" != "$GPT_LAYOUT"$'\n' ]]; then
    printf '%s═══ 3. Resultado ═══%s\n' "$B" "$N"
    die "los offsets que el kernel tiene cacheados NO coinciden con la tabla de
    restauración. Si la tabla no corresponde a $DEV, escribirla rompería el
    arranque. Abortando sin escribir nada.

    kernel : $KERNEL_LAYOUT
    script : $GPT_LAYOUT"
  fi
  ok "verificado: los offsets del kernel coinciden con la tabla de restauración"
else
  printf '%s' "$Y"
  warn "sin offsets del kernel para comparar — no puedo verificar la tabla automáticamente"
  printf '  tabla del script: %s\n' "$(echo "$GPT_LAYOUT" | tr '\n' ' ')"
  printf 'Revisala a mano contra la salida de arriba antes de seguir.\n'
  printf '%s' "$N"
fi

printf '\n%s═══ 4. A confirmar ═══%s\n' "$B" "$N"
printf 'Voy a REESCRIBIR SOLO el índice GPT de:\n\n'
printf '  path estable : %s\n' "/dev/disk/by-id/$SYS_BY_ID"
printf '  dispositivo  : %s\n' "$DEV"
printf '  tamaño       : %s\n' "$SYS_SIZE"
printf '  monta /      : sí (verificado)\n\n'
printf 'Particiones que se van a reescribir (con los mismos offsets y PARTUUIDs):\n'
printf '  p1  start=2048     size=2201600    vfat  /boot/efi\n'
printf '  p2  start=2203648  size=4194304    ext4  /boot\n'
printf '  p3  start=6397952  size=462460928  LVM   /\n\n'
printf 'Los DATOS dentro de las particiones no se tocan: solo el índice.\n'
printf 'Escribí %sRESTAURAR%s para continuar (Ctrl-C aborta): ' "$R" "$N"
read -r answer
[[ "$answer" == 'RESTAURAR' ]] || die "abortado — NADA quedó modificado"

log "Reescribiendo GPT en $DEV (mismos offsets, mismos PARTUUIDs)"
sfdisk --wipe never --no-reread --force "$DEV" <<EOF
label: gpt
start=2048, size=2201600, type=$GPT_TYPE_EFI, uuid=$GPT_UUID_EFI
start=2203648, size=4194304, type=$GPT_TYPE_EXT4, uuid=$GPT_UUID_EXT4
start=6397952, size=462460928, type=$GPT_TYPE_LVM, uuid=$GPT_UUID_LVM
EOF

log "Dejando que udev re-evalue"
udevadm settle 2>/dev/null || true
partprobe "$DEV" 2>/dev/null || true

printf '\n%s═══ 5. Verificación ═══%s\n' "$B" "$N"
echo "--- sfdisk -d (debería mostrar 3 particiones) ---"
sfdisk -d "$DEV" || die "sfdisk no puede leer la tabla restaurada"
echo
echo "--- blkid (los UUID de filesystem deben ser los de siempre) ---"
p1="$(part_name 1 || true)"; p2="$(part_name 2 || true)"; p3="$(part_name 3 || true)"
echo "  esperado p1 vfat  A9B8-4E0F"
echo "  esperado p2 ext4  34606998-a802-4ebe-9a7b-00d66bda0efb"
echo "  esperado p3 LVM   2EYmPn-1QQb-Iavd-jdFx-trc3-0ojG-V8y2gp"
echo
# shellcheck disable=SC2086
blkid $p1 $p2 $p3 || die "blkid no ve las particiones"
echo
echo "--- LVM (el PV del root debe seguir ahí) ---"
pvs 2>&1 | sed 's/^/  /' || true
lvs 2>&1 | sed 's/^/  /' || true
echo
echo "--- montajes actuales (todo debería seguir montado) ---"
findmnt / /boot /boot/efi 2>&1 | sed 's/^/  /' || true

printf '\n'
ok "Restauración terminada sobre $DEV. NO hace falta reiniciar: el sistema sigue corriendo."
ok "Tras el próximo arranque el BIOS/GRUB vuelve a encontrar /boot y /boot/efi."
warn "Recién ahora corré: sudo bash $STACK_DIR/fix-media-mounts.sh"
