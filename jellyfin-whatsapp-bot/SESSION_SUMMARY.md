# Jellyfin WhatsApp Bot - Resumen de Sesion

## Estado general

- Bot corriendo en Docker Compose como `jellyfin-whatsapp-bot`.
- WhatsApp conectado por Baileys.
- Integraciones activas: Radarr, Sonarr, Jellyseerr, qBittorrent, Bazarr.
- Se reconstruyo y reinicio el contenedor con `docker compose up -d --build`.

## Cambios realizados

### Status y disponibilidad real

- `/status` ya no muestra `configurado` solo por tener variables.
- Ahora verifica disponibilidad real de Radarr y Sonarr con probe a `system/status`.
- Estados actuales posibles:
  - `no configurado`
  - `disponible`
  - `no disponible`

### Busqueda de peliculas

- Se mejoro el ranking de `/peli`.
- Se elimino la linea `Estado: ...` de resultados.
- Se priorizan mejor coincidencias exactas, popularidad, votos y anio.
- Si existe, se muestra `Titulo original`.

### Ayuda

- `/ayuda` fue resumido para no mandar un bloque tan largo.
- Ahora agrupa comandos por categoria.

### Comandos nuevos

- `/reiniciar`
  - reinicia todo el bot
  - solo owner
- `/reconectar`
  - reinicia solo la conexion de WhatsApp
  - solo owner
- `/actualizar nombre`
  - busca una pelicula o serie ya existente en biblioteca
  - relanza la busqueda en Radarr o Sonarr

### Fallback de mensajes

- Si el usuario manda algo que no coincide con ningun comando ni flujo activo, el bot responde:
  - `No entendi ese mensaje. Proba con un comando valido o usa /ayuda.`

### Cache corta

- Se agrego cache en memoria de 30 segundos para:
  - `/status`
  - `/cola`
  - `/descargas`
  - `/requests`

### Eliminar solo contenido real

- `/eliminar` ya no usa resultados externos.
- Ahora busca solo dentro de biblioteca descargada:
  - peliculas descargadas de Radarr
  - series descargadas de Sonarr

### Flujo de series por temporada

- `serie 1` ya no agrega directo siempre.
- Si la serie es nueva, ahora pregunta:
  - `todas`
  - `temporada N`
- Si elegis una temporada:
  - se agrega a Sonarr monitoreando solo esa temporada
- Para series nuevas se envia `seasonFolder: true`.

### Webhook de Sonarr

- Antes descartaba eventos `Download` si faltaba `episodeFile`.
- Ahora envia una notificacion basica aunque ese dato no venga.
- Eso evita perder mensajes al terminar descargas validas.

## Configuracion encontrada

### Sonarr

- URL interna: `http://sonarr:8989`
- Root folder: `/media/series`
- Root folder accesible: `true`
- Naming de episodios:
  - `{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}`

### Modern Family

Situacion original:

- estaba en Sonarr con `seasonFolder: false`
- path: `/media/series/Modern Family`
- archivos todos mezclados en una sola carpeta

Acciones hechas:

- se actualizo la serie en Sonarr a `seasonFolder: true`
- se movieron archivos a:
  - `Season 01`
  - `Season 02`
  - ...
  - `Season 11`
- se dispararon comandos Sonarr:
  - `RescanSeries`
  - `RefreshSeries`

Estado actual:

- Sonarr estaba reescaneando la serie al final de la sesion.
- El indexado no habia terminado todavia.

## Subtitulos e idiomas

### Sonarr

- `Modern Family` usa `languageProfileId: 1`.
- El unico language profile disponible en Sonarr es `English`.
- Conclusion:
  - Sonarr no esta configurado para preferir audio en espaniol.

### Bazarr

- Perfil detectado: `Espanol`
- Ese perfil incluye:
  - `ea`
  - `es`
- `Modern Family` tiene aplicado ese perfil en Bazarr.
- En varios episodios Bazarr detecta audio/subs embebidos en:
  - `fr`
  - `en`
- En varios episodios faltan aun subtitulos:
  - `es`
  - `ea`

### Hallazgo clave de Bazarr

- Bazarr si descargo subtitulos espanoles para varios episodios.
- Hay `.es.srt` reales ya presentes en disco.
- Pero OpenSubtitles estaba limitado temporalmente:
  - `DownloadLimitExceeded`
  - bloqueo por `6 hours`

### Config relevante de Bazarr

- providers habilitados:
  - `opensubtitlescom`
  - `legendasdivx`
  - `tvsubtitles`
- `minimum_score: 90`
  - bastante exigente

## Archivos tocados durante la sesion

- `src/commands/status.js`
- `src/clients/radarrClient.js`
- `src/utils/formatMessage.js`
- `src/commands/admin.js`
- `src/commands/index.js`
- `src/commands/help.js`
- `src/commands/delete.js`
- `src/whatsapp.js`
- `src/commands/update.js`
- `src/utils/cache.js`
- `src/commands/queue.js`
- `src/commands/downloads.js`
- `src/commands/requests.js`
- `src/clients/sonarrClient.js`
- `src/commands/confirmSelection.js`
- `src/handlers/sonarrWebhook.js`

## Pendientes recomendados

### Alta prioridad

1. Verificar que Sonarr termine de reindexar `Modern Family` correctamente.
2. Confirmar desde la UI de Sonarr que la serie ya figura con `season folders` activos.
3. Revisar si queres cambiar el language profile de Sonarr de `English` a uno nuevo en espaniol o multilenguaje.

### Subtitulos

1. Esperar a que se libere el limite de OpenSubtitles.
2. Reintentar busqueda de subtitulos faltantes en Bazarr.
3. Considerar bajar `minimum_score` de Bazarr si esta dejando pasar demasiados subtitulos utiles.
4. Considerar agregar mas proveedores si queres mejor cobertura en espaniol.

### Bot

1. Agregar comando para forzar rescan o refresh de una serie desde WhatsApp.
2. Mejorar fallback del bot para sugerir comandos segun texto libre.
3. Agregar paginado tambien en `/eliminar` si aparecen mas de 10 coincidencias.
4. Agregar comando `/ultimo` o `/recien agregado`.

## Comandos utiles actuales

- `/status`
- `/peli nombre`
- `/serie nombre`
- `/actualizar nombre`
- `/eliminar nombre`
- `/cola`
- `/descargas`
- `/faltantes`
- `/catalogo`
- `/requests`
- `/random`
- `/recomendar`
- `/reconectar`
- `/reiniciar`

## Notas finales

- Las series nuevas agregadas desde ahora deberian crearse con `seasonFolder: true`.
- `Modern Family` fue corregida manualmente en disco y en Sonarr, pero el rescan quedo en curso al cerrar esta sesion.
- El problema de subtitulos en frances no fue que Bazarr eligiera frances como deseado, sino que varios releases ya traian `fr/en` embebidos y faltaban aun los `.es`.
