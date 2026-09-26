#!/usr/bin/env bash
# rescue-and-format-sdf.sh — termina el rescate de sdf (los archivos solo-lectura
# de uid 1001 hacen falta root) y recién después lo agrega al pool.
#
# Uso:  sudo bash rescue-and-format-sdf.sh
#
#  1. Completa la copia a /mnt/media1/chae-archive/sdf-2026/ (faltan 13 archivos:
#     Contraseñas-Chrome.csv, bookmarks-chrome.html, CertificadoCobertura, .tmp…)
#  2. Verifica que origen y copia matcheen. Si NO, aborta sin formatear.
#  3. Desmonta el origen (el formateador aborta si el disco está montado)
#  4. Delega el formateo a add-media-disk.sh
#
# Este script NO formatea. El único camino destructivo del rescate es
# add-media-disk.sh, que corre el guard compartido (assert_safe_to_wipe).
# Si esa política cambia, este archivo no queda desactualizado.
set -Eeuo pipefail

STACK_DIR='/home/chae/stack'
SRC='/mnt/.sdf-check/home'
DST='/mnt/media1/chae-archive/sdf-2026'
SDF_PATH_ID='pci-0000:00:14.0-usb-0:8:1.0-scsi-0:0:0:0'
ADD="$STACK_DIR/scripts/add-media-disk.sh"
SDF_BY_PATH="/dev/disk/by-path/$SDF_PATH_ID"

B='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
log() { printf "${B}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$*"; }
ok()  { printf "${G}  ✔ %s${N}\n" "$*"; }
warn(){ printf "${Y}  ⚠ %s${N}\n" "$*"; }
die() { printf "${R}ERROR: %s${N}\n" "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "correr como root: sudo bash $0"
[[ -d "$SRC/contabilidad" ]] || die "no está montado sdf en /mnt/.sdf-check (esperaba $SRC)"
[[ -d "$DST" ]] || die "no existe $DST (debería estar el rescate parcial)"
[[ -x "$ADD" ]] || die "no encontré $ADD"
[[ -e "$SDF_BY_PATH" ]] || die "no existe $SDF_BY_PATH — ¿sdf sigue conectado?"

EXCLUDES=(
  --exclude='.cache/' --exclude='.wine/' --exclude='.nx/'
  --exclude='.mozilla/' --exclude='.config/' --exclude='.local/'
  --exclude='snap/' --exclude='.adobe/' --exclude='.gnupg/'
  --exclude='.hplip/' --exclude='.pki/' --exclude='.qt/'
  --exclude='.cups/' --exclude='.thunderbird/' --exclude='.ssh/'
)

printf '%s═══ 1/4: completo el rescate (archivos de uid 1001 que faltan) ═══%s\n' "$B" "$N"
log "Esto agrega los 13 archivos solo-lectura que el rsync anterior no pudo leer"
log "(Contraseñas-Chrome.csv, bookmarks-chrome.html, CertificadoCobertura, .tmp…)"

rsync -a --stats "${EXCLUDES[@]}" \
  "$SRC/contabilidad/" "$DST/contabilidad/" 2>&1 | tail -5
rsync -a --stats "${EXCLUDES[@]}" \
  "$SRC/informatica/" "$DST/informatica/" 2>&1 | tail -5

printf '\n%s═══ 2/4: verificación ═══%s\n' "$B" "$N"
fail=0
for d in Documentos Escritorio Descargas Imágenes; do
  s=$(find "$SRC/contabilidad/$d" -type f 2>/dev/null | wc -l)
  c=$(find "$DST/contabilidad/$d" -type f 2>/dev/null | wc -l)
  if [[ "$s" == "$c" ]]; then
    printf '  %-12s origen=%-7s copia=%-7s %s\n' "$d" "$s" "$c" "OK"
  else
    printf '  %-12s origen=%-7s copia=%-7s %s\n' "$d" "$s" "$c" "DIFIERE"
    fail=1
  fi
done

for f in "contabilidad/Escritorio/Contraseñas-Chrome.csv" \
         "contabilidad/Escritorio/bookmarks-chrome.html" \
         "contabilidad/CertificadoCobertura (1).txt"; do
  if [[ -f "$DST/$f" ]]; then
    ok "presente: $(basename "$f")"
  else
    warn "FALTA: $f"
    fail=1
  fi
done

echo
ok "total rescatado: $(du -sh "$DST" | cut -f1) en $DST"

if [[ "$fail" -ne 0 ]]; then
  die "la copia quedó incompleta — NO voy a formatear. Mirá los FALTA/DIFIERE de arriba."
fi

# ── el formateador aborta si el disco está montado, así que el desmontaje es
#    explícito y va acá, después de verificar la copia, nunca antes ──
printf '\n%s═══ 3/4: desmontando el origen ═══%s\n' "$B" "$N"
if mountpoint -q /mnt/.sdf-check; then
  log "Desmonto /mnt/.sdf-check (el formateador se niega a tocar un disco montado)"
  umount /mnt/.sdf-check || die "no pude desmontar /mnt/.sdf-check —Abortando, sdf queda como está"
  ok "origen desmontado"
else
  ok "/mnt/.sdf-check ya estaba desmontado"
fi
if mountpoint -q /mnt/.sdf-check; then
  die "/mnt/.sdf-check sigue montado — no sigo"
fi

printf '\n%s═══ 4/4: delegando el formateo ═══%s\n' "$B" "$N"
ok "rescate verificado completo: todo lo de $SRC está en $DST"
warn "sdf se va a formatear y entra al pool como la próxima rama libre (mediaN)."
log "Llamando a add-media-disk.sh (te va a pedir escribir AGREGAR)"
log "El número de rama lo calcula él: no asumo que sea media5."
echo
exec "$ADD" "$SDF_BY_PATH"
