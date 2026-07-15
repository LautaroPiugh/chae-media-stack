#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.local/state/media-mount-recovery"
STATE_FILE="${STATE_DIR}/last_state"
LOG_FILE="${STATE_DIR}/recovery.log"
MOUNTPOINT_PATH="/mnt/media"
EXPECTED_DIRS=(
  "/mnt/media/movies"
  "/mnt/media/series"
  "/mnt/media/downloads"
)
CONTAINERS=(
  "chae-radarr"
  "chae-sonarr"
  "chae-bazarr"
  "chae-jellyfin"
  "chae-qbittorrent"
)

mkdir -p "${STATE_DIR}"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >> "${LOG_FILE}"
}

is_mount_healthy() {
  mountpoint -q "${MOUNTPOINT_PATH}" || return 1

  for path in "${EXPECTED_DIRS[@]}"; do
    [[ -d "${path}" ]] || return 1
  done

  return 0
}

last_state="unknown"
if [[ -f "${STATE_FILE}" ]]; then
  last_state="$(<"${STATE_FILE}")"
fi

if is_mount_healthy; then
  current_state="healthy"
else
  current_state="missing"
fi

printf '%s' "${current_state}" > "${STATE_FILE}"

if [[ "${last_state}" == "missing" && "${current_state}" == "healthy" ]]; then
  log "Media mount recovered. Restarting media containers."
  docker restart "${CONTAINERS[@]}" >> "${LOG_FILE}" 2>&1 || log "Container restart failed."
elif [[ "${last_state}" != "${current_state}" ]]; then
  log "Media mount state changed: ${last_state} -> ${current_state}"
fi
