#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Cargar configuración local (MEDIA_SERVER_IP, etc.)
if [ -f "$DIR/.env" ]; then set -a; . "$DIR/.env"; set +a; fi
export COMPOSE_PROJECT_NAME=media-stack

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
  nginx-proxy-manager
)

echo "═══ Iniciando Media Stack ═══"

for svc in "${SERVICES[@]}"; do
  compose_dir="$DIR/services/$svc"
  if [ ! -f "$compose_dir/docker-compose.yml" ]; then
    echo "  ✘ $svc: no se encontró docker-compose.yml"
    continue
  fi
  echo "  → $svc..."
  docker compose -f "$compose_dir/docker-compose.yml" up -d 2>&1 | sed 's/^/    /'
done

echo "  → jellyfin-whatsapp-bot..."
docker compose -f "$DIR/jellyfin-whatsapp-bot/docker-compose.yml" up -d --build 2>&1 | sed 's/^/    /'

echo ""
echo "✔ Stack iniciado. Ejecute ./scripts/health-check.sh para verificar estado."
