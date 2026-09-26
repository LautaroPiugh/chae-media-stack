# 🐯 Chae Media Stack

Stack de streaming multimedia auto-hosteado que corre en **chae-server**: descarga, gestiona, transcodifica y transmite películas, series, anime y música, controlable desde la web o desde **WhatsApp**.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Docker](https://img.shields.io/badge/Docker-compose-2496ED)
![Platform](https://img.shields.io/badge/platform-Linux-FCC624)

---

## Índice

- [Características](#características)
- [Arquitectura](#arquitectura)
- [Servicios](#servicios)
- [Instalación paso a paso](#instalación-paso-a-paso)
- [Bot de WhatsApp](#bot-de-whatsapp)
- [Flujos de datos](#flujos-de-datos)
- [Automatización](#automatización)
- [Almacenamiento](#almacenamiento)
- [Redes y acceso remoto](#redes-y-acceso-remoto)
- [Seguridad](#seguridad)
- [Actualización y mantenimiento](#actualización-y-mantenimiento)
- [Scripts útiles](#scripts-útiles)
- [Troubleshooting](#troubleshooting)
- [Documentación adicional](#documentación-adicional)
- [Licencia](#licencia)

---

## Características

- 🎬 **Streaming** con Jellyfin: películas, series, anime y música, con transcodificación por GPU (VAAPI Intel).
- 🤖 **Control por WhatsApp**: buscá, pedí y gestioná todo el stack con comandos desde tu celular.
- ⬇️ **Descargas automatizadas**: Prowlarr → Radarr/Sonarr → qBittorrent con importación y renombrado automático.
- 💬 **Subtítulos en español garantizados**: pipeline multi-fuente (Bazarr + OpenSubtitles + DeepL + Gemini AI) que busca, descarga y traduce subtítulos.
- 🔄 **Transcodificación inteligente**: Tdarr convierte a HEVC, limpia pistas innecesarias y ahorra espacio.
- 📊 **Dashboard** propio (Homepage) y monitoreo de salud (Uptime Kuma).
- 🔒 **Sin puertos expuestos a internet**: todo el ingreso vía Cloudflare Tunnel.
- 🗄️ **Backups diarios** automáticos con retención de 14 días.

## Arquitectura

```
                        Internet
                            │
                   [Cloudflare Tunnel]
                   (sin puertos abiertos)
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   [Jellyseerr]        [Jellyfin]         [Homepage]
   (solicitudes)       (streaming)        (dashboard)
        │                   ▲
        ▼                   │
┌──────────────────── *arr suite ────────────────────┐
│                                                    │
│  [Prowlarr] ← indexadores (+ Flaresolverr)          │
│      │                                             │
│      ├──► [Radarr] ──┐                             │
│      ├──► [Sonarr] ──┼──► [qBittorrent]            │
│      └──► [Bazarr]   │    (descargas)               │
│     (subtítulos)     │         │                    │
│                      ▼         ▼                    │
│              /mnt/media/movies·series               │
│                            │                        │
│                     [Tdarr + node]                  │
│                  (transcode HEVC)                   │
└────────────────────────────────────────────────────┘

[Jellyfin WhatsApp Bot] ⇄ Radarr · Sonarr · Bazarr · Jellyseerr · qBittorrent · Jellyfin
        ↕ cron/scripts
[check_es_subs.py] ⇄ Bazarr · OpenSubtitles · DeepL · OMDb
[subgenai] ⇄ Jellyfin (subtítulos whisper on-demand)

Soporte: [PostgreSQL] · [Uptime Kuma] · [Portainer] · [AdGuard Home] · [Maintainerr]
```

## Servicios

Casi todos los contenedores usan prefijo `chae-*` (ej: `chae-jellyfin`). Las tres excepciones son `subgenai`, `jellyfin-whatsapp-bot` y `portainer`, que usan su nombre de proyecto de Compose. Casi todos los puertos se publican solo en la IP LAN del server y en localhost. La excepción es qBittorrent, que además expone su puerto BitTorrent `6881` TCP/UDP en todas las interfaces (`0.0.0.0`).

| Servicio | Puerto | Descripción |
|----------|--------|-------------|
| **Jellyfin** | 8096 | Servidor de streaming (películas, series, anime, música) — VAAPI GPU |
| **Jellyseerr** | 5055 | Solicitudes y descubrimiento de contenido |
| **Radarr** | 7878 | Automatización de biblioteca de películas |
| **Sonarr** | 8989 | Automatización de biblioteca de series |
| **Prowlarr** | 9696 | Gestor centralizado de indexadores |
| **Bazarr** | 6767 | Descarga automática de subtítulos (prioridad ES) |
| **Tdarr** | 8265 | Transcodificación HEVC + limpieza de streams (server + nodo) |
| **qBittorrent** | 8080 / 6881 | Cliente BitTorrent |
| **WhatsApp Bot** | 3555 | Control total del stack via WhatsApp (@whiskeysockets/baileys) |
| **Maintainerr** | 8787 | Limpieza automática de contenido visto |
| **SubgenAI** | 9000 | Generación de subtítulos con IA (whisper) |
| **PostgreSQL** | 5432 | Base de datos compartida |
| **Uptime Kuma** | 3001 | Monitoreo de salud y uptime |
| **Homepage** | 3003 | Dashboard personalizado del stack |
| **AdGuard Home** | 3002 (UI) / 53 (DNS) | Bloqueo de anuncios y trackers por DNS |
| **Flaresolverr** | 8191 | Bypass de Cloudflare para indexadores |
| **Portainer** | 9443 | Administración de contenedores (HTTPS) |

---

## Instalación paso a paso

> Guía extendida con post-configuración de cada servicio: [INSTALL.md](INSTALL.md)

### Requisitos

| Componente | Mínimo | Recomendado |
|------------|--------|-------------|
| CPU | 2 núcleos | 4+ núcleos (transcoding) |
| RAM | 4 GB | 8–16 GB |
| Disco sistema | 20 GB SSD | 100 GB SSD |
| Disco multimedia | 500 GB | 1 TB+ |
| GPU | — | Intel con VAAPI (transcodificación por hardware) |

Software: Linux, Docker + Compose plugin, git. Opcional: Python 3 (scripts), Node.js 20 (solo si corrés el bot sin Docker).

### Paso 1 — Instalar dependencias

```bash
# Docker Engine + Compose plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
docker compose version   # verificar

# Python 3 (para los scripts de subtítulos y automatización)
sudo apt install python3 python3-pip python3-requests -y
```

### Paso 2 — Preparar almacenamiento

El stack asume esta estructura (ajustala a tus discos):

```bash
sudo mkdir -p /mnt/media/{movies,series,anime,music,downloads/{incomplete,torrents},backups}
sudo mkdir -p /mnt/media2/downloads /mnt/media2/backups/stack
```

Si usás discos separados, montalos vía `/etc/fstab`. Con dos discos podés unificarlos con mergerfs en `/mnt/media`.

### Paso 3 — Clonar el repositorio

```bash
git clone https://github.com/LautaroPiugh/chae-media-stack.git
cd chae-media-stack
```

### Paso 4 — Instalar (wizard recomendado)

El instalador interactivo pregunta IP, zona horaria, UID/GID y rutas, genera el `.env` raíz, despliega los servicios elegidos y espera que queden sanos:

```bash
./install.sh                # wizard interactivo 🐯
```

Flags útiles:

| Flag | Descripción |
|------|-------------|
| `--yes` | Acepta todos los defaults (instalación sin preguntas) |
| `--dry-run` | Muestra el plan completo sin ejecutar nada |
| `--update` | `git pull` + recrea los contenedores |
| `--uninstall` | Baja los contenedores (conserva datos) |

El wizard crea un `.env` raíz con `MEDIA_SERVER_IP` y otras variables, y copia su contenido a un `.env` en cada `services/*/` que tenga compose. Todos los composes leen la IP desde el `.env` de su propio directorio (`${MEDIA_SERVER_IP:-192.168.0.200}`), así que cambiarla después es editar el `.env` raíz **y** las copias.

### Paso 4 (alternativa) — Instalación manual

Si preferís entender cada pieza:

```bash
# 1. Crear las redes Docker compartidas y el volumen de Portainer
docker network create qbittorrent_default
docker network create jellyfin_default
docker network create prowlarr_default
docker network create postgres_default
docker volume create portainer_data

# 2. Configuración central (.env raíz + copias por servicio)
cat > .env <<'EOF'
MEDIA_SERVER_IP=192.168.1.100
TZ=America/Argentina/Buenos_Aires
PUID=1000
PGID=1000
EOF
  chmod 600 .env
  # install.sh copia el .env a cada servicio; el manual hace lo mismo.
  # Con symlinks funcionaría y propagaría un cambio al instante, pero no es
  # lo que hace la herramienta: una herramienta que escriba in-place sobre
  # services/<svc>/.env con un symlink escribiría sobre el canónico.
  for d in services/*/; do install -m 600 .env "$d/.env"; done

# 3. Levantar todo en orden (postgres primero, arr apps después)
./scripts/start-stack.sh

# 4. Bot de WhatsApp
cp jellyfin-whatsapp-bot/.env.example jellyfin-whatsapp-bot/.env
nano jellyfin-whatsapp-bot/.env    # WHATSAPP_OWNER, JELLYFIN_API_KEY, RADARR_API_KEY, SONARR_API_KEY...
cd jellyfin-whatsapp-bot && docker compose up -d --build
docker logs -f jellyfin-whatsapp-bot   # escanear QR con WhatsApp → Dispositivos vinculados
```

Antes de arrancar revisá en los composes: `POSTGRES_PASSWORD` (postgres), rutas de volúmenes y `TZ`.

### Paso 5 — Post-configuración esencial

1. **Jellyfin** (`:8096`) → setup inicial, agregar bibliotecas `/media/movies`, `/media/series`, `/media/anime`, `/media/music`.
2. **Prowlarr** (`:9696`) → agregar tus indexadores.
3. **Radarr/Sonarr** → conectar Prowlarr como indexer, definir root folders, copiar API keys.
4. **qBittorrent** (`:8080`, default `admin/adminadmin`) → cambiar contraseña.
5. **Webhooks del bot** → en Radarr y Sonarr: Settings → Connect → Webhook → `http://jellyfin-whatsapp-bot:3555/webhook/radarr` (y `/sonarr`), eventos Download + Upgrade.
6. **Cron de automatización** (opcional, ver sección [Automatización](#automatización)).

### Paso 6 — Verificar la instalación

```bash
./scripts/health-check.sh        # chequeo integral del stack

# o manualmente:
docker ps                        # todos los chae-* corriendo
curl -s -o /dev/null -w "%{http_code}" http://localhost:8096   # Jellyfin → 200
curl -s http://localhost:3555/health                           # Bot → ok
```

---

## Bot de WhatsApp

Se conecta a WhatsApp Web con `@whiskeysockets/baileys` (API no oficial). Corre como contenedor, genera QR al primer inicio y solo responde al número del dueño (`WHATSAPP_OWNER`). Los comandos admin se habilitan con `/registraradmin`.

### Comandos principales

| Comando | Descripción |
|---------|-------------|
| `/ayuda` | Lista todos los comandos |
| `/status` | Estado del sistema: conexiones, biblioteca, descargas, disco |
| `/peli [nombre]` | Buscar y agregar película a Radarr |
| `/serie [nombre]` | Buscar y agregar serie a Sonarr (elige temporada) |
| `/buscar [nombre]` | Búsqueda combinada Radarr + Sonarr |
| `/cola` | Cola de descargas activas |
| `/subs` | Estado de subtítulos ES de toda la biblioteca |
| `/traducir [película]` | Traduce subtítulos EN→ES vía DeepL |
| `/azar` / `/recomendar [género]` | Recomendaciones de la biblioteca |
| `/pedidos` / `/mispedidos` | Solicitudes pendientes en Jellyseerr |
| `/ultimo` / `/catalogo` / `/faltantes` | Explorar la biblioteca |
| `/espacio` | Uso de disco |
| `/actualizar [nombre]` | Buscar mejor calidad de contenido existente |
| `/actualizarsistema` | Preflight Git + Docker con confirmación y cola de actualización |
| `/eliminar` `/refrescar` `/reiniciar` `/reconectar` `/limpiartorrents` | **(admin)** mantenimiento |
| `/cancelar` `/mas` `/repetir` | Control de flujos y paginación |

Lista completa con ejemplos: [jellyfin-whatsapp-bot/README.md](jellyfin-whatsapp-bot/README.md)

### Webhooks

| Endpoint | Auth | Descripción |
|----------|------|-------------|
| `POST /webhook/radarr?token=<SECRET>` | query token | Película descargada → notifica a WhatsApp |
| `POST /webhook/sonarr?token=<SECRET>` | query token | Episodio descargado → notifica a WhatsApp |
| `POST /notify/system-update` | header `x-update-token` | Notificaciones de scripts/cron |

## Flujos de datos

### Agregar contenido desde WhatsApp

```
/peli Inception → Bot confirma con vos → agrega a Radarr
  → Radarr busca en Prowlarr → envía el mejor release a qBittorrent
  → descarga a /mnt/media2/downloads → importa y renombra a /mnt/media/movies/
  → Jellyfin detecta el contenido → webhook al bot → "✅ Inception (2010) descargada"
```

### Subtítulos ES garantizados

```
cron (cada 6h) check_es_subs.py
  → consulta Bazarr por todo sin sub ES (códigos es/ea/sp)
  → prueba providers de Bazarr → OpenSubtitles REST API (por IMDB ID)
  → episodios: fallback OMDb → películas: sub EN + traducción DeepL → .es.srt
  → notifica resumen por WhatsApp

cron (cada 10min) auto_translate.py → subs EN recientes traducidos con Gemini
subgenai → whisper on-demand cuando Jellyfin no encuentra subs
```

### Transcodificación y limpieza

```
Tdarr monitorea /mnt/media → convierte a HEVC (VAAPI) → elimina pistas de audio/subs no deseadas
Maintainerr limpia contenido ya visto según reglas
```

## Automatización

| Frecuencia | Script | Descripción |
|------------|--------|-------------|
| 2 min | `media-mount-recovery.sh` | Verifica montura de `/mnt/media`; si se recuperó reinicia Radarr/Sonarr/Bazarr/Jellyfin/qBittorrent |
| 5 min | `generate-stack-dashboard-data.sh` | Caché JSON para el dashboard |
| 10 min | `auto_translate.py` | Traduce subs EN→ES vía Gemini |
| 6 h | `check_es_subs.py` | Verifica y descarga subtítulos ES faltantes |
| 3:00 am | `backup-stack.sh` | Dump PostgreSQL + configs (retención 14 días) |
| 4:30 am | logrotate | Rotación de logs propios del stack |
| On-demand | `media-update-broker` (systemd) | Actualiza Git + allowlist Docker de forma secuencial con backups, health-check y rollback |

## Almacenamiento

```
  /mnt/media/              pool mergerfs (~5.4T) = media1..media6
    ├── movies/            películas (Radarr)
    ├── series/            series (Sonarr)
    ├── anime/             anime
    ├── music/             música
    ├── downloads/         torrents completados
    └── backups/           backups automáticos

  /mnt/media1/             916G ext4 — espejo de backups
    └── backups/stack/     copia de los backups automáticos
  /mnt/media2/             916G ext4 — descargas + backups
    ├── downloads/         destino de descargas de qBittorrent y caché de Tdarr
    └── backups/stack/     backups diarios (origen)
  /mnt/media3/             916G ext4 — biblioteca
  /mnt/media4/             916G ext4 — biblioteca
  /mnt/media5/             916G ext4 — rama libre
  /mnt/media6/             916G ext4 — rama libre
  ```

  Todas las ramas son ext4 y se declaran en `.media-branches.conf`, que es la
  fuente de verdad. Agregar un disco regenera ese archivo, `fstab` y el
  drop-in de Docker juntos, con `scripts/add-media-disk.sh`.

## Redes y acceso remoto

**Redes Docker** (externas, se crean una vez):

```
qbittorrent_default → radarr, sonarr, bazarr, prowlarr, jellyseerr, qbittorrent,
                      flaresolverr, bot, tdarr(+node), uptime-kuma, homepage, maintainerr
jellyfin_default    → jellyfin, uptime-kuma
prowlarr_default    → prowlarr, flaresolverr
```

Los servicios se comunican por nombre de contenedor como DNS (ej: `http://radarr:7878`).

**Acceso remoto:** las UIs administrativas no están publicadas directamente a internet; el túnel Cloudflare (`cloudflared`, servicio systemd con autoupdates, configurado por dashboard) es el camino de entrada previsto para ellas. El único puerto que sí escucha en todas las interfaces es `6881` de qBittorrent, cuyo acceso desde internet depende del firewall del host y del NAT del router.

## Seguridad

  - Sin UIs administrativas expuestas directamente desde internet: el
    Cloudflare Tunnel es el único camino de entrada externo
    - Dentro de la LAN, 15 UIs quedan publicadas en la IP del server
      (Jellyfin, Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr, qBittorrent,
      AdGuard, Scrutiny, Maintainerr, Homepage, Dozzle, Tdarr, Uptime Kuma,
      subgen). Quien esté en la LAN las alcanza directo
    - qBittorrent mantiene `6881` TCP/UDP en todas las interfaces a
      propósito, para aceptar peers entrantes. No es una UI y no está
      sujeto al modelo de las anteriores: su exposición real depende del
      firewall del host y del NAT del router
  - El bot solo responde al número del dueño; admin requiere `/registraradmin`
  - Webhooks protegidos con tokens secretos
  - `.env` con permisos `600`, excluidos del repo; API keys nunca commiteadas
    - Solo los servicios que soportan `PUID`/`PGID` y las tienen
      configuradas crean sus archivos como `1000:1000`. AdGuard y Scrutiny
      son las excepciones: no reciben esas variables y sus procesos
      corren como root. Scrutiny además es `privileged` con `SYS_RAWIO` y
      `SYS_ADMIN`. Y en los servicios compatibles, esto tampoco implica
      non-root: el PID 1 sigue siendo root, las imágenes de linuxserver
      bajan solo el proceso del servicio a uid 1000
- 20 de 21 composes pineados por digest. La excepción es
  `jellyfin-whatsapp-bot`, que se construye localmente desde el repo
- 12 de 22 contenedores tienen healthcheck. Los 10 que no, ver más abajo
- Límites de memoria en los servicios que los necesitan (tdarr 2g,
  tdarr-node 8g, subgen 8g)

## Actualización y mantenimiento

```bash
./install.sh --update          # git pull + recrea contenedores (wizard)
# o
/home/chae/stack/scripts/update-media-stack.sh   # script local de actualización

./scripts/health-check.sh      # estado integral del stack
./scripts/stop-stack.sh        # bajar todo
./scripts/start-stack.sh       # levantar todo
```

También disponible desde WhatsApp: `/actualizarsistema`.

## Scripts útiles

| Script | Descripción |
|--------|-------------|
| `install.sh` | Wizard de instalación/update/uninstall |
| `scripts/start-stack.sh` / `stop-stack.sh` | Levantar/bajar el stack completo |
| `scripts/health-check.sh` | Chequeo de salud de todos los servicios |
| `scripts/stack-status.sh` / `media-status.sh` | Estado rápido del stack |
| `scripts/chaetop` | Dashboard TUI del servidor (discos, media stack, torrents, Docker) |
| `scripts/stack-logs.sh` | Logs centralizados |
| `scripts/backup-stack.sh` | Backup diario (Postgres + configs) |
| `scripts/check_es_subs.py` | Pipeline principal de subtítulos ES |
| `scripts/media-mount-recovery.sh` | Autocuración de la montura de medios |
| `scripts/sync-homepage-keys.sh` | Sincroniza API keys con Homepage |
| `scripts/update-media-stack.sh` | Actualización del stack |
| `bin/panel-remoto` | Panel de control remoto |

### chaetop — dashboard TUI

Dashboard interactivo en terminal (`chaetop` está en `~/bin`, `~/.local/bin` y
`stack/bin` vía symlink a `scripts/chaetop`). Paneles:

- **Discos y mounts**: lista automática de todos los discos reales de
  `/proc/mounts` (los que se agreguen aparecen solos), con barra, uso, libre,
  device y filesystem; los HDD del pool (`/mnt/media1`, `/mnt/media2`) además
  muestran `[ok]`/error verificando el UUID esperado.
- **Media stack**: biblioteca Jellyfin (pelis/series/eps), sesiones activas con
  usuario y título, Radarr (faltantes + cola), Sonarr (eps faltantes + cola) y
  pedidos en proceso de Jellyseerr.
- **Torrents**: descargas activas de qBittorrent con progreso y ETA.
- **Servicios Docker**: estado, salud, CPU, memoria, puerto y URL por contenedor.

Atajos: `q` salir · `j/k` elegir servicio · `l` logs · `r` reiniciar ·
`s` shell · `u` preview de updates · `U` actualizar el servicio elegido (con
confirmación, vía `update-media-stack.sh service`) · `m` mounts · `d` docker ·
`?` ayuda.

Credenciales y API keys en `~/.config/chaetop/chaetop.env`
(`QBIT_USER`, `QBIT_PASS`, `JELLYFIN_KEY`, `RADARR_KEY`, `SONARR_KEY`,
`SEERR_KEY`).

## Troubleshooting

```bash
docker ps -a | grep chae        # ¿está corriendo?
docker logs chae-radarr         # logs de un servicio
sudo lsof -i :8096              # puerto ocupado
```

- **Contenedor no arranca** → `docker logs <contenedor>`, verificá `.env` y rutas de volúmenes.
- **No aparece el QR del bot** → `docker compose restart` en `jellyfin-whatsapp-bot/`.
- **Webhooks no llegan** → usá el nombre de contenedor (`http://jellyfin-whatsapp-bot:3555/...`) desde Radarr/Sonarr.
- **Medios desaparecidos** → `media-mount-recovery.sh` los restaura en ~2 min; revisá `dmesg` si los discos se desconectan.

## Documentación adicional

- [INSTALL.md](INSTALL.md) — guía de instalación detallada con post-configuración por servicio
- [SISTEMA.md](SISTEMA.md) — documentación completa del sistema: hardware, servicios, cron, backups, seguridad
- [services/README.md](services/README.md) — comportamiento y optimizaciones por servicio
- [jellyfin-whatsapp-bot/README.md](jellyfin-whatsapp-bot/README.md) — comandos, webhooks y troubleshooting del bot

## Licencia

Este proyecto está bajo la licencia [MIT](LICENSE) — Copyright © 2026 Lautaro Piugh
