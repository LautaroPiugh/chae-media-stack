# Sistema Media Stack Personal

## Descripción General

Servidor multimedia argentino con 15+ servicios Docker, bot de WhatsApp, túnel Cloudflare, y pipeline automático de subtítulos. Corre en una PC con Ubuntu (hostname: `chae`).

---

## Hardware & Almacenamiento

| Componente | Detalle |
|-----------|---------|
| CPU | x86_64 |
| RAM | 16GB |
| Disco sistema | SSD 100G (LVM, 49% usado) |
| Disco datos 1 | HDD 465G → `/mnt/media1` (NTFS, 17% usado) |
| Disco datos 2 | HDD 699G → `/mnt/media2` (NTFS, 78% usado) |
| Pool mergerfs | `/mnt/media` = media1 + media2, 1.2T total (54% usado) |

### Pool mergerfs (`/mnt/media`)

Combina ambos discos. Política: `mfs` (most free space — escribe en el disco con más espacio libre). Mínimo 20G libres por disco.

```
/mnt/media/
  /movies/       → ~700 películas
  /series/       → series completas
  /anime/        → anime
  /music/        → música
  /downloads/    → descargas compartidas
    /incomplete/ → descargas parciales
    /torrents/   → torrents completados
  /backups/      → backups automáticos
```

### Script de recuperación

`/home/chae/scripts/media-mount-recovery.sh` corre cada 2 minutos vía cron. Si detecta que `/mnt/media` no está montado, espera a que se recupere y reinicia: Radarr, Sonarr, Bazarr, Jellyfin, qBittorrent.

---

## Servicios Docker (18 containers)

Todos corren con `PUID=1000`, `PGID=1000` (usuario `chae`), `TZ=America/Argentina/Buenos_Aires`.

### Streaming & Visualización

| Servicio | Puerto | URL | Imagen |
|----------|--------|-----|--------|
| **Jellyfin** | 8096 | `http://192.168.1.100:8096` | `lscr.io/linuxserver/jellyfin` |
| **Jellyseerr** | 5055 | `http://192.168.1.100:5055` | `ghcr.io/seerr-team/seerr` |
| **Uptime Kuma** | 3001 | `http://192.168.1.100:3001` | `louislam/uptime-kuma` |

### Gestión de Medios (Arr Stack)

| Servicio | Puerto | URL Interna | URL Host | Imagen |
|----------|--------|-------------|----------|--------|
| **Radarr** | 7878 | `http://radarr:7878` | `http://192.168.1.100:7878` | `lscr.io/linuxserver/radarr` |
| **Sonarr** | 8989 | `http://sonarr:8989` | `http://192.168.1.100:8989` | `lscr.io/linuxserver/sonarr` |
| **Bazarr** | 6767 | `http://bazarr:6767` | `http://192.168.1.100:6767` | `lscr.io/linuxserver/bazarr` |
| **Prowlarr** | 9696 | `http://prowlarr:9696` | `http://192.168.1.100:9696` | `lscr.io/linuxserver/prowlarr` |
| **qBittorrent** | 8080 | `http://qbittorrent:8080` | `http://192.168.1.100:8080` | `lscr.io/linuxserver/qbittorrent` |
| **Flaresolverr** | 8191 | `http://flaresolverr:8191` | - | `ghcr.io/flaresolverr/flaresolverr` |

### Utilidades

| Servicio | Puerto | URL | Imagen |
|----------|--------|-----|--------|
| **WhatsApp Bot** | 3555 | `http://localhost:3555` | `jellyfin-whatsapp-bot:latest` |
| **Tdarr** | 8265 | `http://192.168.1.100:8265` | `ghcr.io/haveagitgat/tdarr` |
| **Maintainerr** | 8787 | `http://192.168.1.100:8787` (mapped desde 6246) | `ghcr.io/maintainerr/maintainerr` |
| **Portainer** | 9443 (SSL) | `https://192.168.1.100:9443` | `portainer/portainer-ce` |
| **SubgenAI** | 9000 | `http://192.168.1.100:9000` | `mccloud/subgen:cpu` |
| **PostgreSQL** | 5432 | interno | `postgres:16` |
| **Nginx Proxy Manager** | 18080/18081/18443 | `http://192.168.1.100:18081` | `jc21/nginx-proxy-manager` |
| **Watchtower** | - | - | `containrrr/watchtower` |

### Red Docker

Hay una red principal `qbittorrent_default` que conecta la mayoría de los servicios. Los nombres DNS entre containers son los nombres cortos (ej: `radarr`, `sonarr`, `bazarr`).

```
qbittorrent_default:  radarr, sonarr, bazarr, prowlarr, jellyseerr, qbittorrent,
                      flaresolverr, jellyfin-whatsapp-bot, tdarr, tdarr-node, uptime-kuma
jellyfin_default:     jellyfin, uptime-kuma
```

---

## Túnel Cloudflare

El servidor es accesible desde internet mediante **Cloudflare Tunnel** (sin exponer puertos).

```bash
systemctl status cloudflared
# PID activo, protocolo quic, ubicación Ezeiza (eze02)
```

El túnel corre como servicio systemd con un token de Cloudflare. No hay archivos de configuración locales — se administra desde el dashboard de Cloudflare.

Auto-update: `cloudflared-update.service` corre `cloudflared update` y reinicia si hay versión nueva.

---

## WhatsApp Bot

Bot personal para administrar el media stack desde WhatsApp. Usa `@whiskeysockets/baileys` (WhatsApp Web).

**Código**: `/home/chae/jellyfin-whatsapp-bot/`
**Docker Compose**: `/home/chae/jellyfin-whatsapp-bot/docker-compose.yml`
**Puerto**: 3555
**Número**: `TU_NUMERO` (dueño/admin)
**Para reconectar**: el bot genera QR al iniciar si no hay sesión válida. Usar `/reconectar` si se pierde la sesión.

### Comandos Disponibles

| Comando | Descripción |
|---------|-------------|
| `/ayuda` o `/help` | Muestra todos los comandos |
| `/status` | Estado del sistema: conexiones, biblioteca, descargas, disco |
| `/subs` o `/subtitulos` | Estado de subtítulos ES: películas/series con y sin |
| `/traducir [película]` | Traduce subtítulos de una película EN→ES vía DeepL |
| `/buscar [nombre]` | Búsqueda combinada en Radarr + Sonarr |
| `/peli [nombre]` o `/pelicula [nombre]` | Buscar y agregar película a Radarr |
| `/serie [nombre]` o `/series [nombre]` | Buscar y agregar serie a Sonarr |
| `/azar [peli/serie]` o `/random` | Recomendación aleatoria de la biblioteca |
| `/recomendar [género]` | Recomendación por género |
| `/cola` o `/descargas` | Cola de descargas activas (Radarr + Sonarr + qBittorrent) |
| `/pedidos` o `/requests` | Solicitudes pendientes en Jellyseerr |
| `/mispedidos` | Mis solicitudes hechas desde el bot |
| `/ultimo` o `/último` | Últimas 5 películas/series agregadas |
| `/espacio` | Uso de disco |
| `/catalogo [tipo]` | Catálogo completo de películas o series |
| `/faltantes [tipo]` | Faltantes en la biblioteca |
| `/actualizar [nombre]` | Buscar mejor calidad para contenido existente |
| `/actualizarsistema` | Preparar actualización segura de Git y Docker |
| `/actualizarsistema estado` | Consultar la cola de actualización |
| `/eliminar [nombre]` | **(admin)** Eliminar de biblioteca + disco + torrents |
| `/refrescar [nombre]` | **(admin)** Refrescar metadatos + rescan en Sonarr |
| `/reiniciar` | **(admin)** Reinicia el bot |
| `/reconectar` | **(admin)** Reconecta WhatsApp Web |
| `/limpiartorrents` | **(admin)** Limpia torrents completados de qBittorrent |
| `/registraradmin` | Registra al usuario como admin (código: `0420`) |
| `/cancelar` | Cancela el flujo actual |
| `/repetir` | Repite la página actual de resultados |
| `/mas` | Siguiente página de resultados |

### Admin Verification

Para usar comandos admin, enviar `/registraradmin` una vez desde el número del dueño.

### Webhook Endpoints

| Endpoint | Token | Descripción |
|----------|-------|-------------|
| `POST /webhook/radarr?token=<RADARR_SECRET>` | Configurable en `.env` | Notifica películas descargadas |
| `POST /webhook/sonarr?token=<SONARR_SECRET>` | Configurable en `.env` | Notifica episodios descargados |
| `POST /notify/system-update` | Header: `x-update-token` | Recibe notificaciones del script de subs |

### Configuración

Archivo: `/home/chae/jellyfin-whatsapp-bot/.env`

```env
PORT=3555
WHATSAPP_OWNER=TU_NUMERO
JELLYFIN_URL=http://TU_IP:8096
JELLYFIN_API_KEY=CHANGEME
JELLYFIN_USER_ID=CHANGEME
RADARR_URL=http://radarr:7878
RADARR_API_KEY=CHANGEME
RADARR_ROOT_FOLDER=/media/movies
RADARR_QUALITY_PROFILE_ID=1
SONARR_URL=http://sonarr:8989
SONARR_API_KEY=CHANGEME
SONARR_ROOT_FOLDER=/media/series
SONARR_QUALITY_PROFILE_ID=1
BAZARR_URL=http://bazarr:6767
BAZARR_API_KEY=CHANGEME
JELLYSEERR_URL=http://jellyseerr:5055
JELLYSEERR_API_KEY=CHANGEME
QBITTORRENT_URL=http://qbittorrent:8080
QBITTORRENT_USERNAME=admin
QBITTORRENT_PASSWORD=CHANGEME
PROWLARR_URL=http://prowlarr:9696
PROWLARR_API_KEY=CHANGEME
DEEPL_API_KEY=CHANGEME
SERVICE_NAME=Jellyfin WhatsApp Bot
WHATSAPP_UPDATE_NOTIFY_TOKEN=CHANGEME
```

---

## Pipeline de Subtítulos

### Script Principal: `check_es_subs.py`

**Archivo**: `/home/chae/scripts/check_es_subs.py`
**ENV**: `/home/chae/scripts/check_es_subs.env`
**Log**: `/home/chae/scripts/check_es_subs.log`
**Cron**: Cada 6 horas (`0 */6 * * *`)
**Cache OMDb**: `/home/chae/scripts/omdb_cache.json`

#### Qué hace

1. Obtiene todas las películas y series de Bazarr
2. Para cada item, verifica si tiene subtítulos ES (códigos: `es`, `ea`, `sp`)
3. Si faltan, intenta descargar en este orden:
   - **Paso 1**: Bazarr providers (búsqueda directa de subs ES)
   - **Paso 2**: OpenSubtitles REST API (legacy, por IMDB ID)
     - Series: primero busca por IMDB de la serie, filtra por season/episode
     - Si no encuentra: busca IMDB del episodio vía OMDb API, busca por ese IMDB
   - **Paso 3 (solo películas)**: Descarga sub EN → DeepL → guarda como `.es.srt`
4. Si hubo descargas o errores, envía notificación WhatsApp al endpoint del bot

#### Modo CLI (para el bot)

```bash
python3 /home/chae/scripts/check_es_subs.py --translate-movie "Título de película"
```

### Script Secundario: `auto_translate.py`

**Archivo**: `/home/chae/services/bazarr/auto_translate.py`
**Cron**: Cada 10 minutos
Traduce subs EN→ES recién descargados por Bazarr usando Gemini AI.

### Filtro anti-SDH (subs para sordos)

Política: solo subtítulos español/español latam normales, nunca SDH/HI/CC.

- `check_es_subs.py` descarta candidatos marcados como hearing impaired (flag del API o nombre con `.hi.`/`.sdh.`/`.cc.`)
- Bazarr tiene `hi: False` en los perfiles de idioma
- `auto_translate.py` omite subs EN cuyo archivo sea SDH
- Cuarentena de SDH históricos: `scripts/sdh-quarantine.sh` mueve los existentes a `/mnt/media/backups/sdh-quarantine/` (94 archivos movidos el 2026-08-23; restaurar con `mv` inverso)

### OMDb Cache Persistente

Guarda IMDB IDs de episodios en JSON para no malgastar la cuota de 1000 llamadas/día. Se guarda tras cada consulta.

---

## Cron Jobs (usuario `chae`)

| Cada | Comando | Descripción |
|------|---------|-------------|
| 2 minutos | `/home/chae/scripts/media-mount-recovery.sh` | Verifica montura de `/mnt/media`, reinicia servicios si se recuperó |
| 5 minutos | `/home/chae/scripts/generate-stack-dashboard-data.sh` | Genera cache JSON para dashboard |
| 10 minutos | `python3 /home/chae/services/bazarr/auto_translate.py` | Traduce subs EN bjados por Bazarr vía Gemini |
| 6 horas | `python3 /home/chae/scripts/check_es_subs.py` | Verifica y descarga subtítulos ES faltantes |
| 3am daily | `/home/chae/scripts/backup-stack.sh` | Backup PostgreSQL + configs a `/mnt/media2/backups/stack/` (retención 14 días) |
| Manual por WhatsApp | `media-update-broker` | Actualiza la allowlist Docker uno por uno y se detiene ante fallos |
| on-demand | `./scripts/start-stack.sh` | Inicia todos los servicios en orden |
| on-demand | `./scripts/stop-stack.sh` | Detiene todos los servicios (orden inverso) |
| on-demand | `./scripts/health-check.sh` | Verifica estado de todos los containers + HTTP + almacenamiento |

---

## Arquitectura

```
                    Internet
                        |
                   [Cloudflare Tunnel]
                        |
                   [Prowlarr] (búsqueda de torrents)
                        |
             +----------+----------+
             |          |          |
         [Radarr]   [Sonarr]    [Bazarr]
         (pelis)    (series)   (subtítulos)
             |          |
             +----[qBittorrent]----+
                        |          |
                   [Jellyfin]   [Tdarr]
                  (streaming)  (transcode)

[WhatsApp Bot] ↔ Radarr + Sonarr + Bazarr + Jellyseerr + qBittorrent
     ↕ cron
[check_es_subs.py] ↔ Bazarr + OpenSubtitles + DeepL + OMDb
     ↕
[auto_translate.py] ↔ Bazarr + Gemini AI
```

### Flujo de Datos

1. **Agregar contenido**: Usuario escribe `/peli Nombre` en WhatsApp → Bot busca en Radarr/Sonarr → Prowlarr busca trackers → qBittorrent descarga → Jellyfin lo ve
2. **Subtítulos**: Cada 6h, script verifica faltantes → OpenSubtitles o DeepL → guarda `.es.srt`
3. **Notificaciones**: Radarr/Sonarr envían webhook al bot → bot reenvía a WhatsApp
4. **Transcodificación**: Tdarr procesa archivos automáticamente
5. **Actualizaciones**: `/actualizarsistema` usa código temporal, backups, health-check y rollback; Watchtower permanece deshabilitado
6. **Backups**: Diario 3am, Postgres + configs a disco 2, retención 14 días

---

## URLs de Acceso

| Servicio | URL Local |
|----------|-----------|
| Jellyfin | `http://192.168.1.100:8096` |
| Radarr | `http://192.168.1.100:7878` |
| Sonarr | `http://192.168.1.100:8989` |
| Bazarr | `http://192.168.1.100:6767` |
| Prowlarr | `http://192.168.1.100:9696` |
| qBittorrent | `http://192.168.1.100:8080` |
| Jellyseerr | `http://192.168.1.100:5055` |
| Uptime Kuma | `http://192.168.1.100:3001` |
| Tdarr | `http://192.168.1.100:8265` |
| Maintainerr | `http://192.168.1.100:8787` |
| Portainer | `https://192.168.1.100:9443` |
| SubgenAI | `http://192.168.1.100:9000` |
| NPM Admin | `http://192.168.1.100:18081` |
| Bot API | `http://localhost:3555` |

---

## Archivos de Configuración Importantes

| Archivo | Propósito |
|---------|-----------|
| `/home/chae/jellyfin-whatsapp-bot/.env` | API keys del bot |
| `/home/chae/jellyfin-whatsapp-bot/src/server.js` | Servidor Express del bot |
| `/home/chae/jellyfin-whatsapp-bot/src/commands/index.js` | Enrutador de comandos WhatsApp |
| `/home/chae/scripts/check_es_subs.py` | Script principal de subtítulos |
| `/home/chae/scripts/check_es_subs.env` | API keys del script de subs |
| `/home/chae/scripts/omdb_cache.json` | Cache de IMDB IDs de episodios |
| `/home/chae/services/*/docker-compose.yml` | Config de cada servicio Docker |
| `/etc/systemd/system/cloudflared.service` | Servicio del túnel Cloudflare |

---

## Mapa de Puertos

| Puerto | Servicio | Container |
|--------|----------|-----------|
| 3001 | Uptime Kuma | chae-uptime-kuma |
| 3555 | WhatsApp Bot | jellyfin-whatsapp-bot |
| 5055 | Jellyseerr | chae-jellyseerr |
| 5432 | PostgreSQL | chae-postgres |
| 6767 | Bazarr | chae-bazarr |
| 6881 TCP/UDP | qBittorrent (torrents) | chae-qbittorrent |
| 7878 | Radarr | chae-radarr |
| 8080 | qBittorrent WebUI | chae-qbittorrent |
| 8096 | Jellyfin HTTP | chae-jellyfin |
| 8191 | Flaresolverr | chae-flaresolverr |
| 8265 | Tdarr WebUI | chae-tdarr |
| 8787 | Maintainerr | chae-maintainerr |
| 8920 | Jellyfin HTTPS | chae-jellyfin |
| 8989 | Sonarr | chae-sonarr |
| 9000 | SubgenAI | subgenai |
| 9443 | Portainer SSL | portainer |
| 9696 | Prowlarr | chae-prowlarr |
| 18080 | NPM HTTP | nginx-proxy-manager |
| 18081 | NPM Admin | nginx-proxy-manager |
| 18443 | NPM HTTPS | nginx-proxy-manager |

---

## Backup

Los backups corren cada día a las 3am vía `/home/chae/scripts/backup-stack.sh`:

- **Destino**: `/mnt/media2/backups/stack/`
- **Espejo**: copia rsync a `/mnt/media1/backups/stack/` (disco físico independiente de la rama mergerfs)
- **Notificación**: WhatsApp en fallo (trap ERR + `die`) y resumen al finalizar
- **Qué incluye**:
  - Dump de PostgreSQL (`chae` database, verificado con gzip -t + cabecera pg_dumpall)
  - Snapshot online consistente de la SQLite de Jellyfin (quick_check)
  - Tarballs de configs de todos los servicios Docker (tolera archivos cambiados en vivo)
- **Retención**: 14 días (se borran los más viejos automáticamente)
- **Lock**: `flock` evita corridas solapadas

## Docker: Hardening

- Imágenes pineadas por digest (`repo@sha256:...`) en todos los compose; recrear no cambia versión
- Healthchecks propios en arrs (`/ping`), Jellyfin (`/health`), Jellyseerr, AdGuard, Postgres (`pg_isready`), Maintainerr
- Límites de memoria: tdarr-node 8g, tdarr 2g, subgenai 4g
- Postgres: credenciales en `services/postgres/.env` (nunca en el compose); puerto solo en localhost
- Maintainerr y Portainer tienen compose propio bajo `services/` (antes eran contenedores sueltos irreproducibles)
- Sin contenedores huérfanos (watchtower y `-pre-*` eliminados)

## Logs

- Rotación diaria 4:30am vía logrotate nivel usuario: `~/.config/logrotate/chae.conf` (estado en `~/.local/state/logrotate.status`)
- Aplica a `scripts/*.log` y `auto_translate.log`: rota a partir de 5MB, conserva 3 comprimidos

---

## Notas de Seguridad

- Los archivos `.env` tienen permisos `600` (solo el dueño puede leerlos)
- El túnel Cloudflare no expone puertos directamente
- Webhooks de Radarr/Sonarr requieren token secreto
- Comandos admin requieren verificación via `/registraradmin` (código: `0420`)
- WhatsApp bot solo responde a mensajes del número del dueño
- Scripts que envían notificaciones requieren `x-update-token`
- Las contraseñas y API keys están distribuidas en archivos `.env` — nunca committeadas a git
- **Importante:** después de clonar, cambiar todas las `CHANGEME` por tus valores reales
