const { statfs } = require('fs/promises');
const fs = require('fs');
const config = require('./config');
const { sendWhatsAppMessage } = require('./whatsapp');
const { isConfigured: isJellyseerrConfigured, getStatus: getJellyseerrStatus } = require('./clients/jellyseerrClient');
const { isConfigured: isQbitConfigured, getActiveTorrents } = require('./clients/qbittorrentClient');

const state = {
  services: new Map(),
  lowDiskAlerted: false,
  stalled: new Map(),
  mountHealthy: null,
  healthAlerted: new Map(),
  lastSubtitleCount: -1,
  updateAlerted: new Map(),
};

const MOUNT_PATH = '/mnt/media';
const EXPECTED_MOUNT_DIRS = ['/mnt/media/movies', '/mnt/media/series', '/mnt/media/downloads'];

const MONITORED_IMAGES = [
  { name: 'Radarr', image: 'lscr.io/linuxserver/radarr' },
  { name: 'Sonarr', image: 'lscr.io/linuxserver/sonarr' },
  { name: 'Prowlarr', image: 'lscr.io/linuxserver/prowlarr' },
  { name: 'Bazarr', image: 'lscr.io/linuxserver/bazarr' },
  { name: 'qBittorrent', image: 'lscr.io/linuxserver/qbittorrent' },
  { name: 'Jellyfin', image: 'lscr.io/linuxserver/jellyfin' },
  { name: 'Jellyseerr', image: 'ghcr.io/fallenbagel/jellyseerr' },
];

async function checkUrl(name, url) {
  try {
    const res = await fetch(url);
    return res.ok;
  } catch {
    return false;
  }
}

async function checkServices() {
  const targets = [
    ['Radarr', `${config.radarr.url}/api/v3/system/status`, { 'X-Api-Key': config.radarr.apiKey }],
    ['Sonarr', `${config.sonarr.url}/api/v3/system/status`, { 'X-Api-Key': config.sonarr.apiKey }],
    ['Jellyfin', `${config.jellyfin.url}/System/Info/Public`, {}],
  ];

  for (const [name, url, headers] of targets) {
    let ok = false;
    try {
      const res = await fetch(url, { headers });
      ok = res.ok;
    } catch {
      ok = false;
    }

    const previous = state.services.get(name);
    if (previous === undefined) {
      state.services.set(name, ok);
      continue;
    }

    if (previous !== ok) {
      state.services.set(name, ok);
      await sendWhatsAppMessage(`${ok ? '🟢' : '🔴'} Alerta de servicio\n\n${name} ahora está ${ok ? 'disponible' : 'caído'}.`);
    }
  }

  if (isJellyseerrConfigured()) {
    let ok = false;
    try {
      await getJellyseerrStatus();
      ok = true;
    } catch {
      ok = false;
    }
    const previous = state.services.get('Jellyseerr');
    if (previous !== undefined && previous !== ok) {
      await sendWhatsAppMessage(`${ok ? '🟢' : '🔴'} Alerta de servicio\n\nJellyseerr ahora está ${ok ? 'disponible' : 'caído'}.`);
    }
    state.services.set('Jellyseerr', ok);
  }
}

async function checkDisk() {
  try {
    const stats = await statfs('/');
    const free = stats.bavail * stats.bsize;
    const total = stats.blocks * stats.bsize;
    const freePct = total > 0 ? (free / total) * 100 : 100;

    if (freePct < 10 && !state.lowDiskAlerted) {
      state.lowDiskAlerted = true;
      await sendWhatsAppMessage(`⚠️ Alerta de disco\n\nQueda menos de 10% libre en el contenedor del bot. Libre: ${freePct.toFixed(1)}%`);
    }

    if (freePct >= 10) {
      state.lowDiskAlerted = false;
    }
  } catch {
    // ignore
  }
}

async function checkQbitStalled() {
  if (!isQbitConfigured()) {
    return;
  }

  try {
    const torrents = await getActiveTorrents();
    const now = Date.now();

    torrents.forEach((torrent) => {
      const prev = state.stalled.get(torrent.name);
      if (!prev) {
        state.stalled.set(torrent.name, { progress: torrent.progress, since: now, alerted: false });
        return;
      }

      if (prev.progress === torrent.progress) {
        if (!prev.alerted && now - prev.since > 30 * 60 * 1000) {
          prev.alerted = true;
          sendWhatsAppMessage(`⚠️ qBittorrent trabado\n\n${torrent.name}\nSigue en ${torrent.progress}% hace más de 30 minutos.`).catch(() => {});
        }
      } else {
        state.stalled.set(torrent.name, { progress: torrent.progress, since: now, alerted: false });
      }
    });
  } catch {
    // ignore
  }
}

async function checkMount() {
  let healthy = false;
  try {
    healthy = EXPECTED_MOUNT_DIRS.every((d) => fs.existsSync(d));
  } catch {
    healthy = false;
  }

  const previous = state.mountHealthy;

  if (previous === true && healthy === false) {
    state.mountHealthy = false;
    await sendWhatsAppMessage(`🔴 Alerta de montura\n\n/mnt/media se ha desconectado.\nLos contenedores de medios no podrán acceder a los archivos.`);
  } else if (previous === false && healthy === true) {
    state.mountHealthy = true;
    await sendWhatsAppMessage(`🟢 Montura recuperada\n\n/mnt/media está disponible nuevamente.`);
  } else if (previous === null) {
    state.mountHealthy = healthy;
  }
}

async function checkProviderHealth() {
  const checks = [];

  if (config.radarr.url) {
    checks.push({ name: 'Radarr', url: `${config.radarr.url}/api/v3/health`, headers: { 'X-Api-Key': config.radarr.apiKey } });
  }
  if (config.sonarr.url) {
    checks.push({ name: 'Sonarr', url: `${config.sonarr.url}/api/v1/health`, headers: { 'X-Api-Key': config.sonarr.apiKey } });
  }
  if (config.prowlarr.url) {
    checks.push({ name: 'Prowlarr', url: `${config.prowlarr.url}/api/v1/health`, headers: { 'X-Api-Key': config.prowlarr.apiKey } });
  }

  for (const { name, url, headers } of checks) {
    try {
      const res = await fetch(url, { headers });
      const health = await res.json();
      const key = `${name}:health`;

      if (Array.isArray(health) && health.length > 0) {
        const warnings = health.map((h) => `• ${h.message || h.type || JSON.stringify(h)}`).join('\n');
        if (!state.healthAlerted.get(key)) {
          state.healthAlerted.set(key, true);
          await sendWhatsAppMessage(`⚠️ Problemas en ${name}\n\n${warnings}`);
        }
      } else {
        if (state.healthAlerted.get(key)) {
          state.healthAlerted.set(key, false);
          await sendWhatsAppMessage(`🟢 ${name} sin problemas de salud`);
        }
        state.healthAlerted.set(key, false);
      }
    } catch {
      // service down - handled by checkServices
    }
  }
}

async function checkSubtitleGaps() {
  if (!config.bazarr.url || !config.bazarr.apiKey) {
    return;
  }

  try {
    const res = await fetch(`${config.bazarr.url}/api/wanted?page=1&limit=1`, {
      headers: { 'X-API-KEY': config.bazarr.apiKey },
    });

    if (!res.ok) {
      return;
    }

    const data = await res.json();
    const total = data.totalRecords || data.total || 0;

    if (total !== state.lastSubtitleCount) {
      state.lastSubtitleCount = total;
      if (total > 0) {
        await sendWhatsAppMessage(`📼 Subtítulos faltantes\n\n${total} subtítulos buscados en Bazarr todavía no se han descargado.`);
      } else {
        await sendWhatsAppMessage(`📼 Subtítulos al día\n\nNo hay subtítulos pendientes en Bazarr.`);
      }
    }
  } catch {
    // ignore
  }
}

async function checkContainerUpdates() {
  for (const { name, image } of MONITORED_IMAGES) {
    try {
      const latestDigest = await getLatestDigest(image);
      const key = `update:${image}`;
      const previous = state.updateAlerted.get(key);

      if (latestDigest && previous && previous !== latestDigest) {
        state.updateAlerted.set(key, latestDigest);
        await sendWhatsAppMessage(`📦 Actualización disponible\n\n${name} (${image})\nNueva versión disponible en el registro.`);
      } else if (latestDigest && !previous) {
        state.updateAlerted.set(key, latestDigest);
      }
    } catch {
      // registry check failed, ignore
    }
  }
}

async function getLatestDigest(image) {
  let url;
  let headers = {};

  if (image.startsWith('lscr.io/linuxserver/')) {
    const name = image.replace('lscr.io/linuxserver/', '');
    url = `https://hub.docker.com/v2/repositories/linuxserver/${name}/tags/latest`;
  } else if (image.startsWith('ghcr.io/')) {
    const name = image.replace('ghcr.io/', '');
    url = `https://ghcr.io/v2/${name}/manifests/latest`;
    headers = { Accept: 'application/vnd.oci.image.manifest.v1+json' };
  } else {
    return null;
  }

  const res = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
  if (!res.ok) {
    return null;
  }

  if (image.startsWith('lscr.io/linuxserver/')) {
    const data = await res.json();
    return data.last_updated || data.tag_last_pushed || null;
  }

  // ghcr.io - get digest from header
  return res.headers.get('docker-content-digest') || null;
}

function startAlerts() {
  setInterval(() => {
    checkServices().catch(() => {});
    checkDisk().catch(() => {});
    checkQbitStalled().catch(() => {});
    checkMount().catch(() => {});
    checkProviderHealth().catch(() => {});
    checkSubtitleGaps().catch(() => {});
  }, 5 * 60 * 1000);

  setInterval(() => {
    checkContainerUpdates().catch(() => {});
  }, 6 * 60 * 60 * 1000);
}

module.exports = {
  startAlerts,
};
