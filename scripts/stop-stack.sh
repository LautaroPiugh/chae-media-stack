#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Cargar configuración local (MEDIA_SERVER_IP, etc.)
if [ -f "$DIR/.env" ]; then set -a; . "$DIR/.env"; set +a; fi

SERVICES=(
  jellyfin-whatsapp-bot
  nginx-proxy-manager
  adguard
  tdarr
  homepage
  uptime-kuma
  jellyseerr
  jellyfin
  flaresolverr
  bazarr
  qbittorrent
  sonarr
  radarr
  prowlarr
  subgen
  postgres
)

echo "═══ Deteniendo Media Stack ═══"

for svc in "${SERVICES[@]}"; do
  compose_dir="$DIR/services/$svc"
  if [ ! -f "$compose_dir/docker-compose.yml" ]; then
    compose_dir="$DIR/$svc"
    if [ ! -f "$compose_dir/docker-compose.yml" ]; then
      echo "  ✘ $svc: no se encontró"
      continue
    fi
  fi
  echo "  → $svc..."
  docker compose -f "$compose_dir/docker-compose.yml" down 2>&1 | sed 's/^/    /'
done

echo ""
echo "✔ Stack detenido."
