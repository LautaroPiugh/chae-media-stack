#!/usr/bin/env bash
set -Eeuo pipefail

# Cargar configuración local (MEDIA_SERVER_IP, etc.)
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$DIR/.env" ]; then set -a; . "$DIR/.env"; set +a; fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SERVICES=(
  "Postgres:chae-postgres:tcp:5432"
  "Prowlarr:chae-prowlarr:http:9696"
  "Radarr:chae-radarr:http:7878"
  "Sonarr:chae-sonarr:http:8989"
  "qBittorrent:chae-qbittorrent:http:8080"
  "Bazarr:chae-bazarr:http:6767"
  "Jellyfin:chae-jellyfin:http:8096"
  "Jellyseerr:chae-jellyseerr:http:5055"
  "Flaresolverr:chae-flaresolverr:http:8191"
  "SubgenAI:subgenai:http:9000"
  "Tdarr:chae-tdarr:http:8265"
  "Tdarr Node:chae-tdarr-node:docker-tcp:chae-tdarr,8266"
  "Uptime Kuma:chae-uptime-kuma:http:3001"
  "Homepage:chae-homepage:http:3003"
  "WhatsApp Bot:jellyfin-whatsapp-bot:http:3555:/health"
  "AdGuard:chae-adguard:http:3002"
  "Maintainerr:chae-maintainerr:http:8787"
  "Dozzle:chae-dozzle:http:8081"
  "Scrutiny:chae-scrutiny:http:8082"
  "Portainer:portainer:https:9443"
)

header() {
  printf "\n${CYAN}═══ %s ═══${NC}\n" "$1"
}

check_container() {
  local name="$1"
  if docker ps --format '{{.Names}}' | grep -qx "$name"; then
    return 0
  fi
  return 1
}

check_http() {
  local port="$1"
  local protocol="${2:-http}"
  local path="${3:-/}"
  local -a curl_args=(-s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10)
  local attempt
  local code

  if [[ "$protocol" == 'https' ]]; then
    curl_args+=(--insecure)
  fi
  for attempt in 1 2; do
    code="$(curl "${curl_args[@]}" "${protocol}://127.0.0.1:${port}${path}" 2>/dev/null || true)"
    if [[ "$code" =~ ^[0-9]+$ ]] && [[ "$code" -ge 200 && "$code" -lt 400 ]]; then
      return 0
    fi
    [[ "$attempt" -eq 2 ]] || sleep 1
  done
  return 1
}

check_tcp() {
  local port="$1"
  timeout 2 bash -c "echo > /dev/tcp/localhost/$port" 2>/dev/null && return 0
  return 1
}

check_docker_tcp() {
  local container="$1"
  local host="$2"
  local port="$3"

  docker exec "$container" node -e '
    const net = require("net");
    const socket = net.connect(Number(process.argv[2]), process.argv[1]);
    socket.setTimeout(3000);
    socket.once("connect", () => socket.end());
    socket.once("close", hadError => process.exit(hadError ? 1 : 0));
    socket.once("timeout", () => socket.destroy(new Error("timeout")));
    socket.once("error", () => process.exit(1));
  ' "$host" "$port" >/dev/null 2>&1
}

total=0
up=0
down=0

header "Resumen del Sistema"
printf "Host:     %s\n" "$(hostname)"
printf "Kernel:   %s\n" "$(uname -r)"
printf "Uptime:   %s\n" "$(uptime -p | sed 's/up //')"
printf "Docker:   %s\n\n" "$(docker --version | cut -d' ' -f3 | tr -d ',')"

header "Estado de Servicios"

for service in "${SERVICES[@]}"; do
  IFS=':' read -r label container type port path <<<"$service"
  total=$((total + 1))

  if ! check_container "$container"; then
    printf "  ${RED}✘${NC} %-20s %-25s ${RED}%s${NC}\n" "$label" "($container)" "CONTAINER DOWN"
    down=$((down + 1))
    continue
  fi

  case "$type" in
    http)
      if check_http "$port" 'http' "${path:-/}"; then
        printf "  ${GREEN}✔${NC} %-20s %-25s ${GREEN}%s${NC}\n" "$label" "($container)" "HTTP $port OK"
        up=$((up + 1))
      else
        printf "  ${RED}✘${NC} %-20s %-25s ${RED}%s${NC}\n" "$label" "($container)" "HTTP $port no responde"
        down=$((down + 1))
      fi
      ;;
    https)
      if check_http "$port" "https"; then
        printf "  ${GREEN}✔${NC} %-20s %-25s ${GREEN}%s${NC}\n" "$label" "($container)" "HTTPS $port OK"
        up=$((up + 1))
      else
        printf "  ${RED}✘${NC} %-20s %-25s ${RED}%s${NC}\n" "$label" "($container)" "HTTPS $port no responde"
        down=$((down + 1))
      fi
      ;;
    tcp)
      if check_tcp "$port"; then
        printf "  ${GREEN}✔${NC} %-20s %-25s ${GREEN}%s${NC}\n" "$label" "($container)" "Puerto $port abierto"
        up=$((up + 1))
      else
        printf "  ${RED}✘${NC} %-20s %-25s ${RED}%s${NC}\n" "$label" "($container)" "Puerto $port cerrado"
        down=$((down + 1))
      fi
      ;;
    docker-tcp)
      target_host="${port%,*}"
      target_port="${port##*,}"
      if check_docker_tcp "$container" "$target_host" "$target_port"; then
        printf "  ${GREEN}✔${NC} %-20s %-25s ${GREEN}%s${NC}\n" "$label" "($container)" "Docker $target_host:$target_port OK"
        up=$((up + 1))
      else
        printf "  ${RED}✘${NC} %-20s %-25s ${RED}%s${NC}\n" "$label" "($container)" "Docker $target_host:$target_port no responde"
        down=$((down + 1))
      fi
      ;;
  esac
done

header "Almacenamiento"
for mount in /mnt/media /mnt/media2; do
  total=$((total + 1))
  if mountpoint -q "$mount" 2>/dev/null; then
    usage="$(df -h "$mount" | awk 'NR==2 {print $5}')"
    avail="$(df -h "$mount" | awk 'NR==2 {print $4}')"
    printf "  ${GREEN}✔${NC} %-20s %s usado, %s libres\n" "$mount" "$usage" "$avail"
    up=$((up + 1))
  else
    printf "  ${RED}✘${NC} %-20s ${RED}NO MONTADO${NC}\n" "$mount"
    down=$((down + 1))
  fi
done

printf "\n"
if [ "$down" -gt 0 ]; then
  printf "  ${RED}%d/%d servicios con problemas${NC}\n" "$down" "$total"
  exit 1
else
  printf "  ${GREEN}%d/%d servicios funcionando${NC}\n" "$up" "$total"
  exit 0
fi
