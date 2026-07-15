# Guía de Instalación — Chae Media Stack

Guía paso a paso para instalar y configurar el stack completo desde cero.

---

## 1. Requisitos de Hardware

| Componente | Mínimo | Recomendado |
|------------|--------|-------------|
| CPU | 2 núcleos | 4 núcleos+ (para transcodificación) |
| RAM | 4 GB | 8-16 GB |
| Disco sistema | 20 GB SSD | 100 GB SSD |
| Disco multimedia | 500 GB | 1 TB+ |
| GPU | - | Intel con VAAPI (para transcodificar) |

### Estructura de almacenamiento esperada

El stack asume esta estructura de discos:

```
/mnt/media/      → Pool de almacenamiento multimedia (mergerfs opcional)
/mnt/media1/     → Disco 1
/mnt/media2/     → Disco 2 (descargas + backups)
```

Si tenés un solo disco, montalo en `/mnt/media` y creá los directorios. Si tenés dos o más, podés usar mergerfs para combinarlos (opcional).

Crear la estructura de directorios:

```bash
sudo mkdir -p /mnt/media/{movies,series,anime,music,downloads/{incomplete,torrents},backups}
sudo mkdir -p /mnt/media2/downloads /mnt/media2/backups/stack
```

Si usás discos separados, montalos según tu configuración. Ejemplo con `/etc/fstab`:

```bash
# /dev/sdb1 → /mnt/media1
echo "UUID=TU_UUID /mnt/media1 ntfs defaults,uid=1000,gid=1000 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

---

## 2. Instalar Dependencias

### Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verificar:

```bash
docker --version
```

### Docker Compose (plugin)

```bash
sudo apt install docker-compose-plugin -y
```

Verificar:

```bash
docker compose version
```

### Python 3 + librerías (para scripts de subtítulos)

```bash
sudo apt install python3 python3-pip python3-requests -y
```

Verificar:

```bash
python3 --version
pip3 show requests
```

### Node.js 20 + pnpm (solo si querés correr el bot sin Docker)

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install nodejs -y
sudo corepack enable && sudo corepack prepare pnpm@10.33.4 --activate
```

Verificar:

```bash
node --version
pnpm --version
```

---

## 3. Crear Redes Docker

Los servicios necesitan dos redes Docker para comunicarse entre sí:

```bash
docker network create qbittorrent_default
docker network create jellyfin_default
```

Verificar:

```bash
docker network ls | grep -E 'qbittorrent_default|jellyfin_default'
```

---

## 4. Clonar el Repositorio

```bash
git clone https://github.com/LautaroPiugh/chae-media-stack.git
cd chae-media-stack
```

---

## 5. Configurar Servicios

Cada servicio tiene un archivo `docker-compose.yml`. Algunos requieren editar variables antes de iniciarlos.

### Postgres

Editar `services/postgres/docker-compose.yml` y cambiar la contraseña:

```yaml
POSTGRES_PASSWORD: CHANGEME  # cambiá esto por una contraseña segura
```

### Jellyfin

Editar `services/jellyfin/docker-compose.yml` y cambiar la IP por la de tu servidor:

```yaml
JELLYFIN_PublishedServerUri=http://192.168.1.100:8096
```

### Homepage

Editar `services/homepage/docker-compose.yml` y cambiar la IP:

```yaml
HOMEPAGE_ALLOWED_HOSTS=192.168.1.100:3003,localhost:3003
```

### WhatsApp Bot

```bash
cp jellyfin-whatsapp-bot/.env.example jellyfin-whatsapp-bot/.env
nano jellyfin-whatsapp-bot/.env
```

Variables obligatorias:

| Variable | Descripción | Cómo obtenerla |
|----------|-------------|----------------|
| `WHATSAPP_OWNER` | Tu número de WhatsApp (sin + ni espacios) | Tu número |
| `JELLYFIN_URL` | URL de Jellyfin | `http://TU_IP:8096` |
| `JELLYFIN_API_KEY` | API key de Jellyfin | Dashboard Jellyfin → API Key |
| `RADARR_URL` | URL de Radarr | `http://radarr:7878` |
| `RADARR_API_KEY` | API key de Radarr | Settings → General → API Key |
| `SONARR_URL` | URL de Sonarr | `http://sonarr:8989` |
| `SONARR_API_KEY` | API key de Sonarr | Settings → General → API Key |

### Script de subtítulos

```bash
cp scripts/check_es_subs.env.example scripts/check_es_subs.env 2>/dev/null || true
nano scripts/check_es_subs.env
```

**Nota:** no existe un `.env.example` para este script. Los valores necesarios son:

| Variable | Descripción |
|----------|-------------|
| `BAZARR_URL` | `http://localhost:6767` |
| `BAZARR_API_KEY` | API key de Bazarr (Settings → General) |
| `DEEPL_API_KEY` | API key de DeepL (https://deepl.com/pro-api) |
| `OMDB_API_KEY` | API key de OMDb (http://omdbapi.com/apikey.aspx) |
| `NOTIFY_URL` | `http://localhost:3555/notify/system-update` |
| `NOTIFY_SECRET` | Token para autenticar notificaciones |

---

## 6. Iniciar Servicios

Levantar los servicios **en este orden** para evitar errores de dependencia.

### 6.1. Base de datos

```bash
cd services/postgres && docker compose up -d && cd ../..
```

### 6.2. Indexadores (Prowlarr)

```bash
cd services/prowlarr && docker compose up -d && cd ../..
```

**Post-configuración:** entrá a `http://TU_IP:9696` y agregá tus trackers (indexadores) de torrents.

### 6.3. Gestores de contenido (Radarr + Sonarr)

```bash
cd services/radarr && docker compose up -d && cd ../..
cd services/sonarr && docker compose up -d && cd ../..
```

**Post-configuración:** en cada uno:
1. Entrá a la UI (`http://TU_IP:7878` y `http://TU_IP:8989`)
2. Settings → Indexers → Agregar Prowlarr como indexador
3. Configurá las carpetas raíz (`/media/movies`, `/media/series`)
4. Settings → General → Copiá la API Key para usarla en el bot

### 6.4. Cliente de descargas (qBittorrent)

```bash
cd services/qbittorrent && docker compose up -d && cd ../..
```

**Post-configuración:**
1. Entrá a `http://TU_IP:8080` (usuario: `admin`, contraseña: `adminadmin`)
2. Cambiá la contraseña por defecto
3. Settings → Downloads → Directorio por defecto: `/downloads/torrents`
4. Settings → Connection → UPnP / Port Forwarding: activado

### 6.5. Subtítulos (Bazarr)

```bash
cd services/bazarr && docker compose up -d && cd ../..
```

**Post-configuración:**
1. Entrá a `http://TU_IP:6767`
2. Settings → Radarr/Sonarr: configurar conexión con las API keys
3. Settings → Languages: `es` y `ea`
4. Settings → Providers: activar opensubtitlescom, legendasdivx, podnapisi, subf2m, subdl

### 6.6. Streaming (Jellyfin)

```bash
cd services/jellyfin && docker compose up -d && cd ../..
```

**Post-configuración:**
1. Entrá a `http://TU_IP:8096` y completá el setup inicial
2. Agregá las bibliotecas: `/media/movies`, `/media/series`, `/media/anime`, `/media/music`
3. Settings → API Key → generá una para el bot

### 6.7. Solicitudes (Jellyseerr)

```bash
cd services/jellyseerr && docker compose up -d && cd ../..
```

**Post-configuración:**
1. Entrá a `http://TU_IP:5055`
2. Configurá conexión con Jellyfin, Radarr y Sonarr

### 6.8. Utilidades (resto de servicios)

```bash
cd services/flaresolverr && docker compose up -d && cd ../..
cd services/subgen && docker compose up -d && cd ../..
cd services/uptime-kuma && docker compose up -d && cd ../..
cd services/homepage && docker compose up -d && cd ../..
cd services/tdarr && docker compose up -d && cd ../..
cd services/adguard && docker compose up -d && cd ../..
cd nginx-proxy-manager && docker compose up -d && cd ..
```

### 6.9. Bot de WhatsApp

```bash
cd jellyfin-whatsapp-bot
docker compose up -d --build
docker logs -f jellyfin-whatsapp-bot
```

Buscá el código QR en los logs. En WhatsApp: ⋮ → Dispositivos vinculados → Vincular un dispositivo → Escaneá el QR.

---

## 7. Configurar Webhooks

Conectá Radarr y Sonarr al bot para recibir notificaciones de descargas.

### Radarr

1. Settings → Connect → + → Webhook
2. Name: `Jellyfin WhatsApp Bot`
3. URL: `http://TU_IP:3555/webhook/radarr`
4. Events: ✅ Download, ✅ Upgrade
5. Save

### Sonarr

1. Settings → Connect → + → Webhook
2. Name: `Jellyfin WhatsApp Bot`
3. URL: `http://TU_IP:3555/webhook/sonarr`
4. Events: ✅ Download, ✅ Upgrade
5. Save

---

## 8. Configurar Cron Jobs (Opcional)

Los scripts de automatización mejoran el stack pero no son obligatorios.

Agregar al crontab del usuario:

```bash
crontab -e
```

Agregar estas líneas:

```cron
# Verificar montura de /mnt/media cada 2 minutos
*/2 * * * * /home/$USER/chae-media-stack/scripts/media-mount-recovery.sh

# Generar caché del dashboard cada 5 minutos
*/5 * * * * /home/$USER/chae-media-stack/scripts/generate-stack-dashboard-data.sh

# Traducir subtítulos EN→ES vía Gemini cada 10 minutos
*/10 * * * * python3 /home/$USER/chae-media-stack/services/bazarr/auto_translate.py

# Verificar subtítulos ES faltantes cada 6 horas
0 */6 * * * python3 /home/$USER/chae-media-stack/scripts/check_es_subs.py

# Backup diario a las 3am
0 3 * * * /home/$USER/chae-media-stack/scripts/backup-stack.sh
```

**Importante:** reemplazá `$USER` por tu nombre de usuario real.

---

## 9. Verificar Instalación

Probar que cada servicio responde:

```bash
# Docker: todos los contenedores corriendo
docker ps

# Jellyfin
curl -s -o /dev/null -w "%{http_code}" http://localhost:8096

# Radarr
curl -s -o /dev/null -w "%{http_code}" http://localhost:7878

# Sonarr
curl -s -o /dev/null -w "%{http_code}" http://localhost:8989

# qBittorrent
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080

# Bot de WhatsApp
curl -s http://localhost:3555/health
```

Si todos devuelven `200`, la instalación está completa.

---

## 10. Troubleshooting

### Contenedor no arranca

```bash
# Ver logs del servicio
docker logs chae-radarr
docker logs chae-jellyfin

# Ver si el contenedor existe y su estado
docker ps -a | grep chae
```

### Puerto ocupado

```bash
# Ver qué proceso está usando el puerto
sudo lsof -i :8096

# Cambiar el puerto en docker-compose.yml si es necesario
```

### No aparece el QR del bot

```bash
# Revisar logs
docker logs -f jellyfin-whatsapp-bot

# Si no aparece, reiniciar
docker compose restart
```

### Webhooks no llegan

- Verificá que la URL del webhook sea accesible desde Radarr/Sonarr
- Si Radarr/Sonarr están en Docker, usá el nombre del contenedor como host: `http://jellyfin-whatsapp-bot:3555/webhook/radarr`
- Verificá que el bot esté corriendo: `curl http://localhost:3555/health`

---

## Resumen de URLs

| Servicio | URL |
|----------|-----|
| Jellyfin | `http://TU_IP:8096` |
| Radarr | `http://TU_IP:7878` |
| Sonarr | `http://TU_IP:8989` |
| Prowlarr | `http://TU_IP:9696` |
| Bazarr | `http://TU_IP:6767` |
| qBittorrent | `http://TU_IP:8080` |
| Jellyseerr | `http://TU_IP:5055` |
| Tdarr | `http://TU_IP:8265` |
| Portainer | `https://TU_IP:9443` |
| Bot API | `http://localhost:3555/health` |
