#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${STACK_BACKUP_DIR:-/mnt/media2/backups/stack}"
DATE="$(date +%Y%m%d-%H%M%S)"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
DRY_RUN="${DRY_RUN:-0}"
PG_COMPOSE_FILE="${PG_BACKUP_COMPOSE_FILE:-$PROJECT_DIR/services/postgres/docker-compose.yml}"
PG_COMPOSE_SERVICE="${PG_BACKUP_COMPOSE_SERVICE:-postgres}"
PG_CONTAINER="${PG_BACKUP_CONTAINER:-}"
PG_USER="${PG_BACKUP_USER:-}"
PG_DATABASE="${PG_BACKUP_DATABASE:-}"
BACKUP_LOCK_FILE="${BACKUP_LOCK_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/chae-backup-stack.lock}"
TMP_DUMP=''
JELLYFIN_DB_SNAPSHOT=''
TMP_JELLYFIN_GZIP=''

umask 077

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DUMP" && -f "$TMP_DUMP" ]]; then
    rm -f -- "$TMP_DUMP"
  fi
  if [[ -n "$JELLYFIN_DB_SNAPSHOT" && -f "$JELLYFIN_DB_SNAPSHOT" ]]; then
    rm -f -- "$JELLYFIN_DB_SNAPSHOT"
  fi
  if [[ -n "$TMP_JELLYFIN_GZIP" && -f "$TMP_JELLYFIN_GZIP" ]]; then
    rm -f -- "$TMP_JELLYFIN_GZIP"
  fi
}

trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "comando requerido no encontrado: $1"
}

container_env() {
  docker exec "$PG_CONTAINER" printenv "$1" 2>/dev/null || true
}

run_postgres_command() {
  docker exec "$PG_CONTAINER" sh -eu -c '
    if [ -z "${PGPASSWORD:-}" ]; then
      if [ -n "${POSTGRES_PASSWORD:-}" ]; then
        PGPASSWORD="$POSTGRES_PASSWORD"
        export PGPASSWORD
      elif [ -n "${POSTGRES_PASSWORD_FILE:-}" ] && [ -r "$POSTGRES_PASSWORD_FILE" ]; then
        PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"
        export PGPASSWORD
      fi
    fi
    exec "$@"
  ' sh "$@"
}

can_connect() {
  local user="$1"
  local database="$2"

  run_postgres_command psql \
    --username="$user" \
    --dbname="$database" \
    --no-password \
    --tuples-only \
    --no-align \
    --command='SELECT 1;' >/dev/null 2>&1
}

select_postgres_identity() {
  local compose_container=''
  local compose_user=''
  local compose_database=''
  local runtime_user=''
  local runtime_database=''
  local compose_metadata=''
  local -a compose_values=()
  local candidate_user=''
  local candidate_database=''
  local -a candidate_users=()
  local -a candidate_databases=()
  local index

  if [[ -f "$PG_COMPOSE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    if compose_metadata="$(
      docker compose -f "$PG_COMPOSE_FILE" config --format json 2>/dev/null \
        | jq -r --arg service "$PG_COMPOSE_SERVICE" '
            (.services[$service] // {}) as $service_config
            | [
                ($service_config.container_name // ""),
                ($service_config.environment.POSTGRES_USER // ""),
                ($service_config.environment.POSTGRES_DB // "")
              ]
            | .[]
          '
    )"; then
      mapfile -t compose_values <<<"$compose_metadata"
      compose_container="${compose_values[0]:-}"
      compose_user="${compose_values[1]:-}"
      compose_database="${compose_values[2]:-}"
    else
      log "WARN: no se pudo leer la configuracion Compose de PostgreSQL"
    fi
  elif [[ -f "$PG_COMPOSE_FILE" ]]; then
    log "WARN: jq no esta disponible; se omite la deteccion desde Compose"
  fi
  unset compose_metadata compose_values

  PG_CONTAINER="${PG_CONTAINER:-${compose_container:-chae-postgres}}"

  [[ "$(docker inspect --format '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null || true)" == 'true' ]] \
    || die "el contenedor PostgreSQL no esta corriendo: $PG_CONTAINER"

  runtime_user="$(container_env POSTGRES_USER)"
  runtime_database="$(container_env POSTGRES_DB)"

  if [[ -n "$PG_USER" ]]; then
    candidate_database="${PG_DATABASE:-$PG_USER}"
    if ! can_connect "$PG_USER" "$candidate_database"; then
      die "no se pudo conectar con PG_BACKUP_USER=$PG_USER y base $candidate_database"
    fi
    PG_DATABASE="$candidate_database"
    return
  fi

  if [[ -n "$compose_user" ]]; then
    candidate_users+=("$compose_user")
    candidate_databases+=("${PG_DATABASE:-${compose_database:-$compose_user}}")
  fi

  if [[ -n "$runtime_user" && "$runtime_user" != "$compose_user" ]]; then
    candidate_users+=("$runtime_user")
    candidate_databases+=("${PG_DATABASE:-${runtime_database:-$runtime_user}}")
  fi

  if [[ "$compose_user" != 'chae' && "$runtime_user" != 'chae' ]]; then
    candidate_users+=('chae')
    candidate_databases+=("${PG_DATABASE:-chae}")
  fi

  if [[ "$compose_user" != 'postgres' && "$runtime_user" != 'postgres' ]]; then
    candidate_users+=('postgres')
    candidate_databases+=("${PG_DATABASE:-postgres}")
  fi

  for index in "${!candidate_users[@]}"; do
    candidate_user="${candidate_users[$index]}"
    candidate_database="${candidate_databases[$index]}"
    if can_connect "$candidate_user" "$candidate_database"; then
      PG_USER="$candidate_user"
      PG_DATABASE="$candidate_database"
      return
    fi
    log "WARN: el candidato PostgreSQL $candidate_user/$candidate_database no pudo autenticarse"
  done

  die "no se encontro un usuario/base PostgreSQL validos; defina PG_BACKUP_USER y PG_BACKUP_DATABASE"
}

[[ "$DRY_RUN" == '0' || "$DRY_RUN" == '1' ]] || die "DRY_RUN debe ser 0 o 1"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_RETENTION_DAYS debe ser un entero no negativo"

require_cmd docker
select_postgres_identity

log "PostgreSQL detectado: contenedor=$PG_CONTAINER usuario=$PG_USER base=$PG_DATABASE"

if [[ "$DRY_RUN" == '1' ]]; then
  log "DRY_RUN: conexion PostgreSQL validada; no se crearon, movieron ni eliminaron backups"
  log "DRY_RUN: destino previsto $BACKUP_DIR/database/postgres-$DATE.sql.gz"
  exit 0
fi

require_cmd gzip
require_cmd flock
require_cmd mktemp
require_cmd node
require_cmd tar

mkdir -p "$(dirname "$BACKUP_LOCK_FILE")"
chmod 700 "$(dirname "$BACKUP_LOCK_FILE")" 2>/dev/null || true
exec 9>"$BACKUP_LOCK_FILE"
chmod 600 "$BACKUP_LOCK_FILE" 2>/dev/null || true
flock -n 9 || die "ya hay otro backup del stack en ejecucion"

mkdir -p "$BACKUP_DIR"/{configs,database}

log "Iniciando backup del stack..."

# ── Postgres DB ──
FINAL_DUMP="$BACKUP_DIR/database/postgres-$DATE.sql.gz"
[[ ! -e "$FINAL_DUMP" ]] || die "el archivo final ya existe: $FINAL_DUMP"

TMP_DUMP="$(mktemp "$BACKUP_DIR/database/.postgres-$DATE.XXXXXX.sql.gz")"
chmod 600 "$TMP_DUMP" 2>/dev/null || true

log "Generando dump completo de PostgreSQL..."
if ! run_postgres_command pg_dumpall \
  --username="$PG_USER" \
  --database="$PG_DATABASE" \
  | gzip -c > "$TMP_DUMP"; then
  die "pg_dumpall o gzip fallo; no se publico ningun backup nuevo"
fi

[[ -s "$TMP_DUMP" ]] || die "el dump comprimido quedo vacio"
gzip -t "$TMP_DUMP" || die "el dump no supera gzip -t"

if ! UNCOMPRESSED_BYTES="$(gzip -dc "$TMP_DUMP" | wc -c | tr -d '[:space:]')"; then
  die "no se pudo medir el contenido descomprimido"
fi
[[ "$UNCOMPRESSED_BYTES" =~ ^[0-9]+$ && "$UNCOMPRESSED_BYTES" -gt 0 ]] \
  || die "el contenido SQL descomprimido esta vacio"

if ! gzip -dc "$TMP_DUMP" | grep -F 'PostgreSQL database cluster dump' >/dev/null; then
  die "el archivo no contiene la cabecera esperada de pg_dumpall"
fi

mv -- "$TMP_DUMP" "$FINAL_DUMP"
TMP_DUMP=''
log "Dump PostgreSQL verificado: $FINAL_DUMP ($UNCOMPRESSED_BYTES bytes SQL sin comprimir)"

# ── Jellyfin SQLite DB ──
JELLYFIN_DB="$PROJECT_DIR/services/jellyfin/config/data/data/jellyfin.db"
JELLYFIN_DB_BACKUP="$BACKUP_DIR/database/jellyfin-$DATE.db.gz"
[[ -f "$JELLYFIN_DB" ]] || die "falta la base SQLite de Jellyfin: $JELLYFIN_DB"
[[ ! -e "$JELLYFIN_DB_BACKUP" ]] || die "el archivo final ya existe: $JELLYFIN_DB_BACKUP"

JELLYFIN_DB_SNAPSHOT="$(mktemp "$BACKUP_DIR/database/.jellyfin-$DATE.XXXXXX.db")"
chmod 600 "$JELLYFIN_DB_SNAPSHOT" 2>/dev/null || true
log "Generando snapshot online consistente de Jellyfin SQLite..."
node --no-warnings - "$JELLYFIN_DB" "$JELLYFIN_DB_SNAPSHOT" <<'NODE'
const { DatabaseSync, backup } = require('node:sqlite');

const source = new DatabaseSync(process.argv[2], { readOnly: true });
backup(source, process.argv[3])
  .then(() => source.close())
  .catch((error) => {
    source.close();
    console.error(error);
    process.exit(1);
  });
NODE

node --no-warnings - "$JELLYFIN_DB_SNAPSHOT" <<'NODE'
const { DatabaseSync } = require('node:sqlite');

const database = new DatabaseSync(process.argv[2], { readOnly: true });
const result = Object.values(database.prepare('PRAGMA quick_check').get())[0];
database.close();
if (result !== 'ok') {
  console.error(`PRAGMA quick_check failed: ${result}`);
  process.exit(1);
}
NODE

TMP_JELLYFIN_GZIP="$(mktemp "$BACKUP_DIR/database/.jellyfin-$DATE.XXXXXX.db.gz")"
gzip -c "$JELLYFIN_DB_SNAPSHOT" > "$TMP_JELLYFIN_GZIP"
gzip -t "$TMP_JELLYFIN_GZIP" || die "el backup SQLite de Jellyfin no supera gzip -t"
mv -- "$TMP_JELLYFIN_GZIP" "$JELLYFIN_DB_BACKUP"
TMP_JELLYFIN_GZIP=''
rm -f -- "$JELLYFIN_DB_SNAPSHOT"
JELLYFIN_DB_SNAPSHOT=''
log "Snapshot SQLite de Jellyfin verificado: $JELLYFIN_DB_BACKUP"

# ── Configs de servicios clave ──
CONFIG_DIRS=(
  "jellyfin:$PROJECT_DIR/services/jellyfin"
  "sonarr:$PROJECT_DIR/services/sonarr"
  "radarr:$PROJECT_DIR/services/radarr"
  "bazarr:$PROJECT_DIR/services/bazarr"
  "prowlarr:$PROJECT_DIR/services/prowlarr"
  "qbittorrent:$PROJECT_DIR/services/qbittorrent"
  "jellyseerr:$PROJECT_DIR/services/jellyseerr"
  "tdarr:$PROJECT_DIR/services/tdarr"
  "uptime-kuma:$PROJECT_DIR/services/uptime-kuma"
)

for pair in "${CONFIG_DIRS[@]}"; do
  name="${pair%%:*}"
  src="${pair##*:}"
  if [ -d "$src" ]; then
    log "Backupeando configuracion: $name"
    archive="$BACKUP_DIR/configs/${name}-$DATE.tar.gz"
    log "Destino: $archive"
    if [[ "$name" == 'jellyfin' ]]; then
      tar czf "$archive" \
        --exclude='jellyfin/config/data/data/jellyfin.db' \
        --exclude='jellyfin/config/data/data/jellyfin.db-shm' \
        --exclude='jellyfin/config/data/data/jellyfin.db-wal' \
        -C "$(dirname "$src")" "$(basename "$src")"
    else
      tar czf "$archive" -C "$(dirname "$src")" "$(basename "$src")"
    fi
  else
    die "falta el directorio obligatorio de $name: $src"
  fi
done

# ── Limpiar backups viejos ──
log "Limpiando backups con mas de $RETENTION_DAYS dias..."
find "$BACKUP_DIR" -type f -name "*.gz" -mtime "+$RETENTION_DAYS" -delete

log "Backup completado: $BACKUP_DIR"
