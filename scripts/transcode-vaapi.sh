#!/usr/bin/env bash
# transcode-vaapi.sh — re-encode video to HEVC with the AMD iGPU (VAAPI).
#
# Por defecto NO modifica nada: hace un dry-run y lista qué haría.
# Con --apply transcodifica a un temporal EN LA MISMA CARPETA del destino (rename
# atómico) y sólo reemplaza el original si pasa todas las validaciones.
#
# Uso:
#   scripts/transcode-vaapi.sh /mnt/media/tdarr-test
#   scripts/transcode-vaapi.sh --apply --output-dir /mnt/media/tdarr-test/salida /mnt/media/series/Girls/"Season 4"
#   scripts/transcode-vaapi.sh --apply --maxdepth 8 --min-bitrate 5000 /mnt/media/movies
#
# Validaciones antes de aceptar el resultado:
#   - ffmpeg terminó con exit 0
#   - el resultado se puede leer y su códec de video es hevc
#   - la duración coincide con el original (±2 s)  ← atrapa encodes truncados
#   - el tamaño quedó entre --min-ratio y --max-ratio del original
# Si algo falla, borra el temporal y deja el original intacto.
set -euo pipefail

CONTAINER="${TRANSCODE_CONTAINER:-chae-transcoder}"
FFMPEG_BIN="${TRANSCODE_FFMPEG:-/usr/lib/jellyfin-ffmpeg/ffmpeg}"
FFPROBE_BIN="${TRANSCODE_FFPROBE:-/usr/lib/jellyfin-ffmpeg/ffprobe}"
HOST_PREFIX="${TRANSCODE_HOST_PREFIX:-/mnt/media}"
CONT_PREFIX="${TRANSCODE_CONT_PREFIX:-/media}"
LOG="${TRANSCODE_LOG:-$HOME/stack/logs/transcode-vaapi.log}"

QUALITY=32
MIN_BITRATE=0
MIN_RATIO=15
MAX_RATIO=110
MAXDEPTH=1
APPLY=0
OUTPUT_DIR=""
FOLDERS=()
FAILED=0
DONE=0
SKIPPED=0
BYTES_BEFORE=0
BYTES_AFTER=0

usage() {
  cat <<'EOF'
Uso: transcode-vaapi.sh [opciones] <carpeta>...

  --apply              Modifica/escribe archivos (sin esto es dry-run)
  --output-dir DIR     Escribe el resultado en DIR y NO toca el original
  --quality N          global_quality de hevc_vaapi (default: 32; más alto = más chico)
  --min-ratio N        Tamaño mínimo aceptado, % del original (default: 15)
  --max-ratio N        Tamaño máximo aceptado, % del original (default: 110)
  --min-bitrate KBPS   Saltea archivos por debajo de ese bitrate (default: 0 = todos)
  --maxdepth N         Profundidad de búsqueda (default: 1; usá 8 para bibliotecas)
  --log PATH           Archivo de log (default: ~/stack/logs/transcode-vaapi.log)
  -h, --help           Esta ayuda

Variables: TRANSCODE_CONTAINER (default chae-transcoder), TRANSCODE_FFMPEG,
           TRANSCODE_FFPROBE, TRANSCODE_HOST_PREFIX, TRANSCODE_CONT_PREFIX
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)       APPLY=1; shift ;;
    --output-dir)  OUTPUT_DIR="${2:-}"; shift 2 ;;
    --quality)     QUALITY="${2:-}"; shift 2 ;;
    --min-ratio)   MIN_RATIO="${2:-}"; shift 2 ;;
    --max-ratio)   MAX_RATIO="${2:-}"; shift 2 ;;
    --min-bitrate) MIN_BITRATE="${2:-}"; shift 2 ;;
    --maxdepth)    MAXDEPTH="${2:-}"; shift 2 ;;
    --log)         LOG="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            printf 'opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    *)             FOLDERS+=("$1"); shift ;;
  esac
done

[[ ${#FOLDERS[@]} -gt 0 ]] || { usage >&2; exit 2; }
for n in QUALITY MIN_BITRATE MIN_RATIO MAX_RATIO MAXDEPTH; do
  [[ "${!n}" =~ ^[0-9]+$ ]] || { printf '%s debe ser numérico\n' "$n" >&2; exit 2; }
done
if (( MIN_RATIO >= MAX_RATIO )); then
  echo "--min-ratio debe ser menor que --max-ratio" >&2; exit 2
fi

mkdir -p "$(dirname "$LOG")"
[[ -n "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

cont_path() {
  local p="$1"
  [[ "$p" == "$HOST_PREFIX"/* ]] || {
    printf 'ruta fuera de %s: %s\n' "$HOST_PREFIX" "$p" >&2
    return 1
  }
  printf '%s' "${p/#$HOST_PREFIX/$CONT_PREFIX}"
}

probe() {
  local field="$1" file="$2" cp
  cp="$(cont_path "$file")" || return 1
  docker exec "$CONTAINER" "$FFPROBE_BIN" -v error \
    -select_streams v:0 -show_entries "$field" -of csv=p=0 "$cp" 2>/dev/null | head -n1
}

duration() {
  local file="$1" cp
  cp="$(cont_path "$file")" || return 1
  docker exec "$CONTAINER" "$FFPROBE_BIN" -v error \
    -show_entries format=duration -of csv=p=0 "$cp" 2>/dev/null | head -n1
}

file_size() { stat -c%s "$1" 2>/dev/null || echo 0; }

cleanup_tmp() { [[ -n "${TMP:-}" && -f "$TMP" ]] && rm -f "$TMP"; }
trap cleanup_tmp EXIT

process_file() {
  local file="$1"
  local codec bitrate size owner tmp dst cp_file cp_dst cp_tmp out_codec out_size ratio
  local dur_in dur_out

  codec="$(probe stream=codec_name "$file")" || true
  if [[ -z "$codec" ]]; then
    log "SKIP  no se pudo probe: $file"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if [[ "$codec" == "hevc" ]]; then
    log "SKIP  ya es HEVC: $file"; SKIPPED=$((SKIPPED + 1)); return 0
  fi

  if [[ "$MIN_BITRATE" != "0" ]]; then
    bitrate="$(probe format=bit_rate "$file")" || true
    bitrate="${bitrate:-0}"
    if [[ "$bitrate" =~ ^[0-9]+$ ]] && (( bitrate / 1000 < MIN_BITRATE )); then
      log "SKIP  bitrate $((bitrate / 1000))k < ${MIN_BITRATE}k: $file"
      SKIPPED=$((SKIPPED + 1)); return 0
    fi
  fi

  if [[ -n "$OUTPUT_DIR" ]]; then
    dst="$OUTPUT_DIR/$(basename "${file%.*}").mkv"
  else
    dst="$file"
  fi

  if [[ "$APPLY" -eq 0 ]]; then
    log "DRY   $codec -> hevc (q$QUALITY) -> $dst"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi

  size="$(file_size "$file")"
  owner="$(stat -c '%u:%g' "$file" 2>/dev/null || echo 0:0)"
  tmp="$(dirname "$dst")/.transcode-vaapi.$$.mkv"
  TMP="$tmp"

  cp_file="$(cont_path "$file")" || return 1
  cp_dst="$(cont_path "$dst")" || return 1
  cp_tmp="$(cont_path "$tmp")" || return 1

  log "START $file"
  if ! docker exec "$CONTAINER" "$FFMPEG_BIN" \
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

  dur_in="$(duration "$file")" || dur_in=""
  dur_out="$(duration "$tmp")" || dur_out=""
  if [[ -n "$dur_in" && -n "$dur_out" ]]; then
    if ! awk -v a="$dur_in" -v b="$dur_out" 'BEGIN{ d=a-b; if (d<0) d=-d; exit !(d<=2.0) }'; then
      log "FAIL  duración distinta (in=${dur_in}s out=${dur_out}s): $file"
      rm -f "$tmp"; FAILED=$((FAILED + 1)); return 0
    fi
  fi

  out_size="$(file_size "$tmp")"
  if [[ "$size" -gt 0 ]]; then ratio=$(( out_size * 100 / size )); else ratio=0; fi
  if (( ratio < MIN_RATIO || ratio > MAX_RATIO )); then
    log "FAIL  tamaño fuera de rango (${ratio}%, permitido ${MIN_RATIO}-${MAX_RATIO}%): $file"
    rm -f "$tmp"; FAILED=$((FAILED + 1)); return 0
  fi

  mv -f "$tmp" "$dst"
  TMP=""
  docker exec "$CONTAINER" chown "$owner" "$cp_dst" 2>/dev/null || true
  log "OK    ${ratio}% (${size} -> ${out_size} bytes): $dst"
  DONE=$((DONE + 1))
  BYTES_BEFORE=$((BYTES_BEFORE + size))
  BYTES_AFTER=$((BYTES_AFTER + out_size))
}

log "=== transcode-vaapi @ $(hostname) | q=$QUALITY ratio=${MIN_RATIO}-${MAX_RATIO}% min-bitrate=$MIN_BITRATE apply=$APPLY out='${OUTPUT_DIR}' ==="

for folder in "${FOLDERS[@]}"; do
  if [[ ! -d "$folder" ]]; then
    log "SKIP  no es una carpeta: $folder"; continue
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
