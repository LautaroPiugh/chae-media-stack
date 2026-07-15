#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="/mnt/media2/backups/stack"
DATE="$(date +%Y%m%d-%H%M%S)"
RETENTION_DAYS=14

mkdir -p "$BACKUP_DIR"/{configs,database}

echo "[$(date '+%H:%M:%S')] Iniciando backup del stack..."

# ── Postgres DB ──
PG_CONTAINER="chae-postgres"
if docker ps --filter name="$PG_CONTAINER" --format '{{.Names}}' | grep -q "$PG_CONTAINER"; then
  echo "  > Dump de Postgres..."
  PG_DUMPED=false
  for PG_USER in postgres admin root; do
    if docker exec "$PG_CONTAINER" psql -U "$PG_USER" -c "SELECT 1" >/dev/null 2>&1; then
      echo "    -> conectado como: $PG_USER"
      if docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_USER" | gzip > "$BACKUP_DIR/database/postgres-$DATE.sql.gz"; then
        echo "    -> OK: $(du -h "$BACKUP_DIR/database/postgres-$DATE.sql.gz" | cut -f1)"
        PG_DUMPED=true
      fi
      break
    fi
  done
  if ! $PG_DUMPED; then echo "  > WARN: no se pudo conectar a Postgres con ningun usuario"; fi
else
  echo "  > SKIP: Postgres no esta corriendo"
fi

# ── Configs de servicios clave ──
CONFIG_DIRS=(
  "jellyfin:/home/chae/services/jellyfin"
  "sonarr:/home/chae/services/sonarr"
  "radarr:/home/chae/services/radarr"
  "bazarr:/home/chae/services/bazarr"
  "prowlarr:/home/chae/services/prowlarr"
  "qbittorrent:/home/chae/services/qbittorrent"
  "jellyseerr:/home/chae/services/jellyseerr"
  "tdarr:/home/chae/services/tdarr"
  "uptime-kuma:/home/chae/services/uptime-kuma"
)

for pair in "${CONFIG_DIRS[@]}"; do
  name="${pair%%:*}"
  src="${pair##*:}"
  if [ -d "$src" ]; then
    echo "  > Backupeando $name..."
    archive="$BACKUP_DIR/configs/${name}-$DATE.tar.gz"
    echo "    -> $archive"
    tar czf "$archive" -C "$(dirname "$src")" "$(basename "$src")"
  fi
done

# ── Limpiar backups viejos ──
echo "  > Limpiando backups con mas de $RETENTION_DAYS dias..."
find "$BACKUP_DIR" -type f -name "*.gz" -mtime "+$RETENTION_DAYS" -delete

echo "[$(date '+%H:%M:%S')] Backup completado: $BACKUP_DIR"
