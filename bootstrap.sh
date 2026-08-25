#!/usr/bin/env bash
# ============================================================================
#  🐯 CHAE MEDIA STACK — bootstrap
#  Clona el repo y lanza el instalador temático.
#
#  Uso:  bash <(curl -fsSL <url-del-raw>/bootstrap.sh)
# ============================================================================
set -Eeuo pipefail

REPO="https://github.com/LautaroPiugh/chae-media-stack.git"
DEST="${HOME}/chae-media-stack"

echo "🐯 Chae Media Stack — bootstrap"
echo

command -v git >/dev/null 2>&1 || { echo "✘ Necesitás git instalado"; exit 1; }
docker info >/dev/null 2>&1 || echo "▲ Docker no responde todavía (¿lo instalaste/arrancaste?)"

if [ -d "$DEST/.git" ]; then
    echo "→ El repo ya existe en $DEST, actualizando…"
    git -C "$DEST" pull --ff-only || true
else
    echo "→ Clonando en $DEST …"
    git clone --depth 1 "$REPO" "$DEST"
fi

cd "$DEST"
chmod +x install.sh
exec ./install.sh "$@"
