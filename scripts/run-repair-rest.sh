#!/usr/bin/env bash
set -u
cd /home/chae/stack/scripts
while pgrep -f "fix_subs_whisper.py fix-broken /mnt/media/series/Girls" >/dev/null 2>&1; do
  sleep 60
done
echo "[$(date +%T)] Girls terminado; lanzando el resto de la biblioteca" >> /home/chae/stack/logs/repair-all.log
python3 fix_subs_whisper.py fix-broken /mnt/media --jobs=2 >> /home/chae/stack/logs/repair-all.log 2>&1
echo "[$(date +%T)] biblioteca terminada" >> /home/chae/stack/logs/repair-all.log
