#!/usr/bin/env bash
set -euo pipefail

up="$(docker ps -q | wc -l | tr -d ' ')"
all="$(docker ps -aq | wc -l | tr -d ' ')"
printf 'ctr:%s/%s' "$up" "$all"
