#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Cargar configuración local (MEDIA_SERVER_IP, etc.)
if [ -f "$DIR/.env" ]; then set -a; . "$DIR/.env"; set +a; fi
# SIN export COMPOSE_PROJECT_NAME. Cada compose declara container_name, y los
# 21 contenedores vivos usan el project name del directorio de su compose
# (adb guard, radarr, tdarr…). Poner acá "media-stack" hacía que este script
# buscara un project que no existe e intentara crear un segundo set con los
# mismos container_name: conflicto. stop-stack.sh nunca exportó nada, así que
# los dos scripts además no concordaban entre sí.
# Si algún día se quiere un project name único, va en el .env de la raíz
# (Compose lo lee solo desde ahí), no acá.

SERVICES=(
  postgres
  prowlarr
  radarr
  sonarr
  qbittorrent
  bazarr
  jellyfin
  jellyseerr
  flaresolverr
  subgen
  uptime-kuma
  homepage
  tdarr
  adguard
  recyclarr
  qbitmanage
  scrutiny
  dozzle
)

echo "═══ Iniciando Media Stack ═══"

for svc in "${SERVICES[@]}"; do
  compose_dir="$DIR/services/$svc"
  if [ ! -f "$compose_dir/docker-compose.yml" ]; then
    echo "  ✘ $svc: no se encontró docker-compose.yml"
    continue
  fi
  echo "  → $svc..."
  compose_args=(-f "$compose_dir/docker-compose.yml")
    [ -f "$compose_dir/docker-compose.override.yml" ] && compose_args+=(-f "$compose_dir/docker-compose.override.yml")
    docker compose "${compose_args[@]}" up -d 2>&1 | sed 's/^/    /'
done

echo "  → jellyfin-whatsapp-bot..."
docker compose -f "$DIR/jellyfin-whatsapp-bot/docker-compose.yml" up -d --build 2>&1 | sed 's/^/    /'

echo ""
echo "✔ Stack iniciado. Ejecute ./scripts/health-check.sh para verificar estado."
