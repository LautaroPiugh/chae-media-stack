#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${MEDIA_STACK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
QBT_CONFIG="$ROOT/services/qbittorrent/config/qBittorrent/qBittorrent.conf"
SONARR_CONFIG="$ROOT/services/sonarr/config/config.xml"
QBT_URL="${QBT_URL:-http://127.0.0.1:8080}"
SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989/api/v3}"
MAX_STALLED_HOURS="${SONARR_MAX_STALLED_HOURS:-12}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/chae-media-update"
LOCK_FILE="$STATE_DIR/stalled-sonarr-torrents.lock"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -r "$1" ]] || die "no se puede leer: $1"
}

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || {
  log 'Otra revision de torrents Sonarr ya esta en ejecucion'
  exit 0
}

require_file "$QBT_CONFIG"
require_file "$SONARR_CONFIG"
command -v curl >/dev/null || die 'falta curl'
command -v jq >/dev/null || die 'falta jq'

QBT_KEY="$(sed -n 's#^WebUI\\APIKey=##p' "$QBT_CONFIG")"
SONARR_KEY="$(awk -F'[<>]' '/<ApiKey>/{print $3; exit}' "$SONARR_CONFIG")"
[[ -n "$QBT_KEY" ]] || die 'no se encontro la API key de qBittorrent'
[[ -n "$SONARR_KEY" ]] || die 'no se encontro la API key de Sonarr'

qbt() {
  curl -fsS -H "Authorization: Bearer $QBT_KEY" "$@"
}

sonarr() {
  curl -fsS -H "X-Api-Key: $SONARR_KEY" "$@"
}

cutoff="$(( $(date +%s) - MAX_STALLED_HOURS * 3600 ))"
torrents="$(qbt "$QBT_URL/api/v2/torrents/info")"
candidates="$(jq -c --argjson cutoff "$cutoff" '
  [.[]
   | select(.category == "sonarr")
   | select(.state == "stalledDL")
   | select((.num_seeds // 0) == 0)
   | select((.added_on // 0) > 0 and .added_on <= $cutoff)
   | {hash, name, added_on}]
' <<<"$torrents")"

if [[ "$candidates" == '[]' ]]; then
  log 'No hay torrents Sonarr estancados con 0 seeds fuera del umbral'
  exit 0
fi

queue="$(sonarr "$SONARR_URL/queue?pagesize=1000")"
while IFS= read -r candidate; do
  hash="$(jq -r '.hash' <<<"$candidate")"
  name="$(jq -r '.name' <<<"$candidate")"
  log "Retirando torrent estancado: $name"

  # Conserva los datos parciales para que nunca se borren por esta politica.
  qbt -X POST \
    --data-urlencode "hashes=$hash" \
    --data-urlencode 'deleteFiles=false' \
    "$QBT_URL/api/v2/torrents/delete" >/dev/null

  mapfile -t queue_ids < <(jq -r --arg hash "$hash" '
    .records[]
    | select((.downloadId // "") | ascii_downcase == $hash)
    | .id
  ' <<<"$queue")
  mapfile -t series_ids < <(jq -r --arg hash "$hash" '
    [.records[]
     | select((.downloadId // "") | ascii_downcase == $hash)
     | .seriesId] | unique[]
  ' <<<"$queue")

  for queue_id in "${queue_ids[@]}"; do
    curl -fsS -X DELETE -H "X-Api-Key: $SONARR_KEY" \
      "$SONARR_URL/queue/$queue_id?removeFromClient=false&blocklist=true" >/dev/null \
      || log "WARN: no se pudo limpiar la entrada Sonarr $queue_id"
  done

  for series_id in "${series_ids[@]}"; do
    sonarr -X POST -H 'Content-Type: application/json' \
      --data "{\"name\":\"SeriesSearch\",\"seriesId\":$series_id}" \
      "$SONARR_URL/command" >/dev/null
    log "Busqueda relanzada para la serie $series_id"
  done
done < <(jq -c '.[]' <<<"$candidates")
