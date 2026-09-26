#!/usr/bin/env bash
set -Eeuo pipefail

MEDIA_POOL_PATH="${MEDIA_POOL_PATH:-/mnt/media}"
CONFIG_FILE="${MEDIA_BRANCHES_CONFIG:-/home/chae/stack/.media-branches.conf}"
BRANCH_PATHS=()
BRANCH_UUIDS=()
EXPECTED_BRANCHES=''

config_get() {
  local key="$1"
  [[ -f "$CONFIG_FILE" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG_FILE"
}

load_media_config() {
  local branches_raw uuids_raw
  [[ -f "$CONFIG_FILE" ]] || return 1
  branches_raw="$(config_get MEDIA_BRANCHES || true)"
  uuids_raw="$(config_get MEDIA_UUIDS || true)"
  [[ -n "$branches_raw" && -n "$uuids_raw" ]] || return 1
  IFS=':' read -ra BRANCH_PATHS <<< "$branches_raw"
  IFS=':' read -ra BRANCH_UUIDS <<< "$uuids_raw"
  [[ "${#BRANCH_PATHS[@]}" -gt 0 && "${#BRANCH_PATHS[@]}" -eq "${#BRANCH_UUIDS[@]}" ]] || return 1
  EXPECTED_BRANCHES="$branches_raw"
  return 0
}

is_rw_mount() {
  local path="$1"
  local options
  options="$(findmnt -rn -o OPTIONS --target "$path" 2>/dev/null || true)"
  [[ ",$options," == *,rw,* ]]
}

branch_is_healthy() {
  local path="$1"
  local expected_uuid="$2"
  local current_uuid

  [[ -d "$path" && -e "/dev/disk/by-uuid/$expected_uuid" ]] || return 1
  mountpoint -q "$path" || return 1
  current_uuid="$(findmnt -rn -o UUID --target "$path" 2>/dev/null || true)"
  [[ "$current_uuid" == "$expected_uuid" ]] || return 1
  is_rw_mount "$path"
}

pool_has_expected_branches() {
  local command_line
  local executable
  local argument
  local branches_found
  local mountpoint_found
  local -a arguments=()

  for command_line in /proc/[0-9]*/cmdline; do
    arguments=()
    mapfile -d '' -t arguments < "$command_line" 2>/dev/null || continue
    [[ "${#arguments[@]}" -ge 3 ]] || continue
    executable="${arguments[0]##*/}"
    [[ "$executable" == 'mergerfs' ]] || continue
    branches_found=0
    mountpoint_found=0
    for argument in "${arguments[@]:1}"; do
      [[ "$argument" == "$EXPECTED_BRANCHES" ]] && branches_found=1
      [[ "$argument" == "$MEDIA_POOL_PATH" ]] && mountpoint_found=1
    done
    if [[ "$branches_found" -eq 1 && "$mountpoint_found" -eq 1 ]]; then
      return 0
    fi
  done
  return 1
}

load_media_config || { printf 'missing\n'; exit 1; }

all_branches_ok=1
for i in "${!BRANCH_PATHS[@]}"; do
  if ! branch_is_healthy "${BRANCH_PATHS[$i]}" "${BRANCH_UUIDS[$i]}"; then
    all_branches_ok=0
    break
  fi
done

if [[ "$all_branches_ok" -eq 1 ]] \
  && mountpoint -q "$MEDIA_POOL_PATH" \
  && [[ "$(findmnt -rn -o FSTYPE --target "$MEDIA_POOL_PATH" 2>/dev/null || true)" == 'fuse.mergerfs' ]] \
  && pool_has_expected_branches \
  && is_rw_mount "$MEDIA_POOL_PATH" \
  && [[ -d "$MEDIA_POOL_PATH/series" ]] \
  && [[ -d "$MEDIA_POOL_PATH/movies" ]] \
  && [[ -d "$MEDIA_POOL_PATH/downloads" ]]; then
  printf 'healthy\n'
  exit 0
fi

printf 'missing\n'
exit 1
