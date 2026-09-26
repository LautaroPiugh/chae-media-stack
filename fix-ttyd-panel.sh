#!/usr/bin/env bash
# fix-ttyd-panel.sh — libera el puerto 7681 para ttyd-panel.service
#
# Problema: el paquete de ttyd habilita ttyd.service (login genérico de root)
# con "-p 7681" y se queda con el puerto; ttyd-panel.service (panel-remoto con
# credencial, el que usa el túnel de Cloudflare) no puede bindear y entra en
# auto-restart.
#
# Solución: movemos ttyd.service al 7682. No se desactiva ni se pierde nada, y
# el panel queda con el 7681 que espera el túnel. Si no usás el login genérico,
# se puede desactivar con:  systemctl disable --now ttyd
#
# Uso:  sudo bash fix-ttyd-panel.sh
set -Eeuo pipefail

B='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
ok()   { printf "${G}  ✔ %s${N}\n" "$*"; }
warn() { printf "${Y}  ⚠ %s${N}\n" "$*"; }
die()  { printf "${R}ERROR: %s${N}\n" "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "correr como root: sudo bash $0"

CFG=/etc/default/ttyd
[[ -f "$CFG" ]] || die "no existe $CFG"

if grep -q '\-p 7681' "$CFG"; then
  cp "$CFG" "${CFG}.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i 's/-p 7681/-p 7682/' "$CFG"
  ok "$CFG: ttyd.service movido al 7682 (backup hecho)"
else
  warn "$CFG no tiene -p 7681; dejo como está"
fi

echo
echo "── dejando el 7681 libre para ttyd-panel ──"
# matar el ttyd viejo que sigue sosteniendo el 7681
if systemctl is-active --quiet ttyd; then
  systemctl restart ttyd || warn "no pude reiniciar ttyd"
  ok "ttyd.service reiniciado (debería estar en 7682)"
fi

# si aún así alguien tiene el 7681, avisar (no matar a ciegas)
if ss -tlnp 2>/dev/null | grep -q '127.0.0.1:7681'; then
  warn "el 7681 sigue ocupado:"
  ss -tlnp 2>/dev/null | grep '7681' | sed 's/^/    /'
fi

echo
echo "── arrancando ttyd-panel ──"
systemctl daemon-reload
systemctl restart ttyd-panel
sleep 2

echo
printf '%s═══ Resultado ═══%s\n' "$B" "$N"
ss -tlnp 2>/dev/null | grep -E ':7681|:7682' | sed 's/^/  /'
echo
for u in ttyd ttyd-panel; do
  printf '  %-14s %s\n' "$u" "$(systemctl is-active "$u")"
done
echo
if systemctl is-active --quiet ttyd-panel; then
  ok "ttyd-panel corriendo en https://127.0.0.1:7681 (Panel remoto)"
else
  warn "ttyd-panel no arrancó; mirá: journalctl -u ttyd-panel -n 30"
fi
