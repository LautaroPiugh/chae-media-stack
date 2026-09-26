# Sistema Media Stack Personal

## Descripción General

Servidor multimedia argentino con 15+ servicios Docker, bot de WhatsApp, túnel Cloudflare, y pipeline automático de subtítulos. Corre en una PC con Ubuntu (hostname: `chae`).

---

## Hardware & Almacenamiento

| Componente | Detalle |
|-----------|---------|
| CPU | x86_64 |
| RAM | 32GB (25,6G disponibles en uso normal) |
| Disco sistema | SSD 220G (LVM ext4, 20% usado) — by-id estable `ata-HS-SSD-WAVE_S__240G_FZ8257638` (resuelve a `/dev/sdg` en la configuración actual) |
| Disco datos 1 | HDD 1TB USB → `/mnt/media1` (ext4) — espejo de backups (`backups/stack/`) + rescate de sdf (`chae-archive/sdf-2026`, 5.5G de contabilidad) |
| Disco datos 2 | HDD 1TB USB → `/mnt/media2` (ext4) — descargas (`downloads/`) y backups principales |
| Disco datos 3 | HDD 1TB WD → `/mnt/media3` (ext4) — biblioteca activa (series/películas) |
| Disco datos 4 | HDD 1TB Seagate → `/mnt/media4` (ext4) — biblioteca de películas + destino de contenido nuevo |
| Disco datos 5 | HDD 1TB USB (ex-sdf) → `/mnt/media5` (ext4) — rama libre del pool (sep 2026) |
| Disco datos 6 | HDD 1TB Seagate (ZN1NCYJL) → `/mnt/media6` (ext4) — rama libre del pool (sep 2026) |
| Pool mergerfs | `/mnt/media` = media1 + media2 + media3 + media4 + media5 + media6, ~5,4T total |
| DB | Radarr/Sonarr/Prowlarr en PostgreSQL (chae-postgres, sep 2026); Bazarr/Jellyfin siguen en SQLite |

> **Nota sep 2026:** los discos NTFS viejos (media1 465G, media2 699G) se reemplazaron por
> 1TB ext4. Los UUIDs de las ramas viven en `/home/chae/stack/.media-branches.conf`, que leen
> `media-mount-recovery.sh`, `media-status.sh`, `chaetop` y `media-pool-watchdog.sh`.
> Para agregar/quitar discos: `scripts/add-media-disk.sh` (ver abajo).

### Pool mergerfs (`/mnt/media`)

Combina los seis discos. Política: `mfs` (most free space — escribe en el disco con más espacio libre). Mínimo 20G libres por disco. El contenido nuevo (descargas e importaciones de Radarr/Sonarr) aterriza en el disco con más espacio.

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

`/home/chae/stack/scripts/media-mount-recovery.sh` corre cada 2 minutos vía cron. Valida cada rama
(leídas de `.media-branches.conf`) y el pool mergerfs; si algo no está sano detiene los contenedores
consumidores, y los reinicia solo cuando todo vuelve a estar correcto.

`/home/chae/stack/scripts/media-pool-watchdog.sh` (systemd `media-pool-watchdog.service` + `.timer`,
cada 2 minutos, como root) remonta ramas caídas y el pool, y loguea en
`/var/log/media-pool-watchdog.log`. Se dispara a mano desde el popup de tmux (`prefix + R`)
vía `stack-repair.sh`.

### Gestión de discos

- `fix-media-mounts.sh` (repo root, `sudo bash`) — reparación completa tras cambiar discos:
  inspecciona `sdf` en read-only, formatea los discos nuevos como GPT+ext4, escribe
  `.media-branches.conf`, la sección `# BEGIN media-pool` de `/etc/fstab`, el drop-in
  `docker.service.d/media-mounts.conf`, monta ramas + pool y crea directorios base.
  Identifica discos por `by-path` (puerto físico) y aborta si el disco tiene algo montado,
  contiene `/`/`/boot`/`/boot/efi`, es un PV de LVM o mide 223,6G (el del sistema).
- `scripts/add-media-disk.sh` (con `sudo`) — agrega un disco nuevo como la próxima rama `mediaN`:
  lo formatea, lo suma a config/fstab/drop-in y remonta el pool. Mismo seguro que arriba.
- `check-restore-sde.sh` / `rescue-and-format-sdf.sh` / `fix-ttyd-panel.sh` — herramientas puntuales
  de la movida de discos de sep 2026 (quedan por si se repite).

### Rescate de sdf (sep 2026)

El disco `sdf` era un Ubuntu viejo con `/home/contabilidad` (9.632 documentos: Balanzas, Tesoro,
SIPAF, `Contraseñas-Chrome.csv`, `Copia Datos Disco Viejo`, `Backup 01 diciembre 2025`). Se copió
completo a `/mnt/media/chae-archive/sdf-2026/` (5.5G, verificado 817/817 docs, 10432/10432 escritorio)
y recién después se formateó como `media5`.

### Limpieza manual (botón del panel)

El panel Homepage (192.168.0.200:3003) tiene la tarjeta **"Limpieza del Stack"** (grupo Mantenimiento). El clic dispara la limpieza vía `chae-cleanup-api.service` (systemd, puerto 3655, script `/home/chae/stack/scripts/cleanup-stack.sh`): purga cachés de transcode/logs de Jellyfin, caché de Tdarr (`/mnt/media2/downloads/tdarr-cache`) y prune de imágenes Docker colgantes; reporta espacio liberado y avisa por WhatsApp.

---

## Servicios Docker (22 containers)

Todos corren con `TZ=America/Argentina/Buenos_Aires`. De los 22 contenedores, 9 admiten `PUID`/`PGID` y las tienen configuradas: son los únicos que crean archivos como `1000:1000` (`chae`). Los demás no reciben esas variables. AdGuard y Scrutiny corren como root, y Scrutiny además es `privileged`. En los que sí las soportan, esto tampoco implica non-root: el PID 1 sigue siendo root y las imágenes de linuxserver bajan solo el proceso del servicio a uid 1000.

### Streaming & Visualización

| Servicio | Puerto | URL | Imagen |
|----------|--------|-----|--------|
| **Jellyfin** | 8096 | `http://192.168.0.200:8096` | `lscr.io/linuxserver/jellyfin` |
| **Jellyseerr** | 5055 | `http://192.168.0.200:5055` | `ghcr.io/seerr-team/seerr` |
| **Uptime Kuma** | 3001 | `http://192.168.0.200:3001` | `louislam/uptime-kuma` |

### Gestión de Medios (Arr Stack)

| Servicio | Puerto | URL Interna | URL Host | Imagen |
|----------|--------|-------------|----------|--------|
| **Radarr** | 7878 | `http://radarr:7878` | `http://192.168.0.200:7878` | `lscr.io/linuxserver/radarr` |
| **Sonarr** | 8989 | `http://sonarr:8989` | `http://192.168.0.200:8989` | `lscr.io/linuxserver/sonarr` |
| **Bazarr** | 6767 | `http://bazarr:6767` | `http://192.168.0.200:6767` | `lscr.io/linuxserver/bazarr` |
| **Prowlarr** | 9696 | `http://prowlarr:9696` | `http://192.168.0.200:9696` | `lscr.io/linuxserver/prowlarr` |
| **qBittorrent** | 8080 | `http://qbittorrent:8080` | `http://192.168.0.200:8080` | `lscr.io/linuxserver/qbittorrent` |
| **Flaresolverr** | 8191 | `http://flaresolverr:8191` | - | `ghcr.io/flaresolverr/flaresolverr` |

### Utilidades

| Servicio | Puerto | URL | Imagen |
|----------|--------|-----|--------|
| **WhatsApp Bot** | 3555 | `http://localhost:3555` | `jellyfin-whatsapp-bot:latest` |
| **Tdarr** | 8265 | `http://192.168.0.200:8265` | `ghcr.io/haveagitgat/tdarr` |
| **Maintainerr** | 8787 | `http://192.168.0.200:8787` (mapped desde 6246) | `ghcr.io/maintainerr/maintainerr` |
| **Portainer** | 9443 (SSL) | `https://127.0.0.1:9443` (solo loopback, no accesible desde la LAN) | `portainer/portainer-ce` |
| **SubgenAI** | 9000 | `http://192.168.0.200:9000` | `mccloud/subgen` |
| **PostgreSQL** | 5432 | `127.0.0.1:5432` (solo loopback) | `postgres:16` |
| **Recyclarr** | - | interno | `ghcr.io/recyclarr/recyclarr:8` |
| **qBitManage** | - | interno | `docker.io/bobokun/qbit_manage:latest` |
| **AdGuard** | 3002 (web), 53 TCP/UDP (DNS) | `http://192.168.0.200:3002` | `adguard/adguardhome` |
| **Dozzle** | 8081 | `http://192.168.0.200:8081` | `amir20/dozzle:latest` |
| **Homepage** | 3003 | `http://192.168.0.200:3003` | `ghcr.io/gethomepage/homepage` |
| **Scrutiny** | 8082 | `http://192.168.0.200:8082` | `ghcr.io/analogj/scrutiny:latest-omnibus` |

### Red Docker

Hay una red principal `qbittorrent_default` que conecta la mayoría de los servicios. Los nombres DNS entre containers son los nombres cortos (ej: `radarr`, `sonarr`, `bazarr`).

```
qbittorrent_default:  radarr, sonarr, bazarr, prowlarr, jellyseerr, qbittorrent,
                      flaresolverr, jellyfin-whatsapp-bot, tdarr, tdarr-node, uptime-kuma
jellyfin_default:     jellyfin, uptime-kuma
```

---

## Túnel Cloudflare

El servidor es accesible desde internet mediante **Cloudflare Tunnel**, que es el camino de entrada de las UIs administrativas sin exponerlas directamente a Internet. Queda salvo `6881` de qBittorrent, que escucha en todas las interfaces a propósito para aceptar peers entrantes y cuya exposición real depende del firewall del host y del NAT del router.

```bash
systemctl status cloudflared
# PID activo, protocolo quic, ubicación Ezeiza (eze02)
```

El túnel corre como servicio systemd con un token de Cloudflare. No hay archivos de configuración locales — se administra desde el dashboard de Cloudflare.

Auto-update: `cloudflared-update.service` corre `cloudflared update` y reinicia si hay versión nueva.

---

## WhatsApp Bot

Bot personal para administrar el media stack desde WhatsApp. Usa `@whiskeysockets/baileys` (WhatsApp Web).

**Código**: `/home/chae/stack/jellyfin-whatsapp-bot/`
**Docker Compose**: `/home/chae/stack/jellyfin-whatsapp-bot/docker-compose.yml`
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
| `/registraradmin` | Registra al usuario como admin (código configurado localmente) |
| `/cancelar` | Cancela el flujo actual |
| `/repetir` | Repite la página actual de resultados |
| `/mas` | Siguiente página de resultados |

### Admin Verification

Para usar comandos admin, enviar `/registraradmin` una vez desde el número del dueño. El código de registro se configura localmente en el bot.

### Webhook Endpoints

| Endpoint | Token | Descripción |
|----------|-------|-------------|
| `POST /webhook/radarr?token=<RADARR_SECRET>` | Configurable en `.env` | Notifica películas descargadas |
| `POST /webhook/sonarr?token=<SONARR_SECRET>` | Configurable en `.env` | Notifica episodios descargados |
| `POST /notify/system-update` | Header: `x-update-token` | Recibe notificaciones del script de subs |

### Configuración

Archivo: `/home/chae/stack/jellyfin-whatsapp-bot/.env`

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

**Archivo**: `/home/chae/stack/scripts/check_es_subs.py`
**ENV**: `/home/chae/stack/scripts/check_es_subs.env`
**Log**: `/home/chae/stack/scripts/check_es_subs.log`
**Cron**: Cada 6 horas (`0 */6 * * *`)
**Cache OMDb**: `/home/chae/stack/scripts/omdb_cache.json`

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
python3 /home/chae/stack/scripts/check_es_subs.py --translate-movie "Título de película"
```

### Script Secundario: `auto_translate.py`

**Archivo**: `/home/chae/stack/services/bazarr/auto_translate.py`
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
| 2 minutos | `/home/chae/stack/scripts/media-mount-recovery.sh` | Verifica montura de `/mnt/media`, reinicia servicios si se recuperó |
| 2 minutos | `media-pool-watchdog.timer` | Remonta ramas caídas y el pool (systemd, root) |
| 5 minutos | `/home/chae/stack/scripts/generate-stack-dashboard-data.sh` | Genera cache JSON para dashboard |
| 10 minutos | `python3 /home/chae/stack/services/bazarr/auto_translate.py` | Traduce subs EN bjados por Bazarr vía Gemini |
| 6 horas | `python3 /home/chae/stack/scripts/check_es_subs.py` | Verifica y descarga subtítulos ES faltantes |
| 3am daily | `/home/chae/stack/scripts/backup-stack.sh` | Backup PostgreSQL + configs a `/mnt/media2/backups/stack/` (retención 14 días) |
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

> Las URLs usan la **IP LAN configurada actualmente** (`192.168.0.200`), no una IP estática garantizada. Si el router entrega esa dirección por DHCP, conviene fijar una reserva antes de depender de estas URLs.

| Servicio | URL Local |
|----------|-----------|
| Jellyfin | `http://192.168.0.200:8096` |
| Radarr | `http://192.168.0.200:7878` |
| Sonarr | `http://192.168.0.200:8989` |
| Bazarr | `http://192.168.0.200:6767` |
| Prowlarr | `http://192.168.0.200:9696` |
| qBittorrent | `http://192.168.0.200:8080` |
| Jellyseerr | `http://192.168.0.200:5055` |
| Uptime Kuma | `http://192.168.0.200:3001` |
| Tdarr | `http://192.168.0.200:8265` |
| Maintainerr | `http://192.168.0.200:8787` |
| Portainer | `https://127.0.0.1:9443` (solo loopback) |
| SubgenAI | `http://192.168.0.200:9000` |
| AdGuard | `http://192.168.0.200:3002` |
| Dozzle | `http://192.168.0.200:8081` |
| Homepage | `http://192.168.0.200:3003` |
| Scrutiny | `http://192.168.0.200:8082` |
| Bot API | `http://localhost:3555` |

---

## Archivos de Configuración Importantes

| Archivo | Propósito |
|---------|-----------|
| `/home/chae/stack/jellyfin-whatsapp-bot/.env` | API keys del bot |
| `/home/chae/stack/jellyfin-whatsapp-bot/src/server.js` | Servidor Express del bot |
| `/home/chae/stack/jellyfin-whatsapp-bot/src/commands/index.js` | Enrutador de comandos WhatsApp |
| `/home/chae/stack/scripts/check_es_subs.py` | Script principal de subtítulos |
| `/home/chae/stack/scripts/check_es_subs.env` | API keys del script de subs |
| `/home/chae/stack/scripts/omdb_cache.json` | Cache de IMDB IDs de episodios |
| `/home/chae/stack/services/*/docker-compose.yml` | Config de cada servicio Docker |
| `/etc/systemd/system/cloudflared.service` | Servicio del túnel Cloudflare |

---

## Mapa de Puertos

| Puerto | Servicio | Container |
|--------|----------|-----------|
| 3001 | Uptime Kuma | chae-uptime-kuma |
| 53 TCP/UDP | AdGuard (DNS) | chae-adguard |
| 3002 | AdGuard WebUI | chae-adguard |
| 3003 | Homepage | chae-homepage |
| 3555 | WhatsApp Bot | jellyfin-whatsapp-bot |
| 5055 | Jellyseerr | chae-jellyseerr |
| 5432 | PostgreSQL — solo loopback | chae-postgres |
| 6767 | Bazarr | chae-bazarr |
| 6881 TCP/UDP | qBittorrent (torrents) | chae-qbittorrent |
| 7878 | Radarr | chae-radarr |
| 8080 | qBittorrent WebUI | chae-qbittorrent |
| 8081 | Dozzle | chae-dozzle |
| 8082 | Scrutiny | chae-scrutiny |
| 8096 | Jellyfin HTTP | chae-jellyfin |
| 8191 | Flaresolverr | chae-flaresolverr |
| 8265 | Tdarr WebUI | chae-tdarr |
| 8787 | Maintainerr | chae-maintainerr |
| 8920 | Jellyfin HTTPS — declarado en el compose, **no publicado** | chae-jellyfin |
| 8989 | Sonarr | chae-sonarr |
| 9000 | SubgenAI | subgenai |
| 9443 | Portainer SSL — solo loopback | portainer |
| 9696 | Prowlarr | chae-prowlarr |

---

## Backup

Los backups corren cada día a las 3am vía `/home/chae/stack/scripts/backup-stack.sh`:

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

- Imágenes pineadas por digest (`repo@sha256:...`) en los compose de servicios; recrear no cambia versión. Excepción: `jellyfin-whatsapp-bot` se construye localmente desde su `Dockerfile` y usa el tag mutable `:latest`
- Healthchecks propios en arrs (`/ping`), Jellyfin (`/health`), Jellyseerr, AdGuard, Postgres (`pg_isready`), Maintainerr
- Límites de memoria: tdarr-node 8g, tdarr 2g, subgenai 8g
- Postgres: hoy NO hay `services/postgres/.env`; la contraseña vive como valor literal en `services/postgres/docker-compose.override.yml` (el compose principal no la trae). Puerto 5432 publicado solo en loopback. Pendiente: mover la credencial a un `.env` y dejarla referenciada
- Maintainerr y Portainer tienen compose propio bajo `services/` (antes eran contenedores sueltos irreproducibles)
- Sin contenedores huérfanos (watchtower y `-pre-*` eliminados)

## Logs

- Rotación diaria 4:30am vía logrotate nivel usuario: `~/.config/logrotate/chae.conf` (estado en `~/.local/state/logrotate.status`)
- Aplica a `scripts/*.log` y `auto_translate.log`: rota a partir de 5MB, conserva 3 comprimidos

---

## Notas de Seguridad

- Los archivos `.env` tienen permisos `600` (solo el dueño puede leerlos)
- Las UIs administrativas no están publicadas directamente a internet: el túnel Cloudflare es su camino de entrada. Excepción: `6881` de qBittorrent, cuya exposición depende del firewall y del NAT
- Webhooks de Radarr/Sonarr requieren token secreto
- Comandos admin requieren verificación via `/registraradmin` (código configurado localmente)
- WhatsApp bot solo responde a mensajes del número del dueño
- Scripts que envían notificaciones requieren `x-update-token`
- Las contraseñas y API keys están distribuidas en archivos `.env` — nunca committeadas a git
- **Importante:** después de clonar, cambiar todas las `CHANGEME` por tus valores reales
