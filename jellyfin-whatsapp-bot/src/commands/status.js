const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');
const { isWhatsAppConnected } = require('../whatsapp');
const { listMovies, listMissingMovies } = require('../clients/radarrClient');
const { listSeries, listMissingSeries } = require('../clients/sonarrClient');
const { isConfigured: isJellyseerrConfigured, getPendingRequests } = require('../clients/jellyseerrClient');
const { isConfigured: isQbitConfigured, getActiveTorrents } = require('../clients/qbittorrentClient');
const { remember } = require('../utils/cache');
const { formatPanel } = require('../utils/panel');
const { getDiskSummary } = require('../utils/diskSummary');

function withTimeout(promise, fallback, timeoutMs = 4000) {
  return Promise.race([
    promise.catch(() => fallback),
    new Promise((resolve) => setTimeout(() => resolve(fallback), timeoutMs)),
  ]);
}

async function checkService(url, headers = {}, timeoutMs = 4000) {
  return Promise.race([
    fetchWithTimeout(url, { headers })
      .then((res) => res.ok)
      .catch(() => false),
    new Promise((resolve) => setTimeout(() => resolve(false), timeoutMs)),
  ]);
}

async function handleStatus() {
  return remember('command:status', 30000, async () => {
    const waConnected = isWhatsAppConnected();
    const radarrConfigured = !!(config.radarr.url && config.radarr.apiKey);
    const sonarrConfigured = !!(config.sonarr.url && config.sonarr.apiKey);

    const [radarrAvailable, sonarrAvailable] = await Promise.all([
      radarrConfigured
        ? checkService(`${config.radarr.url}/api/v3/system/status`, { 'X-Api-Key': config.radarr.apiKey })
        : false,
      sonarrConfigured
        ? checkService(`${config.sonarr.url}/api/v3/system/status`, { 'X-Api-Key': config.sonarr.apiKey })
        : false,
    ]);

    const waStatus = waConnected ? '🟢 conectado' : '🔴 desconectado';
    const radarrStatus = !radarrConfigured ? '⚠️ no configurado' : radarrAvailable ? '✅ disponible' : '🔴 no disponible';
    const sonarrStatus = !sonarrConfigured ? '⚠️ no configurado' : sonarrAvailable ? '✅ disponible' : '🔴 no disponible';

    const [movies, missingMovies, series, missingSeries, requests, downloads, disk] = await Promise.all([
      radarrAvailable ? withTimeout(listMovies(), []) : [],
      radarrAvailable ? withTimeout(listMissingMovies(), []) : [],
      sonarrAvailable ? withTimeout(listSeries(), []) : [],
      sonarrAvailable ? withTimeout(listMissingSeries(), []) : [],
      isJellyseerrConfigured() ? withTimeout(getPendingRequests(), []) : [],
      isQbitConfigured() ? withTimeout(getActiveTorrents(), []) : [],
      withTimeout(getDiskSummary(), null),
    ]);

    const sections = [
      {
        title: 'Conexiones',
        lines: [
          `- WhatsApp: ${waStatus}`,
          `- Radarr: ${radarrStatus}`,
          `- Sonarr: ${sonarrStatus}`,
          `- Jellyfin: ${config.jellyfin.url || 'no configurada'}`,
          `- Jellyseerr: ${isJellyseerrConfigured() ? '✅ configurado' : '⚠️ no configurado'}`,
          `- qBittorrent: ${isQbitConfigured() ? '✅ configurado' : '⚠️ no configurado'}`,
        ],
      },
      {
        title: 'Biblioteca',
        lines: [
          `- 🎬 Películas descargadas: ${movies.length}`,
          `- 🎬 Películas pendientes: ${missingMovies.length}`,
          `- 📺 Series descargadas: ${series.length}`,
          `- 📺 Series pendientes: ${missingSeries.length}`,
        ],
      },
      {
        title: 'Actividad',
        lines: [
          `- 📨 Requests pendientes: ${requests.length}`,
          `- 📥 Descargas reales: ${downloads.length}`,
        ],
      },
    ];

    if (disk) {
      sections.push({
        title: 'Espacio',
        lines: [
          `- Pool libre: ${disk.pool.free} de ${disk.pool.total}`,
          `- Disco 1 libre: ${disk.media1.free}`,
          `- Disco 2 libre: ${disk.media2.free}`,
        ],
      });
    }

    return formatPanel('Estado del bot', sections, 'Tip: usá /cola para descargas, /pedidos para Jellyseerr y /espacio para ver discos.');
  });
}

module.exports = { handleStatus };
