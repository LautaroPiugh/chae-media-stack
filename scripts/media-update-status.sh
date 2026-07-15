#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/media-stack-update.state"

if [[ ! -f "$STATE_FILE" ]]; then
  printf 'upd:never'
  exit 0
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

if [[ -z "${last_run:-}" || -z "${last_status:-}" ]]; then
  printf 'upd:unknown'
  exit 0
fi

printf 'upd:%s/%s %s' "$last_status" "${last_mode:-all}" "$(date -d "@$last_run" '+%d/%m %H:%M')"
