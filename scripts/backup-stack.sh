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
MIRROR_DIR="${STACK_BACKUP_MIRROR_DIR:-/mnt/media1/backups/stack}"
NOTIFY_URL="${BACKUP_NOTIFY_URL:-http://127.0.0.1:3555/notify/system-update}"
NOTIFY_ENABLED="${BACKUP_NOTIFY_ENABLED:-1}"
NOTIFY_ON_SUCCESS="${BACKUP_NOTIFY_SUCCESS:-1}"
BOT_ENV_FILE="${BACKUP_BOT_ENV_FILE:-$PROJECT_DIR/jellyfin-whatsapp-bot/.env}"
TMP_DUMP=''
JELLYFIN_DB_SNAPSHOT=''
TMP_JELLYFIN_GZIP=''

umask 077

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

notify_token() {
  if [[ -n "${BACKUP_NOTIFY_TOKEN:-}" ]]; then
    printf '%s' "$BACKUP_NOTIFY_TOKEN"
    return 0
  fi
  [[ -f "$BOT_ENV_FILE" ]] || return 1
  sed -n 's/^WHATSAPP_UPDATE_NOTIFY_TOKEN=//p' "$BOT_ENV_FILE" | head -n 1
}

notify_whatsapp() {
  local message="$1"
  local token=''

  [[ "$NOTIFY_ENABLED" == '1' && "$DRY_RUN" == '0' ]] || return 0
  token="$(notify_token 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    log "WARN: notificacion WhatsApp omitida (sin token en $BOT_ENV_FILE)"
    return 0
  fi
  curl -fsS --connect-timeout 5 --max-time 15 -X POST "$NOTIFY_URL" \
    -H "x-update-token: $token" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg message "$message" '{message: $message}')" >/dev/null 2>&1 \
    || log "WARN: no se pudo enviar la notificacion WhatsApp"
}

die() {
  log "ERROR: $*"
  notify_whatsapp "❌ Backup del stack FALLO: $*"
  exit 1
}

on_error() {
  local line="$1"
  log "ERROR inesperado en linea $line"
  notify_whatsapp "❌ Backup del stack FALLO inesperadamente (linea $line). Revisar logs."
}

trap 'on_error "$LINENO"' ERR

cleanup() {
  if [[ -n "$TMP_DUMP" && -f "$TMP_DUMP" ]]; then
    rm -f -- "$TMP_DUMP"
  fi
  # El snapshot de Jellyfin se crea dentro de BACKUP_DIR/database, y SQLite
  # escribe a su lado los sidecars -wal y -shm. cleanup solo borra el .db, asi
  # que los otros dos quedaban huerfanos en el directorio de backups, uno de
  # cada por corrida, y la retencion (*.gz -mtime +N) no los toca porque no son
  # .gz. Se borran por ruta exacta del snapshot, nunca por glob: los backups
  # publicados (jellyfin-*.db.gz) quedan intactos.
  if [[ -n "$JELLYFIN_DB_SNAPSHOT" ]]; then
    rm -f -- \
      "$JELLYFIN_DB_SNAPSHOT" \
      "$JELLYFIN_DB_SNAPSHOT-wal" \
      "$JELLYFIN_DB_SNAPSHOT-shm" \
      "$JELLYFIN_DB_SNAPSHOT-journal"
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
rm -f -- \
  "$JELLYFIN_DB_SNAPSHOT" \
  "$JELLYFIN_DB_SNAPSHOT-wal" \
  "$JELLYFIN_DB_SNAPSHOT-shm" \
  "$JELLYFIN_DB_SNAPSHOT-journal"
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
  "homepage:$PROJECT_DIR/services/homepage"
  "qbitmanage:$PROJECT_DIR/services/qbitmanage"
  "recyclarr:$PROJECT_DIR/services/recyclarr"
    "scrutiny:$PROJECT_DIR/services/scrutiny"
    "adguard:$PROJECT_DIR/services/adguard"
    "subgen:$PROJECT_DIR/services/subgen"
    "bot-auth:$PROJECT_DIR/jellyfin-whatsapp-bot/auth"
  )

tar_archive() {
  # tar de config viva: los -wal/-shm cambian constantemente; se excluyen y
  # se tolera exit 1 (warning "file changed"), no exit 2 (fatal).
  local archive="$1"
  shift
  local rc=0
  # --ignore-failed-read evita que UN archivo ilegible (AdGuardHome.yaml es
  # root:root 600) tumbe el backup entero. Pero con ese flag tar no dice NADA:
  # exit 0 y silencio. Por eso warn_unreadable va antes y deja el hueco escrito
  # en el log — un backup que pierde archivos no puede parecer exitoso.
  #
  # El exclude de models es específico al subgen: el tar se hace con
  # -C <dirname> <basename>, así que la raíz del archivo es "subgen" y el
  # patrón tiene que empezar por subgen/. Con */models/* excluía cualquier
  # carpeta llamada models en cualquier servicio respaldado.
    tar czf "$archive" \
      --exclude='*/config/*.db-wal' \
      --exclude='*/config/*.db-shm' \
      --exclude='*/influxdb/*' \
      --exclude='subgen/models/*' \
      --ignore-failed-read \
      --warning=no-file-changed \
      "$@" || rc=$?
  if [[ $rc -gt 1 ]]; then
    die "tar fallo con codigo $rc para $archive"
  elif [[ $rc -eq 1 ]]; then
    log "WARN: tar reporto cambios durante la lectura (codigo 1, tolerado)"
  fi
}

# Lista lo que el usuario actual no puede leer dentro de un dir de config.
# Con --ignore-failed-read esos archivos se saltan en silencio; esto los hace
# visibles. No es decorativo: sin esto, perder credenciales no deja rastro.
warn_unreadable() {
  local name="$1" src="$2" f
  local -a files=()
  # "|| true" NO es cosmetico. find sale con 1 cuando topa con un directorio
  # sin permiso (services/scrutiny/influxdb), y eso dispara el trap ERR — que
  # se hereda al subshell de <(...) y escribe a su fd 1, que es la FIFO que
  # estamos leyendo. El mensaje de error entraba en el array como si fuera un
  # nombre de archivo. Con find dentro de una lista || no hay trap.
  mapfile -t files < <(find "$src" -type f \! -readable 2>/dev/null || true)
  [[ "${#files[@]}" -gt 0 ]] || return 0
  log "WARN: $name — archivos NO respaldados por permisos:"
  for f in "${files[@]}"; do
    [[ -n "$f" ]] || continue
    log "        - ${f#"$PROJECT_DIR"/} (legible solo por root; requiere chown o backup con sudo)"
  done
  log "WARN: $name — el backup terminó bien pero esos archivos NO están en el tar"
  return 0
}

for pair in "${CONFIG_DIRS[@]}"; do
  name="${pair%%:*}"
  src="${pair##*:}"
    if [ -d "$src" ]; then
      log "Backupeando configuracion: $name"
      archive="$BACKUP_DIR/configs/${name}-$DATE.tar.gz"
      log "Destino: $archive"
      warn_unreadable "$name" "$src"
      if [[ "$name" == 'jellyfin' ]]; then
      # La DB va aparte: se saca con snapshot consistente de node:sqlite y se
      # comprueba con quick_check antes de publicarla (ver dump_sqlite_db).
      # Los sidecars -wal/-shm los crea el proceso vivo, no el snapshot.
      #
      # Rutas derivadas: se regeneran solas en el primer arranque, verificado
      # con un restore desechable. 1907 MB de los 1935 MB del tar.
      # NO se excluyen: config/ (XML, database.xml, branding…), data/root
      # (usuarios, Películas, Series) ni la DB, que va en database/.
      tar_archive "$archive" \
        --exclude='jellyfin/config/data/data/jellyfin.db' \
        --exclude='jellyfin/config/data/data/jellyfin.db-shm' \
        --exclude='jellyfin/config/data/data/jellyfin.db-wal' \
        --exclude='jellyfin/config/data/data/trickplay' \
        --exclude='jellyfin/config/data/data/subtitles' \
        --exclude='jellyfin/config/data/metadata' \
        --exclude='jellyfin/config/cache' \
        --exclude='jellyfin/config/log' \
        -C "$(dirname "$src")" "$(basename "$src")"
    else
      tar_archive "$archive" -C "$(dirname "$src")" "$(basename "$src")"
    fi
  else
    die "falta el directorio obligatorio de $name: $src"
  fi
done

# ── Limpiar backups viejos ──
log "Limpiando backups con mas de $RETENTION_DAYS dias..."
find "$BACKUP_DIR" -type f -name "*.gz" -mtime "+$RETENTION_DAYS" -delete

# ── Copia espejo a segundo disco (media1, rama independiente del mergerfs) ──
MIRROR_OK='0'
if command -v rsync >/dev/null 2>&1 && mkdir -p "$MIRROR_DIR" 2>/dev/null && [[ -w "$MIRROR_DIR" ]]; then
  log "Sincronizando copia espejo a $MIRROR_DIR ..."
  if rsync -a --delete "$BACKUP_DIR/" "$MIRROR_DIR/"; then
    MIRROR_OK='1'
    log "Copia espejo OK en disco independiente: $MIRROR_DIR"
  else
    log "WARN: fallo rsync de la copia espejo"
    notify_whatsapp "⚠️ Backup creado pero FALLO la copia espejo a media1. Revisar."
  fi
else
  log "WARN: copia espejo omitida (sin rsync o $MIRROR_DIR no disponible)"
  notify_whatsapp "⚠️ Backup creado pero copia espejo OMITIDA ($MIRROR_DIR no disponible)."
fi

TOTAL_FILES="$(find "$BACKUP_DIR" -type f -name '*.gz' | wc -l | tr -d '[:space:]')"
TOTAL_SIZE="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || true)"
log "Backup completado: $BACKUP_DIR ($TOTAL_FILES archivos .gz, $TOTAL_SIZE)"
if [[ "$NOTIFY_ON_SUCCESS" == '1' ]]; then
  notify_whatsapp "✅ Backup del stack OK: $TOTAL_FILES archivos ($TOTAL_SIZE). Espejo media1: $([[ $MIRROR_OK == 1 ]] && echo OK || echo FALLO)."
fi
