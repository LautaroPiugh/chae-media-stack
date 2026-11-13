#!/usr/bin/env bash
# add-bot-user.sh — da de alta un usuario en el bot de WhatsApp y le manda la bienvenida.
#
# Hace el flujo completo:
#   1. agrega el número a WHATSAPP_USERS en jellyfin-whatsapp-bot/.env
#   2. recrea el contenedor (el env_file se lee al crear, no en restart)
#   3. espera a que WhatsApp esté conectado
#   4. envía la bienvenida por POST /admin/message
#   5. lo marca en auth/greeted-users.json para que no reciba la automática
#
# Uso:
#   scripts/add-bot-user.sh 5491123456789 [Nombre]
#   scripts/add-bot-user.sh --dry-run 5491123456789 [Nombre]
#   scripts/add-bot-user.sh --resend 5491123456789 [Nombre]   # ya existe, sólo reenvía
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_DIR="$ROOT/jellyfin-whatsapp-bot"
ENV_FILE="$BOT_DIR/.env"
COMPOSE_FILE="$BOT_DIR/docker-compose.yml"
GREETED_FILE="$BOT_DIR/auth/greeted-users.json"

DRY_RUN=0
RESEND=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --resend)  RESEND=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "opción desconocida: $arg" >&2; exit 2 ;;
    *) ARGS+=("$arg") ;;
  esac
done

NUMBER_RAW="${ARGS[0]:-}"
NAME="${ARGS[1]:-}"
if [[ -z "$NUMBER_RAW" ]]; then
  echo "falta el número (ej: scripts/add-bot-user.sh 5491123456789 Nahue)" >&2
  exit 2
fi

NUMBER="$(printf '%s' "$NUMBER_RAW" | tr -cd '0-9')"
if [[ ${#NUMBER} -lt 10 ]]; then
  echo "número inválido: $NUMBER_RAW (se esperan dígitos con código de país, sin +)" >&2
  exit 2
fi

[[ -f "$ENV_FILE" ]] || { echo "no existe $ENV_FILE" >&2; exit 1; }

# --- token y puerto del bot --------------------------------------------------
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -n1; }
TOKEN="$(env_value WHATSAPP_UPDATE_NOTIFY_TOKEN)"
PORT="$(env_value PORT)"
PORT="${PORT:-3555}"
[[ -n "$TOKEN" ]] || { echo "falta WHATSAPP_UPDATE_NOTIFY_TOKEN en .env" >&2; exit 1; }

# --- 1. alta en .env ---------------------------------------------------------
CURRENT="$(env_value WHATSAPP_USERS)"
ALREADY=0
IFS=',' read -r -a NUMS <<< "$CURRENT"
for n in "${NUMS[@]}"; do
  [[ "$n" == "$NUMBER" ]] && ALREADY=1
done

if [[ "$ALREADY" -eq 1 && "$RESEND" -eq 0 ]]; then
  echo "El número $NUMBER ya está en WHATSAPP_USERS. Usá --resend para reenviar la bienvenida."
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] agregaría $NUMBER a WHATSAPP_USERS (actual: ${CURRENT})"
  echo "[dry-run] recrearía el contenedor y enviaría la bienvenida${NAME:+ a $NAME}"
  exit 0
fi

if [[ "$ALREADY" -eq 0 ]]; then
  cp -p "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "$ENV_FILE" "$NUMBER" <<'PY'
import sys
path, number = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out = []
for line in lines:
    if line.startswith('WHATSAPP_USERS='):
        nums = [n for n in line.split('=', 1)[1].split(',') if n]
        if number not in nums:
            nums.append(number)
        line = 'WHATSAPP_USERS=' + ','.join(nums)
    out.append(line)
open(path, 'w').write('\n'.join(out) + '\n')
PY
  echo "✔ $NUMBER agregado a WHATSAPP_USERS"
else
  echo "• $NUMBER ya estaba en WHATSAPP_USERS (reenviando)"
fi

# --- 2. recrear el contenedor ------------------------------------------------
echo "→ recreando el bot…"
docker compose -f "$COMPOSE_FILE" up -d >/dev/null

# --- 3 y 4. esperar conexión y enviar ---------------------------------------
saludo="¡Hola${NAME:+ $NAME}! 👋 Bienvenido."
MESSAGE="$saludo

Soy el bot del servidor de series y películas. Desde acá podés pedir contenido y ver cómo viene todo.

🎬 *Para ver*
https://jellyfin.lolisticos.com
Necesitás tu cuenta. Si no la tenés, pedila y te la creo.

🍿 *Para pedir*
- /peli nombre de la película
- /serie nombre de la serie
Te muestro opciones y respondés \"peli 1\" o \"serie 1\".

📊 *Para consultar*
- /status estado del servidor
- /cola descargas en curso
- /pedidos lo que pediste
- /espacio espacio en disco
- /subs subtítulos en español

🧭 *Para explorar*
- /catalogo qué hay disponible
- /faltantes pedido y todavía no llegó
- /azar recomendación al azar
- /ultimo lo último agregado

Escribí /ayuda cuando quieras el listado completo."

sent=0
for intento in $(seq 1 20); do
  body="$(python3 -c 'import json,sys; print(json.dumps({"to":sys.argv[1],"message":sys.argv[2]}))' "$NUMBER" "$MESSAGE")"
  if curl -fsS -o /tmp/add-bot-user.out -X POST \
      -H 'Content-Type: application/json' \
      -H "x-update-token: $TOKEN" \
      --data "$body" \
      "http://127.0.0.1:$PORT/admin/message" >/dev/null 2>&1; then
    if grep -q '"ok":true' /tmp/add-bot-user.out; then
      sent=1; break
    fi
  fi
  sleep 3
done

if [[ "$sent" -ne 1 ]]; then
  echo "✘ no se pudo enviar la bienvenida (¿WhatsApp conectado?). El usuario quedó dado de alta." >&2
  exit 1
fi
echo "✔ bienvenida enviada a $NUMBER"

# --- 5. marcar como saludado -------------------------------------------------
python3 - "$GREETED_FILE" "$NUMBER@s.whatsapp.net" <<'PY'
import json, os, sys
path, jid = sys.argv[1], sys.argv[2]
cur = []
if os.path.exists(path):
    try: cur = json.load(open(path))
    except Exception: cur = []
if not isinstance(cur, list): cur = []
if jid not in cur: cur.append(jid)
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(cur, open(path, 'w'))
PY
echo "✔ marcado como ya saludado"
