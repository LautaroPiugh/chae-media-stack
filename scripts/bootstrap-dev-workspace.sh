#!/usr/bin/env bash
# Create the unprivileged, isolated account used for all development projects.
set -Eeuo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_ROOT="${DEV_ROOT:-/srv/dev}"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

if ! command -v setfacl >/dev/null 2>&1; then
    echo "Missing dependency: install the 'acl' package first (sudo apt-get install acl)."
    exit 1
fi

if ! id "$DEV_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$DEV_USER"
fi

DEV_GROUP="$(id -gn "$DEV_USER")"
install -d -o "$DEV_USER" -g "$DEV_GROUP" -m 0750 "$DEV_ROOT"
install -d -o "$DEV_USER" -g "$DEV_GROUP" -m 0750 \
    "$DEV_ROOT/workspaces" "$DEV_ROOT/bin" "$DEV_ROOT/state"

# Preserve the media stack's existing ownership while preventing development
# code from traversing its home directory or reading the media libraries.
for path in /home/chae /mnt/media /mnt/media1 /mnt/media2 /mnt/media3 \
            /mnt/media4 /mnt/media5 /mnt/media6; do
    [[ -d "$path" ]] || continue
    setfacl -m "u:${DEV_USER}:---" "$path"
done

echo "Development account ready: $DEV_USER"
echo "Workspace root: $DEV_ROOT/workspaces"
echo "No sudo, Docker access, media access, or stack access was granted."
