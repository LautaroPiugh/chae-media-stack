# Resumen Media Stack 2026-05-26

## Bot WhatsApp

- Se corrigio el chequeo de admin para usar registro de sesion con `/registraradmin`.
- Se agrego `/limpiartorrents` para borrar torrents completos de qBittorrent sin borrar archivos importados.
- Se unifico `/cola` y `/descargas` en una sola vista.
- Se persistieron los pedidos para que no se pierdan las notificaciones de descarga completada.
- Se corrigio la notificacion de espacio en disco para usar `/mnt/media` real.
- Se agrego preferencia de calidad en `/peli nombre 4k` y `/peli nombre 1080p`.
- Se mejoro `/actualizar` para peliculas:
  - muestra calidad actual
  - ofrece upgrade disponible
  - ahora etiqueta las opciones como `1080p (Full HD)`, `1440p (2K)` si existe perfil, y `2160p (4K)`

## Sonarr

- Se corrigio el flujo para pedir solo una temporada desde el bot.
- Si elegis una temporada, el bot ahora:
  - agrega la serie
  - deja monitoreada solo esa temporada
  - relanza la busqueda correcta
- Seeders minimos en indexers torrent: `12`.
- `multiLanguages` desactivado para evitar favorecer releases multiaudio.
- Preferencia efectiva: audio original.

## Radarr

- Seeders minimos en indexers torrent: `12` en casi todos.
- `multiLanguages` desactivado para evitar favorecer releases multiaudio.
- Preferencia efectiva: audio original.
- Se limpio la cola rota de `The Batman` y el bot ahora intenta limpiar automaticamente items `downloadClientUnavailable`.
- Excepcion actual: `UzTracker` no dejo guardar por `429 TooManyRequests` en validacion.

## Bazarr

- Idiomas activos de subtitulos: `es` y `ea`.
- Prioridad actual del perfil: `espanol latino` y luego `espanol`.
- Se ajusto `minimum_score` de series a `75`.
- Se ajusto `wanted_search_frequency` a `3h`.
- Proveedores activos:
  - `opensubtitlescom`
  - `legendasdivx`
  - `podnapisi`
  - `subf2m`
  - `subdl`
- `tvsubtitles` se saco porque respondia `404`.
- `subf2m` quedo con `user_agent` configurado.

## qBittorrent

- Se limpio el duplicado de `Twin Peaks S01`.
- Se limpiaron restos de `Modern Family` que habian quedado aunque la serie ya no estaba en Sonarr/Bazarr.
- Se agrego limpieza desde bot para torrents completados.

## Jellyfin

- Se verifico que `Twin Peaks` estaba importada correctamente.
- Se forzo refresh de biblioteca y luego Jellyfin ya devolvia la serie.

## Casos revisados

### Twin Peaks

- Temporada 1 importada correctamente.
- Se corrigio el monitoreo para que temporada 3 no quede activa por error.
- Bazarr reconoce faltantes de subtitulos en `es/ea`, pero depende de disponibilidad real de proveedores.

### Modern Family

- El audio/frances detectado venia de la release `MULTi`, no de Bazarr.
- Sonarr/Bazarr ya no la tenian, pero quedaron torrents viejos en qBittorrent; ya se limpiaron.

## Pendiente o limite actual

- `UzTracker` en Radarr sigue con `minimumSeeders = 1` porque Radarr rechaza guardar mientras el indexer responde `429`.
- Si queres evitar todavia mas releases francesas o `MULTi`, el siguiente paso seria agregar reglas de exclusion por keywords (`MULTi`, `FRENCH`, `VFF`, `TRUEFRENCH`, `DUAL`, etc.).
