# Jellyfin WhatsApp Bot

Bot personal de WhatsApp para tu servidor Jellyfin. Recibe notificaciones de Radarr/Sonarr y permite buscar y agregar contenido mediante comandos.

## ⚠️ Aviso importante

Este bot usa WhatsApp Web (Baileys). No es la API oficial de Meta.
- Puede requerir reescanear el QR si WhatsApp cierra sesión en otro dispositivo
- No usar para spam
- La sesión se guarda en la carpeta `auth/`

## Funcionalidades

- Recibir notificaciones cuando Radarr/Sonarr terminan de descargar
- Buscar y agregar películas a Radarr
- Buscar y agregar series a Sonarr (con selección de temporada)
- Ver cola de descargas activas
- Solicitar contenido via Jellyseerr
- Consultar y disparar traducción de subtítulos
- Explorar catálogo y obtener recomendaciones

## Requisitos

- Node.js 20
- Docker & Docker Compose
- pnpm
- Radarr (opcional)
- Sonarr (opcional)
- Bazarr (opcional)
- Jellyseerr (opcional)
- qBittorrent (opcional)

## Cómo funciona

1. El bot se conecta a WhatsApp Web usando la librería `@whiskeysockets/baileys`
2. Al iniciar por primera vez, genera un código QR para vincular con WhatsApp
3. Solo responde a mensajes del número del dueño configurado
4. Los mensajes entrantes se comparan con patrones de comando
5. El bot consulta las APIs de Radarr/Sonarr/Bazarr/Jellyseerr/qBittorrent
6. Las selecciones pendientes se guardan en memoria hasta confirmar o cancelar
7. Los webhooks de Radarr/Sonarr disparan notificaciones proactivas

## Instalación

```bash
git clone <url-del-repositorio>
cd jellyfin-whatsapp-bot
cp .env.example .env
```

## Configuración

Editá `.env` con tus datos:

```env
PORT=3555

WHATSAPP_OWNER=543425246122

JELLYFIN_URL=http://192.168.1.100:8096
JELLYFIN_API_KEY=
JELLYFIN_USER_ID=

RADARR_URL=http://192.168.1.100:7878
RADARR_API_KEY=
RADARR_ROOT_FOLDER=/movies
RADARR_QUALITY_PROFILE_ID=1
RADARR_MINIMUM_AVAILABILITY=released
RADARR_SECRET=

SONARR_URL=http://192.168.1.100:8989
SONARR_API_KEY=
SONARR_ROOT_FOLDER=/series
SONARR_QUALITY_PROFILE_ID=1
SONARR_LANGUAGE_PROFILE_ID=1
SONARR_SECRET=

SERVICE_NAME=Jellyfin WhatsApp Bot
```

### Cómo obtener las API keys

**Radarr:** Settings → General → API Key
**Sonarr:** Settings → General → API Key

## Ejecutar

### Con Docker

```bash
docker compose up -d --build
docker logs -f jellyfin-whatsapp-bot
```

### Sin Docker

```bash
pnpm install
pnpm start
```

## Escanear el QR

1. Revisá los logs: `docker logs -f jellyfin-whatsapp-bot`
2. Buscá el código QR en la salida
3. En WhatsApp: ⋮ → Dispositivos vinculados → Vincular un dispositivo
4. Escaneá el QR

## Comandos

Enviá estos comandos por WhatsApp:

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

### Agregar contenido con calidad preferida

```bash
/peli inception 4k       # Buscar y preferir calidad 4K
/peli inception 1080p    # Buscar y preferir calidad 1080p
```

### Ejemplos

```
/peli matrix
/serie breaking bad
/cola
peli 1
serie 2
```

## Configurar Webhooks

### Radarr

1. Settings → Connect → Add → Webhook
2. Nombre: `Jellyfin WhatsApp Bot`
3. URL: `http://TU_IP:3555/webhook/radarr`
   - Con secret: `http://TU_IP:3555/webhook/radarr?token=MI_SECRET`
4. Eventos: Download, Upgrade
5. Guardar

### Sonarr

1. Settings → Connect → Add → Webhook
2. Nombre: `Jellyfin WhatsApp Bot`
3. URL: `http://TU_IP:3555/webhook/sonarr`
   - Con secret: `http://TU_IP:3555/webhook/sonarr?token=MI_SECRET`
4. Eventos: Download, Upgrade
5. Guardar

## Probar los Endpoints

```bash
# Health check
curl http://localhost:3555/health

# Status
curl http://localhost:3555/status

# Probar webhook (sin auth)
curl -X POST http://localhost:3555/webhook/radarr \
  -H "Content-Type: application/json" \
  -d '{"eventType":"Download","movie":{"id":1,"title":"Test Movie","year":2024,"movieFile":{"id":1}}}'
```

## Verificación de Admin

Enviá `/registraradmin` una vez desde el número del dueño para habilitar los comandos de admin. La verificación persiste entre reinicios del bot.

## Estructura del Proyecto

```
jellyfin-whatsapp-bot/
  docker-compose.yml
  Dockerfile
  package.json
  .env.example
  README.md
  auth/                    # Sesión de WhatsApp (no borrar)
  src/
    server.js              # Express + endpoints webhook
    whatsapp.js            # Cliente WhatsApp (Baileys)
    config.js              # Configuración desde .env
    alerts.js              # Alertas periódicas del sistema
    commands/              # Manejadores de comandos (25 archivos)
    clients/               # Clientes API (Radarr, Sonarr, Bazarr, etc.)
    handlers/              # Manejadores de webhooks (Radarr, Sonarr, Uptime Kuma)
    store/                 # Selecciones y solicitudes pendientes en memoria
    utils/                 # Helpers (formateo, auth, disco, recomendaciones)
```

## Troubleshooting

### No aparece el QR
- Revisá los logs: `docker logs -f jellyfin-whatsapp-bot`
- El QR aparece solo al iniciar o si se pierde la sesión

### WhatsApp se desconecta
- Puede pasar si WhatsApp cierra sesión desde otro dispositivo
- Borrá el contenido de `auth/` y reescané el QR, o enviá `/reconectar`

### No llegan mensajes de WhatsApp
- Verificá que el número Owner esté bien en `.env`
- El bot solo responde a `WHATSAPP_OWNER`

### Webhooks no funcionan
- Verificá que la URL sea accesible desde Radarr/Sonarr
- Si usás secret, asegurate de agregarlo a la URL: `?token=MI_SECRET`

### Radarr/Sonarr no responden
- Verificá las URLs y API keys en `.env`
- Probá con: `curl -s http://TU_RADARR_URL:7878/api/v3/system/status -H "X-Api-Key: TU_KEY"`

## Detener el bot

```bash
docker compose down
```

O si corrés sin Docker: `Ctrl+C`

## Licencia

MIT
