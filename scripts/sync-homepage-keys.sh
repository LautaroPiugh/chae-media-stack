#!/usr/bin/env bash
# ============================================================================
#  Completa las API keys de los widgets del dashboard (homepage) leyéndolas
#  de la configuración de cada app. Idempotente.
#
#  Uso: ./scripts/sync-homepage-keys.sh
# ============================================================================
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
HP="$DIR/services/homepage/config/services.yaml"

[ -f "$HP" ] || { echo "✗ no existe $HP — instalá homepage primero"; exit 1; }

get_key() { # get_key <archivo> <regex>
    grep -oiE "$2" "$1" 2>/dev/null | head -1 | sed 's/.*[=:<>] *//' | tr -d '"' || true
}

updated=0

set_key() { # set_key <nombre-widget> <key>
    local widget="$1" key="$2"
    [ -z "$key" ] && return 0
    if grep -q "CHANGEME_${widget}" "$HP"; then
        sed -i "s/CHANGEME_${widget}/${key}/" "$HP"
        echo "  ✔ $widget: key completada"
        updated=$((updated+1))
    fi
}

echo "── Sincronizando API keys al dashboard ──"

for app in radarr sonarr prowlarr; do
    xml="$DIR/services/$app/config/config.xml"
    if [ -f "$xml" ]; then
        key=$(get_key "$xml" '<ApiKey>[^<]+</ApiKey>')
        set_key "$(echo $app | tr a-z A-Z)" "$key"
    fi
done

bazarr_ini="$DIR/services/bazarr/config/config/config.ini"
if [ -f "$bazarr_ini" ]; then
    key=$(awk '/^\[auth\]/,/^\[/' "$bazarr_ini" | get_key /dev/null 'api_key *= *[a-f0-9]{32}')
    set_key BAZARR "$key"
fi

seerr_json="$DIR/services/jellyseerr/config/settings.json"
if [ -f "$seerr_json" ]; then
    key=$(python3 -c "import json;print(json.load(open('$seerr_json')).get('main',{}).get('apiKey',''))" 2>/dev/null)
    set_key JELLYSEERR "$key"
fi

# qBittorrent y AdGuard toman usuario/contraseña de .env vía ${VARS}
if grep -q 'CHANGEME' "$HP"; then
    echo
    echo "  ▲ Quedan placeholders CHANGEME en services.yaml:"
    grep -n 'CHANGEME' "$HP" | sed 's/^/      /'
    echo "  ▲ Jellyfin: creá una API key en Dashboard→API Keys y pégala a mano,"
    echo "    o completá los CHANGEME restantes editando services.yaml"
else
    echo "  ✔ Todas las keys están completas"
fi

[ $updated -gt 0 ] && echo "── $updated keys actualizadas ──"
exit 0
