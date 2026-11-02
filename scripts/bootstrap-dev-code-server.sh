#!/usr/bin/env bash
# Install Code Server for the isolated development account and publish it only
# through Tailscale Serve, never on the LAN or public Internet.
set -Eeuo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"
CODE_SERVER_CONFIG="${DEV_HOME}/.config/code-server/config.yaml"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SOURCE="${SCRIPT_DIR}/systemd/code-server-dev.service"
UNIT_DEST="/etc/systemd/system/code-server-dev.service"

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

# The official standalone installer writes only under the dev account.
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" \
    bash -c 'curl -fsSL --proto "=https" --tlsv1.2 https://code-server.dev/install.sh | sh -s -- --method=standalone'

install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$(dirname "$CODE_SERVER_CONFIG")"
if [[ ! -f "$CODE_SERVER_CONFIG" ]]; then
    password="$(openssl rand -hex 32)"
    printf '%s\n' \
        'bind-addr: 127.0.0.1:8088' \
        'auth: password' \
        "password: ${password}" \
        'cert: false' \
        'disable-telemetry: true' \
        | install -o "$DEV_USER" -g "$DEV_USER" -m 0600 /dev/stdin "$CODE_SERVER_CONFIG"
fi

install -o root -g root -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
systemctl daemon-reload
systemctl enable --now code-server-dev.service

# Tailscale Serve provides HTTPS only to the tailnet. This is not Funnel.
tailscale serve --https=443 --bg --yes http://127.0.0.1:8088

systemctl --no-pager --full status code-server-dev.service
tailscale serve status
echo
echo "Code Server password: sudo -u ${DEV_USER} cat ${CODE_SERVER_CONFIG}"
