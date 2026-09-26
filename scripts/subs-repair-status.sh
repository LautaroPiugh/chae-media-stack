#!/usr/bin/env bash
# Visor en vivo de la reparacion de subtitulos ES (popup tmux: prefix + P).
# Un fotograma; el popup lo refresca solo. 'q' cierra.
set -u

LOGS=(/home/chae/stack/logs/repair-girls.log /home/chae/stack/logs/repair-all.log)
LOG=""
for f in "${LOGS[@]}"; do
  [ -s "$f" ] && LOG="$f"
done
for f in "${LOGS[@]}"; do
  if fuser -s "$f" 2>/dev/null; then LOG="$f"; fi
done

B='\033[36m'; G='\033[32m'; R='\033[31m'; Y='\033[33m'; N='\033[0m'; D='\033[2m'; BLD='\033[1m'

ok=0; bad=0; total=""; last=""; cur=""; fails=""
if [ -n "$LOG" ]; then
  ok=$(grep -c -- '-> OK' "$LOG" 2>/dev/null || true)
  bad=$(grep -cE 'no devolvio SRT|no se pudo extraer|fallo la traduccion|QA rechazo' "$LOG" 2>/dev/null || true)
  total=$(grep -oE '\[[0-9]+/[0-9]+\]' "$LOG" 2>/dev/null | tail -1 | sed 's|.*/\([0-9]*\)]|\1|')
  cur=$(grep -E 'whisper\+traducir:' "$LOG" 2>/dev/null | tail -2 | sed 's/.*whisper+traducir: //;s/ (dur=.*//')
  last=$(grep -E '^\[[0-9]' "$LOG" 2>/dev/null | tail -1)
  fails=$(grep -E 'no devolvio SRT|no se pudo extraer|fallo la traduccion|QA rechazo' "$LOG" 2>/dev/null | tail -5 | sed 's/^\[[^]]*\] \[[0-9]*\/[0-9]*\] //')
fi
ok=$(echo "$ok" | head -1); bad=$(echo "$bad" | head -1)
ok=${ok:-0}; bad=${bad:-0}
done_n=$((ok + bad))
proc=$(pgrep -af 'fix_subs_whisper.py fix-broken' | grep -v grep | wc -l)

echo -e "${BLD}${B}═══ REPARACIÓN DE SUBTÍTULOS ES ═══${N}  ${D}${LOG:-sin log}${N}"
echo
if [ "$proc" -gt 0 ]; then
  echo -e " estado   : ${G}EN CURSO${N} (${proc} proceso(s), ${D}2 hilos${N})"
else
  echo -e " estado   : ${Y}DETENIDO${N}"
  cur=""
fi
if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
  pct=$((done_n * 100 / total))
  echo -e " avance   : ${B}${done_n}/${total}${N}  ${D}(${pct}%)${N}   ${G}${ok} ok${N} · ${R}${bad} fallos${N}"
else
  echo -e " avance   : ${G}${ok} ok${N} · ${R}${bad} fallos${N}"
fi
echo
echo -e "${B} en vuelo ahora${N}"
if [ -n "$cur" ]; then
  echo "$cur" | sed 's/^/  ▶ /'
else
  echo -e "  ${D}(ninguno)${N}"
fi
echo
echo -e "${B} último movimiento${N}"
echo -e "  ${D}${last:-(nada)}${N}"
echo
echo -e "${B} últimos fallos${N}"
if [ -n "$fails" ]; then
  echo "$fails" | sed 's/^/  ✗ /'
else
  echo -e "  ${D}(ninguno)${N}"
fi
echo
echo -e "${D} refresco 2s · q para cerrar · logs: ${LOG:--}${N}"
