# Jellyfin WhatsApp Notifier

Recibe webhooks de Radarr y Sonarr y envía notificaciones por WhatsApp cuando movies o episodios están disponibles en Jellyfin.

## Requisitos

- Docker y Docker Compose
- Tu número de WhatsApp (para recibir mensajes)
- Un servidor Jellyfin con Radarr y/o Sonarr configurados

## Instalación

1. Clonar o copiar el proyecto:

```bash
git clone <repo>
cd jellyfin-whatsapp-notifier
```

2. Copiar el archivo de ejemplo `.env`:

```bash
cp .env.example .env
```

3. Editar `.env` con tus datos:

```env
PORT=3555
WHATSAPP_TARGET=543425246122
JELLYFIN_URL=http://TU_IP_O_DOMINIO:8096
SERVICE_NAME=Jellyfin Notifier
RADARR_SECRET=
SONARR_SECRET=
```

4. Levantar el servicio:

```bash
docker compose up -d --build
```

5. Ver los logs y escanear el QR:

```bash
docker logs -f jellyfin-whatsapp-notifier
```

Cuando veas el QR en los logs, escanéalo con tu WhatsApp.

## Configuración

### Variables de entorno

| Variable | Descripción | Default |
|----------|-------------|---------|
| `PORT` | Puerto del servicio | `3555` |
| `WHATSAPP_TARGET` | Número destino (sin + ni espacios) | - |
| `JELLYFIN_URL` | URL de tu Jellyfin | - |
| `SERVICE_NAME` | Nombre del servicio | `Jellyfin Notifier` |
| `RADARR_SECRET` | Secret opcional para webhook de Radarr | - |
| `SONARR_SECRET` | Secret opcional para webhook de Sonarr | - |

## Endpoints

### GET /health

Verifica que el servicio esté activo:

```bash
curl http://localhost:3555/health
```

### GET /status

Verifica el estado de WhatsApp:

```bash
curl http://localhost:3555/status
```

### POST /webhook/radarr

Endpoint para Radarr. Ver [Configurar Radarr](#configurar-radarr).

### POST /webhook/sonarr

Endpoint para Sonarr. Ver [Configurar Sonarr](#configurar-sonarr).

## Configurar Radarr

1. Ir a **Settings → Connect**
2. Agregar un **Webhook**
3. Configurar:
   - **URL**: `http://IP_DEL_SERVIDOR:3555/webhook/radarr`
   - Si usas secret: `http://IP_DEL_SERVIDOR:3555/webhook/radarr?token=MI_SECRET`
4. **Eventos**: `On Download`, `On Upgrade`
5. Guardar

## Configurar Sonarr

1. Ir a **Settings → Connect**
2. Agregar un **Webhook**
3. Configurar:
   - **URL**: `http://IP_DEL_SERVIDOR:3555/webhook/sonarr`
   - Si usas secret: `http://IP_DEL_SERVIDOR:3555/webhook/sonarr?token=MI_SECRET`
4. **Eventos**: `On Download`, `On Upgrade`
5. Guardar

## Notas

- Baileys usa WhatsApp Web no oficialmente. Si WhatsApp cierra la sesión, puede requerir re-vincular el QR.
- La sesión se guarda en la carpeta `auth/` para reutilizarse en reinicios.
- Se incluye protección contra duplicados para evitar spam.

## Desarrollo

```bash
# Instalar dependencias
pnpm install

# Ejecución normal
pnpm start

# Ejecución con hot-reload
pnpm dev

# Ver logs de Docker
docker logs -f jellyfin-whatsapp-notifier

# Reiniciar
docker compose restart jellyfin-whatsapp-notifier
```

## Licencia

MIT