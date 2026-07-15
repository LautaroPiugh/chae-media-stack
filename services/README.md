# Servicios del Media Stack

Servicios de streaming y descargas auto-hosteado.

## Arquitectura

```
                    ┌─────────────┐
                    │   Internet  │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  Prowlarr   │ ←── Gestor de indexadores
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌────▼────┐ ┌────▼─────┐
        │  Radarr   │ │  Sonarr │ │  Bazarr  │
        │ (pelis)   │ │ (series)│ │(subtítulos)
        └─────┬─────┘ └────┬────┘ └──────────┘
              │            │
              │     ┌──────▼──────┐
              │     │   qBittorrent │
              │     │  (descargas)  │
              │     └──────┬──────┘
              │            │
              └─────>──────┘
                         │
                    ┌─────▼─────┐
                    │  Jellyfin  │ ←── Streaming
                    └───────────┘
                         │
                    ┌─────▼─────┐
                    │   Tdarr    │ ←── Transcode
                    └───────────┘
```

## Comportamiento por Servicio

### Jellyfin
- Servidor de streaming para películas, series, anime y música
- Aceleración por hardware via VAAPI (GPU Intel) para transcodificación
- Cache: 1000 MB, retención de logs: 7 días
- Decodificación GPU: h264, hevc, vc1, mpeg2video
- Cuando un usuario reproduce contenido que no es compatible con su dispositivo, Jellyfin transcodifica sobre la marcha usando la GPU
- Detecta automáticamente contenido nuevo cuando Radarr/Sonarr importan archivos a `/media/`
- Puertos: 8096 (HTTP), 8920 (HTTPS)

### Radarr
- Automatización de biblioteca de películas
- **Comportamiento:** cuando se agrega una película (via bot o web UI), Radarr busca en los indexadores de Prowlarr, elige el mejor release según calidad y seeders, lo envía a qBittorrent para descargar, y cuando completa importa el archivo a `/media/movies/` renombrándolo según tu formato
- Notifica al bot de WhatsApp via webhook al completar una descarga
- Seeders mínimos: 12 (configurado por indexador)
- Releases multi-lenguaje: desactivado (prefiere audio original)
- Permite especificar calidad deseada: `4K`, `1080p`, etc.
- Puerto: 7878

### Sonarr
- Automatización de biblioteca de series con monitoreo por temporada
- **Comportamiento:** similar a Radarr pero para series. Cuando se agrega una serie, se elige qué temporadas monitorear. Solo las temporadas monitoreadas disparan búsquedas. Cada episodio se descarga, importa y renombra individualmente
- Notifica al bot por cada episodio descargado
- Seeders mínimos: 12
- Releases multi-lenguaje: desactivado
- Puerto: 8989

### Prowlarr
- Gestor centralizado de indexadores/trackers
- **Comportamiento:** sincroniza los indexadores configurados con Radarr y Sonarr automáticamente. Maneja credenciales, categorías y límites de tasa de cada tracker. Cuando Radarr o Sonarr necesitan buscar un release, consultan a Prowlarr, que a su vez consulta todos los indexadores configurados y devuelve los resultados
- Puede usar Flaresolverr como proxy para indexadores protegidos por Cloudflare
- Puerto: 9696

### Bazarr
- Descargador automático de subtítulos para películas y series
- **Comportamiento:** monitorea las bibliotecas de Radarr y Sonarr. Cuando detecta contenido sin subtítulos en los idiomas configurados (español `es`, español latino `ea`), busca en sus providers: opensubtitlescom, legendasdivx, podnapisi, subf2m, subdl
- Prioridad de perfil: `espanol latino` → `espanol`
- Score mínimo para series: 75
- Frecuencia de búsqueda: cada 3 horas
- Puerto: 6767

### qBittorrent
- Cliente BitTorrent para todas las descargas
- **Comportamiento:** recibe torrents de Radarr y Sonarr. Descarga los archivos a `/downloads/torrents/`. Una vez completa la descarga, seedea según la configuración (sin límite de velocidad). Radarr/Sonarr importan los archivos desde la carpeta de descargas a la biblioteca de medios
- Modo de red: host (sin overhead de Docker bridge)
- UPnP y Port Forwarding: activados para mejor conectividad
- Máximo descargas activas: 4, máximo torrents activos: 5
- Máximo pares por torrent: 100
- Sin límite de descarga
- Puertos: 8080 (WebUI), 6881 (TCP/UDP tráfico torrent)

### Tdarr
- Transcodificación y optimización de medios automatizada
- **Comportamiento:** arquitectura servidor + nodo. El servidor administra las colas y flujos de trabajo, el nodo ejecuta la transcodificación. Monitorea `/media/` en busca de archivos nuevos y aplica el workflow configurado:
  1. Convierte video a HEVC (ahorra ~40-60% de espacio)
  2. Limpia streams de subtítulos no deseados (saca PGS/DVD, conserva los basados en texto)
  3. Elimina pistas de audio innecesarias
- Aceleración GPU via VAAPI
- Cache en `/downloads/tdarr-cache`
- Puertos: 8265 (WebUI), 8266 (Servidor interno)

### Jellyseerr
- Portal de solicitudes y descubrimiento de contenido (fork de Overseerr)
- **Comportamiento:** los usuarios pueden navegar contenido popular, próximo a estrenar y descubrir. Cuando solicitan una película, se envía a Radarr; cuando solicitan una serie, se envía a Sonarr. Muestra disponibilidad desde Jellyfin
- Puerto: 5055

### Flaresolverr
- Servicio de bypass de desafíos de Cloudflare
- **Comportamiento:** actúa como proxy entre Prowlarr y los indexadores que están protegidos por Cloudflare. Cuando un indexador responde con un desafío de Cloudflare, Prowlarr reenvía la solicitud a Flaresolverr, que resuelve el challenge y devuelve el resultado
- Puerto: 8191

### PostgreSQL
- Base de datos para servicios que lo requieren
- Usuario: `chae`, base de datos: `chae`
- Backupeada diariamente por `backup-stack.sh`
- Puerto: 5432

### Uptime Kuma
- Dashboard de monitoreo de salud
- **Comportamiento:** verifica periódicamente que cada servicio responda correctamente via HTTP. Si un servicio falla, envía alerta al bot de WhatsApp via webhook
- Puerto: 3001

### AdGuard
- Bloqueo de anuncios a nivel DNS para la red local
- Filtra anuncios y rastreadores antes de que lleguen a los dispositivos
- Puertos: variables (típicamente 53/3000)

### Maintainerr
- Limpieza automática de contenido
- **Comportamiento:** elimina contenido que cumple reglas configurables (no visto, antiguo, baja puntuación). Se integra con Radarr y Sonarr para realizar las eliminaciones
- Puerto: 8787

### SubgenAI
- Generación de subtítulos impulsada por IA
- Genera subtítulos para contenido que no tiene ninguno
- Se usa como fallback cuando los providers tradicionales no tienen resultados
- Puerto: 9000

### Homepage
- Dashboard personalizado con estado de servicios
- Muestra salud del sistema, uso de almacenamiento y enlaces rápidos
- Lee de un JSON cacheado generado por `generate-stack-dashboard-data.sh`
- Puerto: 3003

## Red

Los servicios se conectan via redes Docker:

```
qbittorrent_default:  radarr, sonarr, bazarr, prowlarr, jellyseerr, qbittorrent,
                      flaresolverr, jellyfin-whatsapp-bot, tdarr, tdarr-node, uptime-kuma, homepage
jellyfin_default:     jellyfin, uptime-kuma
```

DNS interno usa nombres cortos de contenedor (ej: `http://radarr:7878`).

Todos los servicios corren con `PUID=1000`, `PGID=1000` (usuario `chae`), `TZ=America/Argentina/Buenos_Aires`.

## URLs de Acceso

| Servicio | URL |
|---------|-----|
| Jellyfin | http://192.168.1.100:8096 |
| Radarr | http://192.168.1.100:7878 |
| Sonarr | http://192.168.1.100:8989 |
| Prowlarr | http://192.168.1.100:9696 |
| Bazarr | http://192.168.1.100:6767 |
| Tdarr | http://192.168.1.100:8265 |
| Jellyseerr | http://192.168.1.100:5055 |
| Portainer | https://192.168.1.100:9443 |

## Estructura de Almacenamiento

```
/mnt/media/
  /movies/         → Biblioteca de películas
  /series/         → Biblioteca de series
  /anime/          → Anime
  /music/          → Música
  /downloads/      → Descargas temporales
    /incomplete/   → Descargas en progreso
    /torrents/     → Torrents completados
```

## Comandos Útiles

```bash
# Ver estado de contenedores
docker ps

# Ver logs de un servicio
docker logs chae-jellyfin
docker logs chae-qbittorrent
docker logs chae-sonarr

# Reiniciar un servicio
cd /home/chae/services/jellyfin && docker compose restart

# Ver uso de recursos
docker stats

# Backup de configuraciones
tar -czf backup-$(date +%Y%m%d).tar.gz /home/chae/services/*/config/
```
