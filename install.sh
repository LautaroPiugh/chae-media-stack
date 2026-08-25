#!/usr/bin/env bash
# ============================================================================
#  ┌─────────────────────────────────────────────────────────────────────┐
#  │   C H A E   M E D I A   S T A C K  ·  instalador oficial            │
#  │   Tema: Kim Chaewon × LE SSERAFIM  ·  FEARLESS BLUE                 │
#  └─────────────────────────────────────────────────────────────────────┘
#  Uso:
#    ./install.sh                  wizard interactivo
#    ./install.sh --yes            acepta todos los defaults
#    ./install.sh --dry-run        muestra el plan sin ejecutar nada
#    ./install.sh --update         git pull + recrea contenedores
#    ./install.sh --uninstall      baja los contenedores (conserva datos)
# ============================================================================
set -Eeuo pipefail

# ══════════════════════════ TEMA CHAEWON ══════════════════════════
if [ -t 1 ]; then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  FB=$'\e[38;2;91;157;217m'     # FEARLESS BLUE  (Pantone 7453C)
  FB2=$'\e[38;2;140;190;235m'   # Fearless Blue claro
  SLV=$'\e[38;2;201;209;220m'   # plata (color de Chaewon)
  WHT=$'\e[97m'; GRN=$'\e[92m'; RED=$'\e[91m'; YLW=$'\e[93m'
  DIMF=$'\e[38;2;110;125;150m'
  BG_FB=$'\e[48;2;23;37;58m'
else R=""; B=""; DIM=""; FB=""; FB2=""; SLV=""; WHT=""; GRN=""; RED=""; YLW=""; DIMF=""; BG_FB=""; fi

TIGER="🐯"

ART=(
"${FB}      ▄▄▄· • ▌ ▄ ·· ▄ .▄▄▄▄ .▄▄▄   ▄▄· ▄ .▄    ▪   ▄▄· ▄ ▄▄    ▄▄▄ "
"${FB}     ▐█ ▀█ ·██ ▐███▪██▐▀▀▪▀▄.▀▀▐█ ▀ ██▪▐█    ██ ▐█ ▌▪█▌▒█▄▄▒▀▄ ▀▄"
"${SLV}     ▄█▀▀█ ▐█ ▌▐▌▐█· ▄█▀▄▐▀▀▪▐▀▀▪▄█▀▀█▐█▐▐▌   ▐█·██ ▄▄▐█▌▒█▄▄▒█▄▄▄█"
"${SLV}     ▐█ ▪▐▌██ ██▌▐█▌▐█▌▐▌▐█▄▄▌▐█▄▄▌▐█ ▪▐▐█▐█▌  ▐█▌▐███▌██ ▒ ▒ ▒▓▒ ▒ "
"${FB}      ▀  ▀ ▀▀  █▪▀▀▀ ▀▀▀  ▀▀▀  ▀▀▀  ▀  ▀ ▀▀ █▪ ▀▀▀·▀▀▀ ▀▀  ▒ ▒░▒ ▒▒"
)
SUB="${DIM}${SLV}── media stack instalador ${FB}· ${WHT}🐯 baby cheetah edition ${FB}· ${SLV}FEARNOT${R}"

SONGS=(
  "♪ ANTIFRAGILE — antifragile antifragile"
  "♪ UNFORGIVEN — we break these chains"
  "♪ Smart — apuesta por mí"
  "♪ EASY — suave, suave"
  "♪ Hot — más caliente que el resto"
  "♪ Perfect Night — under the starlight"
  "♪ Blue Flame — arde sin miedo"
  "♪ Swan Song — canto antes del final"
  "♪ The Great Mermaid — mar abierto"
  "♪ FEARNOT — florecer sin miedo"
)

MODE="wizard"; ASSUME_YES=0; DRY_RUN=0
for arg in "$@"; do case "$arg" in
  --yes|-y) ASSUME_YES=1;;
  --dry-run|-n) DRY_RUN=1; ASSUME_YES=1;;
  --update|-u) MODE="update";;
  --uninstall) MODE="uninstall";;
esac; done

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

# ══════════════════════════ HELPERS VISUALES ══════════════════════════
STEP_TOTAL=8; STEP_NOW=0; SONG_IDX=0
is_tty() { [ -t 1 ]; }

footer() {
  is_tty || return 0
  local cols lines
  cols=$(tput cols); lines=$(tput lines)
  tput sc
  tput cup $((lines-1)) 0
  tput el
  SONG_IDX=$(( (SONG_IDX+1) % ${#SONGS[@]} ))
  printf "${BG_FB}${DIMF} %s${FB}%s ${DIMF}| paso %s/%s | 🐯 FEARNOT %s" \
    "${SONGS[$SONG_IDX]%—*}" "${SONGS[$SONG_IDX]#*— }" "$STEP_NOW" "$STEP_TOTAL" "${R}"
  tput rc
}

header() {
  clear 2>/dev/null || true
  echo; for l in "${ART[@]}"; do echo "  $l"; done
  echo "  $SUB"
  echo
}

step() {
  STEP_NOW=$((STEP_NOW+1))
  echo
  echo "${FB}┏━━${R} ${B}${WHT}$1${R}"
  echo "${FB}┃${R}"
}
sub()  { echo "${FB}┃${R}  ${SLV}·${R} $1"; }
ok()   { echo "${FB}┃${R}  ${GRN}✔${R} $1"; }
warn() { echo "${FB}┃${R}  ${YLW}▲${R} $1"; }
failx(){ echo "${FB}┃${R}  ${RED}✘ $1${R}"; }
endstep() { echo "${FB}┗━━${R}"; footer; }

ask() { # ask "pregunta" "default" -> respuesta en REPLY
  local q="$1" def="${2:-}"
  if [ "$ASSUME_YES" = 1 ] || ! is_tty; then REPLY="$def"; return 0; fi
  read -rp "$(printf "${FB}┃${R}  ${B}%s${R} ${DIMF}[%s]${R}: " "$q" "$def")" REPLY </dev/tty
  REPLY="${REPLY:-$def}"
}

spinner() { # spinner <pid> "texto"
  local pid="$1" txt="$2" spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧') i=0
  is_tty || { wait "$pid" 2>/dev/null || true; return; }
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${FB}┃${R}  ${FB}%s${R} %s" "${spin[i%8]}" "$txt"
    i=$((i+1)); sleep 0.12
  done
  printf "\r\033[K"
}

gen_token() { openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

run() { # ejecuta respetando dry-run
  if [ "$DRY_RUN" = 1 ]; then echo "${FB}┃${R}  ${DIM}[dry-run]$*${R}"; return 0; fi
  "$@"
}

# ══════════════════════════ UNINSTALL ══════════════════════════
if [ "$MODE" = "uninstall" ]; then
  header; step "Desinstalar (los datos en cada services/*/config se conservan)"
  for d in services/*/docker-compose.yml jellyfin-whatsapp-bot/docker-compose.yml; do
    dir=$(dirname "$d")
    args=(-f "$d"); [ -f "$dir/docker-compose.override.yml" ] && args+=(-f "$dir/docker-compose.override.yml")
    sub "down $(basename "$dir")"
    run docker compose "${args[@]}" down
  done
  ok "Stack detenido. Para borrar también datos: rm -rf services/*/config (¡cuidado!)"
  endstep; exit 0
fi

# ══════════════════════════ UPDATE ══════════════════════════
if [ "$MODE" = "update" ]; then
  header; step "Actualizar stack"
  sub "git pull"
  run git pull --ff-only
  ok "ejecutá de nuevo ./install.sh para recrear contenedores con la nueva config"
  endstep; exit 0
fi

# ══════════════════════════ 1 · PREFLIGHT ══════════════════════════
header
step "1/${STEP_TOTAL} · Preflight — chequeos del sistema"

MISSING=()
for cmd in git docker curl awk sed; do
  command -v "$cmd" >/dev/null 2>&1 && ok "comando $cmd" || { failx "falta $cmd"; MISSING+=("$cmd"); }
done
if docker compose version >/dev/null 2>&1; then ok "docker compose v2 ($(docker compose version --short 2>/dev/null))";
else failx "docker compose v2 no disponible"; MISSING+=("compose"); fi
[ ${#MISSING[@]} -gt 0 ] && { echo; failx "Instalá lo que falta y volvé a correr."; endstep; exit 1; }

DISK_FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
ok "disco libre en /: ${DISK_FREE_GB}G"
[ "$DISK_FREE_GB" -lt 10 ] && warn "menos de 10G libres — puede quedarse corto para imágenes"

if curl -sf --max-time 8 https://github.com >/dev/null 2>&1; then ok "conectividad a internet"
else warn "sin salida a internet — los pulls van a fallar"; fi

AUTO_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
AUTO_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "Etc/UTC")
ok "IP autodetectada: ${AUTO_IP:-?} · TZ: $AUTO_TZ"
endstep

# ══════════════════════════ 2 · PREGUNTAS ══════════════════════════
step "2/${STEP_TOTAL} · Tu configuración"

ask "IP LAN del server" "${AUTO_IP:-192.168.1.100}";          MEDIA_SERVER_IP="$REPLY"
ask "Zona horaria" "$AUTO_TZ";                                CFG_TZ="$REPLY"
ask "Carpeta de biblioteca (MEDIA_ROOT)" "/opt/media";        MEDIA_ROOT="${REPLY%/}"
ask "Carpeta de descargas (DOWNLOADS_ROOT)" "/opt/downloads"; DOWNLOADS_ROOT="${REPLY%/}"
ask "PUID (dueño de archivos)" "1000";                        PUID="$REPLY"
ask "PGID" "1000";                                            PGID="$REPLY"

echo "${FB}┃${R}"
echo "${FB}┃${R}  ${B}Resumen:${R}"
echo "${FB}┃${R}    IP: ${WHT}$MEDIA_SERVER_IP${R}  · TZ: $CFG_TZ · PUID:PGID $PUID:$PGID"
echo "${FB}┃${R}    Media: $MEDIA_ROOT  · Descargas: $DOWNLOADS_ROOT"
if [ "$ASSUME_YES" != 1 ] && is_tty; then
  read -rp "$(printf "${FB}┃${R}  ¿Confirmás? [Y/n]: ")" CONF </dev/tty
  case "$CONF" in n*|N*) echo "${RED}Cancelado.${R}"; exit 1;; esac
fi
endstep

# ══════════════════════════ 3 · ESCRIBIR CONFIG ══════════════════════════
step "3/${STEP_TOTAL} · Generar configuración (.env + symlinks)"

if [ -f .env ] && [ "$DRY_RUN" != 1 ]; then
  cp .env ".env.backup-$(date +%Y%m%d-%H%M%S)"
  warn ".env previo respaldado como .env.backup-*"
fi

ENV_CONTENT=$(cat << EOF
# Generado por install.sh — Kim Chaewon approves 🐯
MEDIA_SERVER_IP=${MEDIA_SERVER_IP}
MEDIA_ROOT=${MEDIA_ROOT}
DOWNLOADS_ROOT=${DOWNLOADS_ROOT}
TZ=${CFG_TZ}
PUID=${PUID}
PGID=${PGID}

# Contraseñas de apps (el instalador las genera; cambialas desde cada web si querés)
QBITTORRENT_PASSWORD=$(gen_token)
ADGUARD_USERNAME=admin
ADGUARD_PASSWORD=$(gen_token)
EOF
)

if [ "$DRY_RUN" = 1 ]; then
  echo "${FB}┃${R}  ${DIM}[dry-run] escribiría .env:${R}"
  echo "$ENV_CONTENT" | sed "s/PASSWORD=.*/PASSWORD=<generado>/" | sed "s/^/${FB}┃${R}  /"
else
  echo "$ENV_CONTENT" > .env
  chmod 600 .env
  set -a; . ./.env; set +a
  for d in services/*/; do
    [ -f "$d/docker-compose.yml" ] || continue
    ln -sfn "../../.env" "$d/.env"
  done
  ok ".env escrito + symlinks services/*/.env creados"
fi
if [ "$DRY_RUN" = 1 ]; then
  echo "${FB}┃${R}  ${DIM}[dry-run] crearía $MEDIA_ROOT y $DOWNLOADS_ROOT${R}"
else
  mkdir -p "$MEDIA_ROOT" "$DOWNLOADS_ROOT" 2>/dev/null || warn "no pude crear $MEDIA_ROOT o $DOWNLOADS_ROOT (¿permisos?)"
fi
endstep

# ══════════════════════════ 4 · COMPONENTES ══════════════════════════
step "4/${STEP_TOTAL} · ¿Qué instalamos?"

SELECTED=(postgres prowlarr radarr sonarr qbittorrent bazarr jellyfin homepage uptime-kuma maintainerr flaresolverr portainer)
ADVANCED=(tdarr subgen adguard whatsapp-bot)

if [ "$ASSUME_YES" = 1 ] || ! is_tty; then
  ok "seleccionados por defecto: ${SELECTED[*]}"
else
  echo "${FB}┃${R}  Enter = incluir · x = saltar"
  FINAL=()
  ALL=("${SELECTED[@]}" "${ADVANCED[@]}")
  for svc in "${ALL[@]}"; do
    default_in=1; [[ " ${ADVANCED[*]} " == *" $svc "* ]] && default_in=0
    [ "$default_in" = 1 ] && d="[Y/n]" || d="[y/N]"
    read -rp "$(printf "${FB}┃${R}  %-14s %s: " "$svc" "$d")" r </dev/tty
    r="${r:-}"
    if [ "$default_in" = 1 ]; then [[ ! "$r" =~ ^(n|N) ]] && FINAL+=("$svc");
    else [[ "$r" =~ ^(y|Y) ]] && FINAL+=("$svc"); fi
  done
  SELECTED=("${FINAL[@]}")
  echo "${FB}┃${R}  → ${WHT}${SELECTED[*]:-nada}${R}"
fi
[ ${#SELECTED[@]} -eq 0 ] && { warn "nada seleccionado, chau 🐯"; endstep; exit 0; }
endstep

# ══════════════════════════ 5 · DESPLEGAR ══════════════════════════
ORDER=(postgres qbittorrent prowlarr radarr sonarr bazarr jellyfin uptime-kuma adguard flaresolverr maintainerr subgen tdarr portainer homepage whatsapp-bot)
step "5/${STEP_TOTAL} · Desplegar contenedores"

FAILS=()
for svc in "${ORDER[@]}"; do
  skip=1; for s in "${SELECTED[@]}"; do [ "$s" = "$svc" ] && skip=0; done
  [ $skip = 1 ] && continue

  dir="services/$svc"; [ "$svc" = "whatsapp-bot" ] && dir="jellyfin-whatsapp-bot"
  yml="$dir/docker-compose.yml"
  [ -f "$yml" ] || { failx "$svc: sin $yml"; FAILS+=("$svc"); continue; }

  args=(-f "$yml")
  [ -f "$dir/docker-compose.override.yml" ] && args+=(-f "$dir/docker-compose.override.yml")

  if [ "$DRY_RUN" = 1 ]; then
    echo "${FB}┃${R}  ${DIM}[dry-run] docker compose ${args[*]} up -d${R}"
  else
    ( docker compose "${args[@]}" up -d ) >/tmp/chae-install-$svc.log 2>&1 &
    spid=$!
    spinner $spid "desplegando $svc..."
    wait $spid && ok "$svc desplegado" || { failx "$svc falló (log: /tmp/chae-install-$svc.log)"; FAILS+=("$svc"); }
  fi
done
endstep

# ══════════════════════════ 6 · SALUD ══════════════════════════
step "6/${STEP_TOTAL} · Esperar salud de los contenedores"
if [ "$DRY_RUN" = 1 ]; then
  echo "${FB}┃${R}  ${DIM}[dry-run] skip${R}"
else
  for svc in "${SELECTED[@]}"; do
    cname="chae-$svc"; [ "$svc" = "whatsapp-bot" ] && cname="jellyfin-whatsapp-bot"
    tries=0
    while [ $tries -lt 24 ]; do
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cname" 2>/dev/null || echo "missing")
      [ "$st" = "healthy" ] || [ "$st" = "running" ] && break
      tries=$((tries+1)); sleep 5
    done
    case "$st" in
      healthy|running) ok "$cname: $st";;
      *) warn "$cname: $st (podría estar inicializando; mirá docker logs $cname)";;
    esac
  done
fi
endstep

# ══════════════════════════ 7 · DASHBOARD ══════════════════════════
step "7/${STEP_TOTAL} · Dashboard (homepage temático)"
has_home=0; for s in "${SELECTED[@]}"; do [ "$s" = "homepage" ] && has_home=1; done
if [ $has_home = 0 ]; then
  sub "homepage no seleccionado — salteado"
elif [ -f services/homepage/config/settings.yaml ]; then
  ok "ya existe configuración de homepage — no la piso"
else
  mkdir -p services/homepage/config
  cat > services/homepage/config/settings.yaml << EOF
title: Chae Server 🐯
theme: dark
color: cyan
language: es
headerStyle: boxed
statusStyle: dot
layout:
  Media:
    style: column
  Automatización:
    style: column
  Monitoreo e Infraestructura:
    style: column
EOF
  cat > services/homepage/config/widgets.yaml << 'EOF'
- search:
    provider: duckduckgo
- datetime:
    text_size: xl
    format:
      dateStyle: full
      timeStyle: short
      hourCycle: h23
- resources:
    cpu: true
    memory: true
    disk: /
    uptime: true
- docker:
    label: Contenedores
EOF
  cat > services/homepage/config/docker.yaml << 'EOF'
my-docker:
    socket: /var/run/docker.sock
EOF
  cat > services/homepage/config/services.yaml << EOF
- Media:
    - Jellyfin:
        icon: jellyfin.png
        href: http://${MEDIA_SERVER_IP}:8096
        description: Servidor de streaming
        server: my-docker
        container: chae-jellyfin
    - Radarr:
        icon: radarr.png
        href: http://${MEDIA_SERVER_IP}:7878
        description: Películas
        server: my-docker
        container: chae-radarr
        widget:
          type: radarr
          url: http://chae-radarr:7878
          key: CHANGEME_RADARR
          enableQueue: true
    - Sonarr:
        icon: sonarr.png
        href: http://${MEDIA_SERVER_IP}:8989
        description: Series
        server: my-docker
        container: chae-sonarr
        widget:
          type: sonarr
          url: http://chae-sonarr:8989
          key: CHANGEME_SONARR
          enableQueue: true
    - Bazarr:
        icon: bazarr.png
        href: http://${MEDIA_SERVER_IP}:6767
        description: Subtítulos
        server: my-docker
        container: chae-bazarr
        widget:
          type: bazarr
          url: http://chae-bazarr:6767
          key: CHANGEME_BAZARR
    - Prowlarr:
        icon: prowlarr.png
        href: http://${MEDIA_SERVER_IP}:9696
        description: Indexadores
        server: my-docker
        container: chae-prowlarr
        widget:
          type: prowlarr
          url: http://chae-prowlarr:9696
          key: CHANGEME_PROWLARR
    - qBittorrent:
        icon: qbittorrent.png
        href: http://${MEDIA_SERVER_IP}:8080
        description: Torrents
        server: my-docker
        container: chae-qbittorrent
        widget:
          type: qbittorrent
          url: http://chae-qbittorrent:8080
          username: admin
          password: \${QBITTORRENT_PASSWORD}
EOF
  cp /dev/null services/homepage/config/custom.css
  cat >> services/homepage/config/custom.css << 'EOF'
/* Chae theme — Fearless Blue glass */
#page_wrapper{background:radial-gradient(900px 520px at 12% -10%,rgba(91,157,217,.16),transparent 60%),radial-gradient(1000px 600px at 88% 8%,rgba(124,140,255,.13),transparent 62%),linear-gradient(180deg,#0a1120,#060a13)!important;background-attachment:fixed!important}
.service-card,[class*="information-widget"],.widget-container>div{background:rgba(15,23,42,.55)!important;backdrop-filter:blur(14px);border:1px solid rgba(148,197,255,.10)!important;border-radius:16px!important;transition:.25s}
.service-card:hover{border-color:rgba(56,214,255,.45)!important;transform:translateY(-2px);box-shadow:0 0 24px -6px rgba(56,214,255,.28)}
.service-card [class*="bg-emerald"],.service-card [class*="bg-green"]{box-shadow:0 0 8px 1px rgba(52,211,153,.75)}
EOF
  ok "configs generadas en services/homepage/config/"
  warn "las API keys de los widgets se completan después: scripts/sync-homepage-keys.sh"
  if [ "$DRY_RUN" != 1 ]; then
    args=(-f services/homepage/docker-compose.yml)
    [ -f services/homepage/docker-compose.override.yml ] && args+=(-f services/homepage/docker-compose.override.yml)
    docker compose "${args[@]}" up -d 2>&1 | grep -v '^$' | head -2 && ok "homepage reiniciado con configs"
  fi
fi
endstep

# ══════════════════════════ 8 · RESUMEN ══════════════════════════
step "8/${STEP_TOTAL} · Resumen final"

echo "${FB}┃${R}"
echo "${FB}┃${R}  ${B}${WHT}URLs del stack:${R}"
print_url() { # print_url <Nombre> <puerto>
  local n="${1,,}" p="$2"
  for s in "${SELECTED[@]}"; do
    if [[ "$n" == *"${s%%-*}"* ]]; then
      echo "${FB}┃${R}    ${SLV}http://${MEDIA_SERVER_IP}:${p}${R}  ← $n"
      return
    fi
  done
}
print_url Jellyfin 8096;      print_url Jellyseerr 5055
print_url Radarr 7878;        print_url Sonarr 8989
print_url Bazarr 6767;        print_url Prowlarr 9696
print_url qBittorrent 8080;   print_url Homepage 3003
print_url UptimeKuma 3001;    print_url AdGuard 3002
print_url Tdarr 8265;         print_url Maintainerr 8787

echo "${FB}┃${R}"
if [ ${#FAILS[@]} -gt 0 ]; then
  failx "servicios con problemas: ${FAILS[*]} — revisá sus logs"
fi

cat << EOF

  ${FB}╭──────────────────────────────────────────────────────╮${R}
  ${FB}│${R}  ${B}${WHT}Instalación completa${R}
  ${FB}│${R}
  ${FB}│${R}  ${SLV}Próximos pasos manuales:${R}
  ${FB}│${R}   1. Abrí Jellyfin y completá el asistente inicial
  ${FB}│${R}   2. Poné la contraseña generada en qBittorrent:
  ${FB}│${R}      ${DIM}\$ grep QBITTORRENT_PASSWORD .env${R}
  ${FB}│${R}   3. Conectá Radarr/Sonarr ↔ qBittorrent y Prowlarr
  ${FB}│${R}   4. ${DIM}./scripts/sync-homepage-keys.sh${R} cuando tengas
  ${FB}│${R}      las API keys de los *arr
  ${FB}│${R}
  ${FB}│${R}  ${DIM}Gestión diaria:${R}
  ${FB}│${R}    ./scripts/start-stack.sh · stop-stack.sh · health-check.sh
  ${FB}╰──────────────────────────────────────────────────────╯${R}

  ${FB}${B}        ♪  You're an antifragile  ♪${R}
  ${DIMF}              — LE SSERAFIM, ANTIFRAGILE${R}
  ${DIM}        instalado sin miedo, como manda Chaewon 🐯${R}
EOF
footer
