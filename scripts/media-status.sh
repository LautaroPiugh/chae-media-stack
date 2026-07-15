#!/usr/bin/env bash
set -euo pipefail

if mountpoint -q /mnt/media && [[ -d /mnt/media/series ]] && [[ -d /mnt/media/movies ]]; then
  echo "healthy"
else
  echo "missing"
fi
