# Chae Media Stack

Stack de streaming multimedia auto-hosteado con integración de bot de WhatsApp.

## Componentes

- **Bot de WhatsApp** (`jellyfin-whatsapp-bot/`) — Bot en Node.js usando Baileys para administrar medios desde WhatsApp
- **14 servicios Docker** (`services/`) — Jellyfin, Radarr, Sonarr, Bazarr, Prowlarr, qBittorrent, Jellyseerr, Tdarr, Flaresolverr, SubgenAI, Postgres, Uptime Kuma, Homepage, AdGuard
- **Scripts de automatización** (`scripts/`) — Pipeline de subtítulos, backups, recuperación de montura, actualizaciones, dashboard

## Arquitectura

```
                    Internet
                        |
                   [Cloudflare Tunnel]
                        |
                   [Prowlarr] (indexadores)
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
```

## Flujos de Datos

### 1. Agregar contenido desde WhatsApp

```
Usuario envía /peli Inception
  → Bot busca en Radarr películas que coinciden
  → Bot muestra resultados y pide confirmación
  → Usuario confirma con "peli 1"
  → Bot agrega a Radarr con el perfil de calidad configurado
  → Radarr busca en los indexadores de Prowlarr
  → Prowlarr encuentra torrents que coinciden
  → Radarr envía el mejor match a qBittorrent
  → qBittorrent descarga a /mnt/media2/downloads/torrents
  → Radarr importa el archivo a /mnt/media/movies/
  → Jellyfin detecta el nuevo contenido en la biblioteca
  → Radarr envía webhook al bot: "✅ Inception (2010) descargada"
  → Bot reenvía la notificación a WhatsApp
```

### 2. Series con selección de temporada

```
Usuario envía /serie Breaking Bad
  → Bot busca en Sonarr
  → Bot muestra resultados
  → Usuario confirma con "serie 1"
  → Bot pregunta qué temporada monitorear
  → Usuario selecciona temporada 1
  → Sonarr agrega la serie, monitorea solo temporada 1
  → Sonarr dispara búsqueda de episodios de temporada 1
  → Episodios se descargan via Prowlarr → qBittorrent → importación
  → Sonarr notifica al bot via webhook por cada descarga
```

### 3. Subtítulos automáticos (cada 6h)

```
cron ejecuta check_es_subs.py
  → Obtiene todas las películas y series de Bazarr
  → Por cada item sin subtítulos ES:
      1. Prueba providers de Bazarr (opensubtitlescom, legendasdivx, podnapisi, subf2m, subdl)
      2. Si no encuentra: busca en OpenSubtitles REST API por IMDB ID
         - Series: filtra por season/episode
         - Si no encuentra: consulta OMDb API por IMDB del episodio, reintenta
      3. Si aún falta (solo películas): descarga sub EN → traduce via DeepL → guarda como .es.srt
  → Envía notificación WhatsApp con resumen de descargas
```

### 4. Transcodificación (Tdarr)

```
Tdarr monitorea /mnt/media en busca de archivos nuevos
  → Aplica workflow de conversión a HEVC
  → Elimina pistas de audio/subtítulos no deseadas
  → Remueve subtítulos PGS/DVD (conserva solo los basados en texto)
  → Ahorra espacio manteniendo calidad
  → Jellyfin puede reproducir directamente los archivos HEVC
```

### 5. Backup diario (3am)

```
cron ejecuta backup-stack.sh
  → Dump de PostgreSQL (todas las bases) → .sql.gz comprimido
  → Archiva configs de: jellyfin, sonarr, radarr, bazarr, prowlarr, qbittorrent, jellyseerr, tdarr, uptime-kuma
  → Guarda en /mnt/media2/backups/stack/
  → Limpia archivos con más de 14 días
```

### 6. Recuperación de montura (cada 2min)

```
cron ejecuta media-mount-recovery.sh
  → Verifica si /mnt/media está montado y accesible
  → Si está sano: registra estado, sale
  → Si falta: registra estado, espera
  → En la próxima verificación, si se recuperó desde "missing" → reinicia Radarr, Sonarr, Bazarr, Jellyfin, qBittorrent
```

## Bot de WhatsApp

El bot se conecta a WhatsApp Web usando la librería `@whiskeysockets/baileys` (API no oficial). Corre como contenedor Docker y solo responde mensajes del número del dueño.

### Cómo funciona

1. Al iniciar, genera un código QR si no hay sesión válida en `auth/`
2. Escaneá el QR desde WhatsApp (Dispositivos vinculados) para emparejar
3. Solo responde a mensajes de `WHATSAPP_OWNER`
4. Los mensajes entrantes se comparan con patrones de comando en `src/commands/index.js`
5. El bot consulta Radarr/Sonarr/Bazarr/Jellyseerr/qBittorrent via sus APIs
6. Las selecciones pendientes se guardan en memoria hasta confirmar o cancelar
7. Los webhooks de Radarr/Sonarr disparan notificaciones proactivas

### Comandos

| Comando | Descripción |
|---------|-------------|
| `/ayuda` o `/help` | Muestra todos los comandos |
| `/status` | Estado del sistema: conexiones, biblioteca, descargas, disco |
| `/subs` o `/subtitulos` | Estado de subtítulos ES: películas/series con y sin |
| `/traducir [película]` | Traduce subtítulos EN→ES vía DeepL |
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
| `/eliminar [nombre]` | **(admin)** Eliminar de biblioteca + disco + torrents |
| `/refrescar [nombre]` | **(admin)** Refrescar metadatos + rescan en Sonarr |
| `/reiniciar` | **(admin)** Reinicia el bot |
| `/reconectar` | **(admin)** Reconecta WhatsApp Web |
| `/limpiartorrents` | **(admin)** Limpia torrents completados de qBittorrent |
| `/registraradmin` | Registra al usuario como admin (código: `0420`) |
| `/cancelar` | Cancela el flujo actual |
| `/repetir` | Repite la página actual de resultados |
| `/mas` | Siguiente página de resultados |

### Webhooks

| Endpoint | Token | Descripción |
|----------|-------|-------------|
| `POST /webhook/radarr?token=<RADARR_SECRET>` | Configurable | Notifica películas descargadas |
| `POST /webhook/sonarr?token=<SONARR_SECRET>` | Configurable | Notifica episodios descargados |
| `POST /notify/system-update` | Header: `x-update-token` | Recibe notificaciones de scripts cron |

## Redes

### Redes Docker

Dos redes Docker conectan los servicios:

```
qbittorrent_default:  radarr, sonarr, bazarr, prowlarr, jellyseerr, qbittorrent,
                      flaresolverr, jellyfin-whatsapp-bot, tdarr, tdarr-node, uptime-kuma, homepage
jellyfin_default:     jellyfin, uptime-kuma
```

Los servicios se comunican usando nombres cortos de contenedor como DNS (ej: `http://radarr:7878`).

### Túnel Cloudflare

Ningún puerto está expuesto directamente a internet. Un túnel Cloudflare (`cloudflared`) maneja el ingreso seguro:

- Corre como servicio systemd con actualizaciones automáticas
- Configurado via dashboard de Cloudflare (sin archivos de configuración locales)
- Protocolo: QUIC, ubicación: Ezeiza (Argentina)

## Estructura de Almacenamiento

```
/mnt/media/              (pool mergerfs: media1 + media2, ~1.2T)
  /movies/               → Biblioteca de películas (administrada por Radarr)
  /series/               → Biblioteca de series (administrada por Sonarr)
  /anime/                → Anime
  /music/                → Música
  /downloads/            → Descargas compartidas
    /incomplete/         → Descargas parciales
    /torrents/           → Torrents completados (qBittorrent)
  /backups/              → Backups automáticos

/mnt/media1/             → HDD 465G (NTFS)
/mnt/media2/             → HDD 699G (NTFS)
  /downloads/            → Destino de descargas de qBittorrent
  /backups/stack/        → Destino de backups diarios
```

## Pipeline de Subtítulos

### check_es_subs.py (Cada 6h)

Script principal que verifica que todo el contenido tenga subtítulos en español.

**Archivo:** `scripts/check_es_subs.py`
**Config:** `scripts/check_es_subs.env`
**Cron:** Cada 6 horas

1. Consulta Bazarr por todas las películas y series
2. Verifica si cada item tiene subtítulos ES (códigos: `es`, `ea`, `sp`)
3. Si faltan, prueba fuentes en orden:
   - Providers de Bazarr (búsqueda directa de subtítulos)
   - OpenSubtitles REST API (por IMDB ID)
   - Para episodios: OMDb API como fallback para encontrar IMDB del episodio
   - Para películas: descarga sub EN → traducción DeepL → guarda como `.es.srt`
4. Envía notificación WhatsApp si hubo descargas o errores

### auto_translate.py (Cada 10min)

Traduce subtítulos EN descargados recientemente a ES usando Gemini AI.

**Archivo:** `services/bazarr/auto_translate.py`

## Servicios

| Servicio | Puerto | Descripción | Config |
|----------|--------|-------------|--------|
| Jellyfin | 8096 | Servidor de streaming (películas, series, anime, música) | VAAPI GPU |
| Radarr | 7878 | Automatización de biblioteca de películas | - |
| Sonarr | 8989 | Automatización de biblioteca de series | - |
| Prowlarr | 9696 | Gestor de indexadores/trackers | - |
| Bazarr | 6767 | Descargador automático de subtítulos (prioridad ES) | - |
| Tdarr | 8265/8266 | Transcodificación y remux (HEVC, limpieza de streams) | VAAPI GPU |
| qBittorrent | 8080/6881 | Cliente BitTorrent | network=host |
| Jellyseerr | 5055 | Solicitudes y descubrimiento de contenido | - |
| Flaresolverr | 8191 | Bypass de Cloudflare para indexadores | - |
| WhatsApp Bot | 3555 | Interfaz de administración via WhatsApp | Baileys |
| PostgreSQL | 5432 | Base de datos para servicios del stack | - |
| Uptime Kuma | 3001 | Monitoreo de salud y uptime | - |
| Portainer | 9443 | Administración de contenedores Docker | SSL |
| Homepage | 3003 | Dashboard personalizado | - |
| AdGuard | - | Bloqueo de anuncios DNS | - |
| Maintainerr | 8787 | Limpieza automática de contenido | - |
| SubgenAI | 9000 | Generación de subtítulos con IA | - |

## Automatización

| Cada | Script | Descripción |
|------|--------|-------------|
| 2 minutos | `media-mount-recovery.sh` | Verifica montura de `/mnt/media`, reinicia servicios si se recuperó |
| 5 minutos | `generate-stack-dashboard-data.sh` | Genera cache JSON para dashboard |
| 10 minutos | `auto_translate.py` | Traduce subs EN a ES via Gemini |
| 6 horas | `check_es_subs.py` | Verifica y descarga subtítulos ES faltantes |
| 3am daily | `backup-stack.sh` | Dump PostgreSQL + configs de servicios (retención 14 días) |
| 4am daily | Watchtower | Actualiza automáticamente todos los contenedores Docker |

## Seguridad

- Sin puertos expuestos directamente — Cloudflare Tunnel maneja todo el ingreso
- El bot solo responde al número del dueño configurado
- Comandos admin requieren verificación via `/registraradmin` (código: `0420`)
- Los endpoints webhook requieren tokens secretos
- Los archivos `.env` tienen permisos `600` y están excluidos del control de versiones
- Las API keys y contraseñas están distribuidas en archivos `.env` (nunca committeadas)
- Todos los servicios corren con `PUID=1000`, `PGID=1000` (no-root dentro de los contenedores)
- Zona horaria: `America/Argentina/Buenos_Aires`

## Requisitos

- Docker & Docker Compose
- Node.js 20 (para el bot de WhatsApp)
- Python 3 (para los scripts de subtítulos)
- Linux con filesystem `ext4` o `ntfs`

## Inicio Rápido

```bash
git clone https://github.com/LautaroPiugh/chae-media-stack.git
cd chae-media-stack

# Configurar bot de WhatsApp
cp jellyfin-whatsapp-bot/.env.example jellyfin-whatsapp-bot/.env
# Editar .env con tus API keys y URLs

# Iniciar un servicio (ejemplo: Jellyfin)
cd services/jellyfin
docker compose up -d

# Iniciar el bot de WhatsApp
cd ../../jellyfin-whatsapp-bot
docker compose up -d --build
```

## Lecturas Adicionales

- [Documentación completa del sistema](SISTEMA.md) — hardware, todos los servicios, cron, backups, seguridad
- [Referencia de servicios](services/README.md) — detalles por servicio, arquitectura, optimizaciones
- [Bot de WhatsApp](jellyfin-whatsapp-bot/README.md) — comandos, webhooks, troubleshooting

## Licencia

MIT
