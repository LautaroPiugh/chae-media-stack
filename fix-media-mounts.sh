#!/bin/bash
set -e

echo "=== Paso 1: Desmontar /mnt/media ==="
sudo umount /mnt/media || echo "Ya estaba desmontado"

echo ""
echo "=== Paso 2: Verificar NTFS en ambos discos ==="
echo "Verificando /dev/sdd1 (Back - 698GB)..."
#sudo ntfsfix /dev/sdd1

echo ""
echo "Verificando /dev/sdb4 (465GB)..."
#sudo ntfsfix /dev/sdb4

echo ""
echo "=== Paso 3: Montar ambos discos con ntfs-3g ==="
echo "Montando /dev/sdb4 en /mnt/media1..."
sudo mount -t ntfs-3g -o defaults,nofail,uid=1000,gid=1000,umask=002,x-systemd.device-timeout=10 /dev/sdb4 /mnt/media1

echo "Montando /dev/sdd1 en /mnt/media2..."
sudo mount -t ntfs-3g -o defaults,nofail,uid=1000,gid=1000,umask=002,x-systemd.device-timeout=10 /dev/sdd1 /mnt/media2

echo ""
echo "=== Paso 4: Activar mergerfs ==="
sudo systemctl daemon-reload
sudo mount /mnt/media

echo ""
echo "=== Paso 5: Desactivar jellyfin.service nativo ==="
sudo systemctl disable jellyfin.service || echo "Ya estaba desactivado"

echo ""
echo "=== Paso 6: Verificar montajes ==="
mount | grep -E "media|fuse"

echo ""
echo "=== Paso 7: Verificar acceso a datos ==="
ls -la /mnt/media/ | head -10

echo ""
echo "=== Paso 8: Reiniciar Jellyfin Docker ==="
docker start chae-jellyfin

echo ""
echo "=== Paso 9: Verificar logs de Jellyfin ==="
sleep 3
docker logs chae-jellyfin --tail 20

echo ""
echo "=== Completado ==="
echo "Si todo esta bien, los microcortes deberian desaparecer."
echo "Monitorea con: docker logs -f chae-jellyfin"

