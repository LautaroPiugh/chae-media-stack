#!/usr/bin/env bash
# Provision the reusable, isolated development-agent environment for dev.
# It never copies credentials from chae and never grants stack privileges.
set -Eeuo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"
DEV_LOCAL="${DEV_HOME}/.local"
PNPM_HOME="${DEV_LOCAL}/share/pnpm"
AGENT_PATH="${DEV_LOCAL}/bin:${PNPM_HOME}:${PNPM_HOME}/bin:${DEV_HOME}/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
PASEO_HOME="${DEV_HOME}/.paseo"
PASEO_CONFIG="${PASEO_HOME}/config.json"
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

node_major="$(node -p 'process.versions.node.split(".")[0]')"
node_minor="$(node -p 'process.versions.node.split(".")[1]')"
if (( node_major < 22 || (node_major == 22 && node_minor < 19) )); then
    echo "Pi requires Node.js 22.19 or newer; found $(node --version)."
    exit 1
fi

# Never inherit chae's non-traversable home as dev's package-manager cwd.
cd "$DEV_HOME"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$DEV_LOCAL"

# pnpm owns Paseo, Pi, Gentle Shell, and Codex in dev's home. OpenCode uses
# its official standalone installer, so no second npm OpenCode package exists.
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" NPM_CONFIG_PREFIX="$DEV_LOCAL" \
    PATH="$DEV_LOCAL/bin:/usr/local/bin:/usr/bin:/bin" \
    npm install --global --no-audit --no-fund pnpm@12.15.0

runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" PNPM_HOME="$PNPM_HOME" \
    PATH="$AGENT_PATH" \
    bash -c 'cd "$HOME" && exec pnpm add --global --allow-build=gentle-pi \
        @getpaseo/cli@0.12.0 \
        @openai/codex@latest \
        @earendil-works/pi-coding-agent@1.4.0 \
        gentle-pi@4.3.0'

# Official standalone OpenCode installer, isolated under dev's home.
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" \
    PATH="$AGENT_PATH" \
    bash -c 'curl -fsSL --proto "=https" --tlsv1.2 https://opencode.ai/v2/install | bash'

# Gentle AI v4's OpenCode v2 integration requires the V2 plugin SDK before it
# can write managed plugins. Install it before invoking Gentle AI.
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$DEV_HOME/.config/opencode"
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" \
    PATH="$PNPM_HOME:$PNPM_HOME/bin:$DEV_LOCAL/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -c 'cd "$HOME/.config/opencode" && npm install --save-exact --no-audit --no-fund @opencode/plugin@2.0.4'

# Gentle AI owns OpenCode assets and provisions Engram's OpenCode MCP entry.
gentle_tmp="$(mktemp)"
trap 'rm -f -- "$gentle_tmp"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 \
    https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh \
    -o "$gentle_tmp"
chmod 0755 "$gentle_tmp"
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" \
    PATH="$AGENT_PATH" \
    "$gentle_tmp"

runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" \
    PATH="$AGENT_PATH" \
    gentle-ai install --agent opencode --preset full-gentleman
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" \
    PATH="$AGENT_PATH" \
    gentle-ai sync --agent opencode

# Gentle Shell owns the isolated Pi runtime, its Engram companion and MCP
# configuration. It prevents npm:gentle-pi from being loaded twice there.
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" PNPM_HOME="$PNPM_HOME" \
    PATH="$AGENT_PATH" \
    gentle-shell --isolated setup

# pnpm's global executable directory is implementation-dependent. Resolve the
# installed commands as dev instead of assuming a PNPM_HOME layout.
resolve_dev_command() {
    local command_name="$1"
    local resolved
    resolved="$(runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" PNPM_HOME="$PNPM_HOME" \
        PATH="$AGENT_PATH" bash -c "command -v -- '$command_name'")" || true
    if [[ -z "$resolved" || ! -x "$resolved" ]]; then
        echo "Could not resolve ${command_name} for ${DEV_USER}."
        exit 1
    fi
    printf '%s\n' "$resolved"
}

PASEO_BIN="$(resolve_dev_command paseo)"
GENTLE_SHELL_BIN="$(resolve_dev_command gentle-shell)"

# Back up only the config being changed, then preserve all existing Paseo
# settings while registering the known-good Pi/Gentle Shell auditor provider.
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$DEV_LOCAL/state/agent-bootstrap-backups"
if [[ -f "$PASEO_CONFIG" ]]; then
    backup_dir="$DEV_LOCAL/state/agent-bootstrap-backups/$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$backup_dir"
    install -o "$DEV_USER" -g "$DEV_USER" -m 0600 "$PASEO_CONFIG" "$backup_dir/paseo-config.json"
fi
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$PASEO_HOME"
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" node - "$PASEO_CONFIG" "$GENTLE_SHELL_BIN" <<'NODE'
const fs = require('fs');
const [path, gentleShell] = process.argv.slice(2);
let config = {};
if (fs.existsSync(path)) config = JSON.parse(fs.readFileSync(path, 'utf8'));
config.agents ??= {};
config.agents.providers ??= {};
config.agents.providers['gentle-auditor'] = {
  extends: 'pi',
  label: 'Gentle Auditor',
  command: [gentleShell],
  params: {
    sessionDir: `${process.env.HOME}/.gentle-shell/agent/sessions`,
    rpcTimeoutMs: 60000
  }
};
const temp = `${path}.tmp-${process.pid}`;
fs.writeFileSync(temp, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temp, path);
NODE
chown "$DEV_USER:$DEV_USER" "$PASEO_CONFIG"
chmod 0600 "$PASEO_CONFIG"

if ! grep -Fqx 'export PATH="$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"' "$DEV_HOME/.bashrc"; then
    printf '\n# Development agent CLIs installed by bootstrap-dev-agents.sh\nexport PATH="$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"\n' \
        >>"$DEV_HOME/.bashrc"
    chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.bashrc"
fi

install -o root -g root -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
systemctl daemon-reload
systemctl restart paseo-dev.service
sleep 1
systemctl --no-pager --full is-active paseo-dev.service

runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" PNPM_HOME="$PNPM_HOME" \
    PATH="$AGENT_PATH" \
    bash -c '
        paseo --home "$HOME/.paseo" status --json
        paseo --home "$HOME/.paseo" provider diagnostic opencode --json
        paseo --home "$HOME/.paseo" provider diagnostic gentle-auditor --json
        gentle-ai doctor
    '

echo
echo "dev agents installed: OpenCode implementer, Gentle Auditor, Codex, Pi, Gentle-AI, Gentle Shell, and Engram."
echo "No credentials were copied from chae. Authenticate providers interactively as dev before running paid model tasks."
