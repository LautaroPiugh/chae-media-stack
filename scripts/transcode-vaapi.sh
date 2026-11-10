#!/usr/bin/env bash
# transcode-vaapi.sh — re-encode video to HEVC with the AMD iGPU (VAAPI).
#
# Pensado para correr de noche sobre una carpeta, sin depender de Tdarr.
# Por defecto NO modifica nada: hace un dry-run y lista qué haría.
# Con --apply transcodifica cada archivo a un temporal EN LA MISMA CARPETA y
# sólo reemplaza el original si el resultado pasa las validaciones.
#
# Uso:
#   scripts/transcode-vaapi.sh /mnt/media/tdarr-test              # dry-run
#   scripts/transcode-vaapi.sh --apply /mnt/media/tdarr-test      # aplica
#   scripts/transcode-vaapi.sh --apply --min-bitrate 5000 /mnt/media/movies
#
# Validaciones antes de reemplazar:
#   - ffmpeg terminó con exit 0
#   - el resultado se puede leer y su códec de video es hevc
#   - el tamaño quedó entre el 40% y el 110% del original
# Si algo falla, borra el temporal y deja el original intacto.
set -euo pipefail

CONTAINER="${TRANSCODE_CONTAINER:-chae-tdarr-node}"
HOST_PREFIX="${TRANSCODE_HOST_PREFIX:-/mnt/media}"
CONT_PREFIX="${TRANSCODE_CONT_PREFIX:-/media}"
LOG="${TRANSCODE_LOG:-$HOME/stack/logs/transcode-vaapi.log}"

QUALITY=32
MIN_BITRATE=0
APPLY=0
MAXDEPTH=1
FOLDERS=()
FAILED=0
DONE=0
SKIPPED=0
BYTES_BEFORE=0
BYTES_AFTER=0

usage() {
  cat <<'EOF'
Uso: transcode-vaapi.sh [opciones] <carpeta>...

  --apply              Modifica archivos (sin esto es dry-run)
  --quality N          global_quality de hevc_vaapi (default: 32; más alto = más chico)
  --min-bitrate KBPS   Saltea archivos por debajo de ese bitrate (default: 0 = todos)
  --maxdepth N         Profundidad de búsqueda (default: 1; usá 8 para bibliotecas)
  --log PATH           Archivo de log (default: ~/stack/logs/transcode-vaapi.log)
  -h, --help           Esta ayuda

Variables: TRANSCODE_CONTAINER, TRANSCODE_HOST_PREFIX, TRANSCODE_CONT_PREFIX
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)       APPLY=1; shift ;;
    --quality)     QUALITY="${2:-}"; shift 2 ;;
    --min-bitrate) MIN_BITRATE="${2:-}"; shift 2 ;;
    --maxdepth)    MAXDEPTH="${2:-}"; shift 2 ;;
    --log)         LOG="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            printf 'opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    *)             FOLDERS+=("$1"); shift ;;
  esac
done

[[ ${#FOLDERS[@]} -gt 0 ]] || { usage >&2; exit 2; }
[[ "$QUALITY" =~ ^[0-9]+$ ]] || { echo "--quality debe ser numérico" >&2; exit 2; }
[[ "$MIN_BITRATE" =~ ^[0-9]+$ ]] || { echo "--min-bitrate debe ser numérico" >&2; exit 2; }
[[ "$MAXDEPTH" =~ ^[0-9]+$ ]] || { echo "--maxdepth debe ser numérico" >&2; exit 2; }

mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

# cont_path <host-path> — traduce /mnt/media/... a /media/... para el contenedor.
cont_path() {
  local p="$1"
  [[ "$p" == "$HOST_PREFIX"/* ]] || {
    printf 'ruta fuera de %s: %s\n' "$HOST_PREFIX" "$p" >&2
    return 1
  }
  printf '%s' "${p/#$HOST_PREFIX/$CONT_PREFIX}"
}

# probe <campo> <host-path> — consulta ffprobe dentro del contenedor.
probe() {
  local field="$1" file="$2" cp
  cp="$(cont_path "$file")" || return 1
  docker exec "$CONTAINER" /usr/local/bin/ffprobe -v error \
    -select_streams v:0 -show_entries "$field" -of csv=p=0 "$cp" 2>/dev/null | head -n1
}

file_size() { stat -c%s "$1" 2>/dev/null || echo 0; }

cleanup_tmp() { [[ -n "${TMP:-}" && -f "$TMP" ]] && rm -f "$TMP"; }
trap cleanup_tmp EXIT

process_file() {
  local file="$1"
  local codec bitrate size tmp cp_file cp_tmp out_codec out_size ratio owner

  codec="$(probe stream=codec_name "$file")" || true
  if [[ -z "$codec" ]]; then
    log "SKIP  no se pudo probe: $file"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if [[ "$codec" == "hevc" ]]; then
    log "SKIP  ya es HEVC: $file"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi

  if [[ "$MIN_BITRATE" != "0" ]]; then
    bitrate="$(probe format=bit_rate "$file")" || true
    bitrate="${bitrate:-0}"
    if [[ "$bitrate" =~ ^[0-9]+$ ]] && (( bitrate / 1000 < MIN_BITRATE )); then
      log "SKIP  bitrate $((bitrate / 1000))k < $MIN_BITRATE k: $file"
      SKIPPED=$((SKIPPED + 1)); return 0
    fi
  fi

  size="$(file_size "$file")"
  owner="$(stat -c '%u:%g' "$file" 2>/dev/null || echo 0:0)"
  tmp="$(dirname "$file")/.transcode-vaapi.$$.mkv"
  TMP="$tmp"

  if [[ "$APPLY" -eq 0 ]]; then
    log "DRY   $codec -> hevc (q$QUALITY): $file"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi

  cp_file="$(cont_path "$file")" || return 1
  cp_tmp="$(cont_path "$tmp")" || return 1

  log "START $file"
  if ! docker exec "$CONTAINER" /usr/local/bin/ffmpeg \
      -hide_banner -nostdin -loglevel error -y \
      -hwaccel vaapi -hwaccel_output_format vaapi \
      -vaapi_device /dev/dri/renderD128 \
      -i "$cp_file" \
      -map 0:v -map 0:a? -map 0:s? \
      -c copy -c:v hevc_vaapi -global_quality "$QUALITY" \
      -f matroska "$cp_tmp" >>"$LOG" 2>&1; then
    log "FAIL  ffmpeg falló: $file"
    rm -f "$tmp"; FAILED=$((FAILED + 1)); return 0
  fi

  out_codec="$(probe stream=codec_name "$tmp")" || true
  if [[ "$out_codec" != "hevc" ]]; then
    log "FAIL  salida no es hevc ('${out_codec:-?}'): $file"
    rm -f "$tmp"; FAILED=$((FAILED + 1)); return 0
  fi

  out_size="$(file_size "$tmp")"
  if [[ "$size" -gt 0 ]]; then
    ratio=$(( out_size * 100 / size ))
  else
    ratio=0
  fi
  if (( ratio < 40 || ratio > 110 )); then
    log "FAIL  tamaño fuera de rango (${ratio}%): $file"
    rm -f "$tmp"; FAILED=$((FAILED + 1)); return 0
  fi

  mv -f "$tmp" "$file"
  # ffmpeg corre como root en el contenedor: devolvemos el dueño original.
  docker exec "$CONTAINER" chown "$owner" "$cp_file" 2>/dev/null || true
  log "OK    ${ratio}% (${size} -> ${out_size} bytes): $file"
  DONE=$((DONE + 1))
  BYTES_BEFORE=$((BYTES_BEFORE + size))
  BYTES_AFTER=$((BYTES_AFTER + out_size))
  TMP=""
}

log "=== transcode-vaapi @ $(hostname) | quality=$QUALITY min-bitrate=$MIN_BITRATE apply=$APPLY ==="

for folder in "${FOLDERS[@]}"; do
  if [[ ! -d "$folder" ]]; then
    log "SKIP  no es una carpeta: $folder"
    continue
  fi
  while IFS= read -r -d '' file; do
    process_file "$file" || true
  done < <(find "$folder" -maxdepth "$MAXDEPTH" -type f \
             \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.ts' -o -iname '*.m4v' \) \
             -print0 | sort -z)
done

{
  printf '\nRESUMEN: %d transcodificados, %d fallidos, %d salteados\n' "$DONE" "$FAILED" "$SKIPPED"
  if (( DONE > 0 )); then
    pct="$(awk -v a="$BYTES_AFTER" -v b="$BYTES_BEFORE" 'BEGIN{ if (b>0) printf "%.1f", a*100/b; else printf "0.0" }')"
    printf 'Espacio: %d -> %d bytes (%s%% del original)\n' "$BYTES_BEFORE" "$BYTES_AFTER" "$pct"
  fi
  [[ "$APPLY" -eq 0 ]] && printf 'Dry-run: nada se modificó. Usá --apply para ejecutar.\n'
  printf 'Log: %s\n' "$LOG"
} | tee -a "$LOG" >&2

[[ "$FAILED" -eq 0 ]]
