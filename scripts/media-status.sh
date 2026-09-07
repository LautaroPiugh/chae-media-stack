#!/usr/bin/env bash
set -Eeuo pipefail

MEDIA1_PATH="${MEDIA1_PATH:-/mnt/media1}"
MEDIA2_PATH="${MEDIA2_PATH:-/mnt/media2}"
MEDIA3_PATH="${MEDIA3_PATH:-/mnt/media3}"
MEDIA4_PATH="${MEDIA4_PATH:-/mnt/media4}"
MEDIA_POOL_PATH="${MEDIA_POOL_PATH:-/mnt/media}"
MEDIA1_UUID="${MEDIA1_UUID:-E41C8ED01C8E9CE4}"
MEDIA2_UUID="${MEDIA2_UUID:-3FD22A422077368D}"
MEDIA3_UUID="${MEDIA3_UUID:-f5b48469-5ece-4e75-a90d-7ff6a93c4dfe}"
MEDIA4_UUID="${MEDIA4_UUID:-a4325f7b-fd22-4a64-8f1e-fd90483740c5}"

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

is_rw_mount() {
  local path="$1"
  local options
  options="$(findmnt -rn -o OPTIONS --target "$path" 2>/dev/null || true)"
  [[ ",$options," == *,rw,* ]]
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
      [[ "$argument" == "$MEDIA1_PATH:$MEDIA2_PATH:$MEDIA3_PATH:$MEDIA4_PATH" ]] && branches_found=1
      [[ "$argument" == "$MEDIA_POOL_PATH" ]] && mountpoint_found=1
    done
    if [[ "$branches_found" -eq 1 && "$mountpoint_found" -eq 1 ]]; then
      return 0
    fi
  done
  return 1
}

if branch_is_healthy "$MEDIA1_PATH" "$MEDIA1_UUID" \
  && branch_is_healthy "$MEDIA2_PATH" "$MEDIA2_UUID" \
  && branch_is_healthy "$MEDIA3_PATH" "$MEDIA3_UUID" \
  && branch_is_healthy "$MEDIA4_PATH" "$MEDIA4_UUID" \
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
