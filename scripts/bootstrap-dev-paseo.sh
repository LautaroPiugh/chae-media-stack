#!/usr/bin/env bash
# Install a separate, unprivileged Paseo daemon for development workspaces.
set -Eeuo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"
PASEO_VERSION="${PASEO_VERSION:-0.9.2}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SOURCE="${SCRIPT_DIR}/systemd/paseo-dev.service"
UNIT_DEST="/etc/systemd/system/paseo-dev.service"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

if ! id "$DEV_USER" >/dev/null 2>&1; then
    echo "Missing development user: run bootstrap-dev-workspace.sh first."
    exit 1
fi

if [[ ! -f "$UNIT_SOURCE" ]]; then
    echo "Missing service definition: $UNIT_SOURCE"
    exit 1
fi

runuser -u "$DEV_USER" -- env \
    HOME="$DEV_HOME" \
    NPM_CONFIG_PREFIX="$DEV_HOME/.local" \
    npm install --global "@getpaseo/cli@${PASEO_VERSION}"

runuser -u "$DEV_USER" -- env \
    HOME="$DEV_HOME" \
    PATH="$DEV_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    paseo onboard \
        --home "$DEV_HOME/.paseo" \
        --listen 127.0.0.1:6769 \
        --relay \
        --no-mcp \
        --voice disable \
        --timeout 120

# Replace the short-lived onboarding supervisor with the service managed by PID 1.
runuser -u "$DEV_USER" -- env \
    HOME="$DEV_HOME" \
    PATH="$DEV_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    paseo daemon stop --home "$DEV_HOME/.paseo" || true

install -o root -g root -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
systemctl daemon-reload
systemctl enable --now paseo-dev.service
systemctl --no-pager --full status paseo-dev.service

echo
echo "Paseo development daemon is running as ${DEV_USER} on 127.0.0.1:6769."
echo "Pair it from the Paseo app with: sudo -u ${DEV_USER} ${DEV_HOME}/.local/bin/paseo pair --home ${DEV_HOME}/.paseo"
