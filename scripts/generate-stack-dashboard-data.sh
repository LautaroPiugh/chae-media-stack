#!/usr/bin/env bash
MEDIA_SERVER_IP="${MEDIA_SERVER_IP:-192.168.1.100}"
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/stack-dashboard"
OUTPUT_FILE="$CACHE_DIR/stack-data.json"
TMP_FILE="$CACHE_DIR/stack-data.json.tmp"
STATE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/media-stack-update.state"

mkdir -p "$CACHE_DIR"
chmod 755 "$CACHE_DIR"

read_state_value() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS='=' read -r current_key current_value; do
    if [[ "$current_key" == "$key" ]]; then
      printf '%s' "$current_value"
      return 0
    fi
  done < "$STATE_FILE"
}

container_json() {
  local name="$1"
  if docker inspect "$name" >/dev/null 2>&1; then
    docker inspect "$name" --format '{{json .State}}'
  else
    printf '%s' '{"Status":"missing","Running":false}'
  fi
}

http_check() {
  local url="$1"
  local check_url
  local -a curl_args=(-s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4)
  [[ -z "$url" ]] && { echo 'false'; return 0; }
  local code
  check_url="$(sed -E 's#(https?://)[^/:]+#\1127.0.0.1#' <<<"$url")"
  [[ "$check_url" == https://* ]] && curl_args+=(--insecure)
  code="$(curl "${curl_args[@]}" "$check_url" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]+$ ]] && [[ "$code" -ge 200 && "$code" -lt 500 ]] && { echo 'true'; return 0; }
  echo 'false'
}

service_json() {
  local name="$1"
  local container="$2"
  local url="$3"
  local port_label="$4"
  local description="$5"
  local category="$6"
  local state_json
  local status
  local health
  local running
  local label
  local http_ok

  state_json="$(container_json "$container")"
  status="$(jq -r '.Status // "missing"' <<<"$state_json")"
  health="$(jq -r '.Health.Status // "none"' <<<"$state_json")"
  running="$(jq -r '.Running // false' <<<"$state_json")"
  http_ok="$(http_check "$url")"

  label="$status"
  if [[ "$health" != "none" && "$health" != "null" ]]; then
    label="$label / $health"
  fi

  jq -nc \
    --arg name "$name" \
    --arg container "$container" \
    --arg url "$url" \
    --arg portLabel "$port_label" \
    --arg description "$description" \
    --arg category "$category" \
    --arg status "$status" \
    --arg health "$health" \
    --arg statusLabel "$label" \
    --argjson up "$running" \
    --argjson httpOk "$http_ok" \
    '{name:$name,container:$container,url:$url,portLabel:$portLabel,description:$description,category:$category,status:$status,health:$health,statusLabel:$statusLabel,up:$up,httpOk:$httpOk}'
}

storage_json() {
  local label="$1"
  local path="$2"
  local lines line size used avail pcent target

  mapfile -t lines < <(df -B1 --output=size,used,avail,pcent,target "$path")
  line="${lines[1]}"
  read -r size used avail pcent target <<<"$line"
  pcent="${pcent%%%}"

  jq -nc \
    --arg label "$label" \
    --arg path "$path" \
    --arg mountPoint "$target" \
    --argjson sizeBytes "$size" \
    --argjson usedBytes "$used" \
    --argjson availableBytes "$avail" \
    --argjson usePercent "$pcent" \
    '{label:$label,path:$path,mountPoint:$mountPoint,sizeBytes:$sizeBytes,usedBytes:$usedBytes,availableBytes:$availableBytes,usePercent:$usePercent}'
}

memory_bytes() {
  local key="$1"
  local value_kb='0'

  value_kb="$(grep -m1 "^${key}:" /proc/meminfo | tr -s ' ' | cut -d' ' -f2)"
  printf '%s' "$(( value_kb * 1024 ))"
}

host_name="$(hostname)"
primary_ip="$(hostname -I | tr ' ' '\n' | jq -Rsc 'split("\n") | map(select(length>0)) | .[0] // "127.0.0.1"' | jq -r '.')"
timezone="$(date +%Z)"
generated_at="$(date --iso-8601=seconds)"
load_average="$(cut -d' ' -f1-3 /proc/loadavg)"
uptime_seconds="$(cut -d'.' -f1 /proc/uptime)"
memory_total_bytes="$(memory_bytes MemTotal)"
memory_available_bytes="$(memory_bytes MemAvailable)"
memory_used_bytes="$(( memory_total_bytes - memory_available_bytes ))"
os_name='Unknown Linux'

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  os_name="${PRETTY_NAME:-$os_name}"
fi

last_run="$(read_state_value last_run)"
last_status="$(read_state_value last_status)"
last_mode="$(read_state_value last_mode)"

if [[ -n "$last_run" ]]; then
  last_run_at="$(date -d "@$last_run" --iso-8601=seconds 2>/dev/null || true)"
else
  last_run_at=''
fi

case "$last_status" in
  ok) status_label='OK' ;;
  dry-run) status_label='Dry run' ;;
  failed) status_label='Fallo' ;;
  *) status_label='Sin registro' ;;
esac

services_json="$({
  service_json 'Jellyfin' 'chae-jellyfin' "http://${MEDIA_SERVER_IP}:8096" '8096' 'Streaming principal de peliculas, series y anime.' 'media'
  service_json 'Jellyseerr' 'chae-jellyseerr' "http://${MEDIA_SERVER_IP}:5055" '5055' 'Pedidos y autoservicio de contenido.' 'requests'
  service_json 'Sonarr' 'chae-sonarr' "http://${MEDIA_SERVER_IP}:8989" '8989' 'Automatizacion de series.' 'arr'
  service_json 'Radarr' 'chae-radarr' "http://${MEDIA_SERVER_IP}:7878" '7878' 'Automatizacion de peliculas.' 'arr'
  service_json 'Bazarr' 'chae-bazarr' "http://${MEDIA_SERVER_IP}:6767" '6767' 'Subtitulos automaticos para series y peliculas.' 'subtitles'
  service_json 'Tdarr' 'chae-tdarr' "http://${MEDIA_SERVER_IP}:8265" '8265/8266' 'Remux, limpieza de pistas y ahorro de espacio.' 'transcode'
  service_json 'Tdarr Node' 'chae-tdarr-node' '' 'interno' 'Worker de transcode conectado al server.' 'transcode'
  service_json 'Prowlarr' 'chae-prowlarr' "http://${MEDIA_SERVER_IP}:9696" '9696' 'Indexadores y trackers.' 'arr'
  service_json 'qBittorrent' 'chae-qbittorrent' "http://${MEDIA_SERVER_IP}:8080" '8080/6881' 'Cliente torrent principal.' 'download'
  service_json 'Uptime Kuma' 'chae-uptime-kuma' "http://${MEDIA_SERVER_IP}:3001" '3001' 'Monitoreo y health checks.' 'monitoring'
  service_json 'Flaresolverr' 'chae-flaresolverr' '' '8191' 'Bypass de Cloudflare para trackers.' 'support'
  service_json 'SubgenAI' 'subgenai' "http://${MEDIA_SERVER_IP}:9000" '9000' 'Generacion auxiliar de subtitulos y automatizaciones.' 'support'
  service_json 'WhatsApp Bot' 'jellyfin-whatsapp-bot' '' '3555' 'Bot y automatizacion alrededor de Jellyfin.' 'automation'
  service_json 'Postgres' 'chae-postgres' '' '5432' 'Base de datos interna del stack.' 'database'
  service_json 'Portainer' 'portainer' "https://${MEDIA_SERVER_IP}:9443" '9443' 'Administracion de Docker.' 'ops'
  service_json 'Maintainerr' 'chae-maintainerr' "http://${MEDIA_SERVER_IP}:8787" '8787' 'Limpieza automatica de contenido.' 'media'
  service_json 'Watchtower' 'watchtower' '' '' 'Deshabilitado; las actualizaciones se ejecutan bajo demanda con validacion y rollback.' 'ops'
} | jq -s '.')"

storage_json_all="$({
  storage_json 'Biblioteca principal' '/mnt/media'
  storage_json 'Descargas y cache' '/mnt/media2/downloads'
  storage_json 'Volumen secundario' '/mnt/media2'
} | jq -s '.')"

running_containers="$(docker ps -q | wc -l | tr -d ' ')"
total_containers="$(docker ps -aq | wc -l | tr -d ' ')"
services_up="$(jq '[ .[] | select(.up == true) ] | length' <<<"$services_json")"
services_total="$(jq 'length' <<<"$services_json")"
services_down="$(( services_total - services_up ))"
apps_up="$(jq '[ .[] | select((.url | length) > 0 and .up == true) ] | length' <<<"$services_json")"
apps_total="$(jq '[ .[] | select((.url | length) > 0) ] | length' <<<"$services_json")"
internal_total="$(jq '[ .[] | select((.url | length) == 0) ] | length' <<<"$services_json")"
internal_up="$(jq '[ .[] | select((.url | length) == 0 and .up == true) ] | length' <<<"$services_json")"
media_free_bytes="$(jq 'map(select(.path == "/mnt/media"))[0].availableBytes // 0' <<<"$storage_json_all")"
media_usage="$(jq -r 'map(select(.path == "/mnt/media"))[0].usePercent // 0 | tostring + "% usado"' <<<"$storage_json_all")"
tdarr_server_status="$(jq -r '.[] | select(.container == "chae-tdarr") | .status' <<<"$services_json")"
tdarr_node_status="$(jq -r '.[] | select(.container == "chae-tdarr-node") | .status' <<<"$services_json")"

jq -n \
  --arg generatedAt "$generated_at" \
  --arg hostName "$host_name" \
  --arg ip "$primary_ip" \
  --arg timezone "$timezone" \
  --arg osName "$os_name" \
  --arg loadAverage "$load_average" \
  --arg statusLabel "$status_label" \
  --arg lastRunAt "$last_run_at" \
  --arg lastMode "$last_mode" \
  --arg tdarrServerStatus "$tdarr_server_status" \
  --arg tdarrNodeStatus "$tdarr_node_status" \
  --argjson uptimeSeconds "$uptime_seconds" \
  --argjson memoryTotalBytes "$memory_total_bytes" \
  --argjson memoryUsedBytes "$memory_used_bytes" \
  --argjson memoryAvailableBytes "$memory_available_bytes" \
  --argjson runningContainers "$running_containers" \
  --argjson totalContainers "$total_containers" \
  --argjson servicesUp "$services_up" \
  --argjson servicesTotal "$services_total" \
  --argjson servicesDown "$services_down" \
  --argjson appsUp "$apps_up" \
  --argjson appsTotal "$apps_total" \
  --argjson internalUp "$internal_up" \
  --argjson internalTotal "$internal_total" \
  --argjson mediaFreeBytes "$media_free_bytes" \
  --arg mediaUsage "$media_usage" \
  --arg dashboardCommand "$SCRIPT_DIR/generate-stack-dashboard-data.sh" \
  --arg updateCommand "$SCRIPT_DIR/update-media-stack.sh media" \
  --argjson services "$services_json" \
  --argjson storage "$storage_json_all" \
  '{
    generatedAt:$generatedAt,
    host:{
      name:$hostName,
      ip:$ip,
      timezone:$timezone,
      os:$osName,
      loadAverage:$loadAverage,
      uptimeSeconds:$uptimeSeconds,
      memoryTotalBytes:$memoryTotalBytes,
      memoryUsedBytes:$memoryUsedBytes,
      memoryAvailableBytes:$memoryAvailableBytes
    },
    updateState:{statusLabel:$statusLabel,lastRunAt:$lastRunAt,mode:$lastMode},
    summary:{
      runningContainers:$runningContainers,
      totalContainers:$totalContainers,
      servicesUp:$servicesUp,
      servicesTotal:$servicesTotal,
      servicesDown:$servicesDown,
      appsUp:$appsUp,
      appsTotal:$appsTotal,
      internalUp:$internalUp,
      internalTotal:$internalTotal,
      mediaFreeBytes:$mediaFreeBytes,
      mediaUsage:$mediaUsage
    },
    services:$services,
    storage:$storage,
    tdarr:{
      url:"http://${MEDIA_SERVER_IP}:8265",
      ready:(($tdarrServerStatus == "running") and ($tdarrNodeStatus == "running")),
      serverStatus:$tdarrServerStatus,
      nodeStatus:$tdarrNodeStatus,
      cachePath:"/mnt/media2/downloads/tdarr-cache",
      gpuMode:"VAAPI / Intel / /dev/dri",
      libraries:[
        {name:"Peliculas",path:"/media/movies"},
        {name:"Series",path:"/media/series"},
        {name:"Anime",path:"/media/anime"}
      ],
      workflow:[
        {title:"Crear libreria en Tdarr",detail:"Arranca con /media/movies y /media/series por separado para testear sin mezclar reglas."},
        {title:"Usar Basic HEVC Video Flow",detail:"Es la base mas segura para convertir video a HEVC sin tocar archivos que ya son HEVC."},
        {title:"Agregar limpieza de subtitulos",detail:"Usa Migz Clean Subtitle Streams para conservar eng,spa o spa,eng segun tu politica y etiquetar und."},
        {title:"Quitar codecs conflictivos",detail:"Usa MichPass Remove Subtitle And Audio Streams With Certain Codecs para sacar hdmv_pgs_subtitle,dvd_subtitle o truehd si molestan."},
        {title:"Probar con pocos archivos",detail:"Procesa 2 o 3 remux pesados primero y valida reproduccion en Jellyfin antes de escalar."}
      ],
      notes:[
        "Bazarr sigue siendo el servicio principal para descargar subtitulos.",
        "Tdarr ayuda a limpiar pistas embebidas, remuxear y reducir espacio.",
        "El nodo ya detecto hevc_vaapi en las pruebas de arranque."
      ]
    },
    commands:[
      {label:"Regenerar datos del dashboard",command:$dashboardCommand,description:"Actualiza el JSON cacheado que consume la portada."},
      {label:"Ver Tdarr en vivo",command:"docker logs -f chae-tdarr-node",description:"Seguimiento del worker de transcode."},
      {label:"Ver contenedores",command:"docker ps --format \"table {{.Names}}\\t{{.Status}}\\t{{.Ports}}\"",description:"Vista rapida del stack."},
      {label:"Espacio de biblioteca",command:"df -h /mnt/media /mnt/media2/downloads",description:"Confirma espacio libre para media y cache de Tdarr."},
      {label:"Previsualizar actualizaciones",command:$updateCommand,description:"Valida la allowlist del stack sin aplicar cambios."}
    ]
  }' > "$TMP_FILE"

mv "$TMP_FILE" "$OUTPUT_FILE"
chmod 644 "$OUTPUT_FILE"
