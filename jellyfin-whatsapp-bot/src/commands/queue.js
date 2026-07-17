const { getQueue: getRadarrQueue } = require('../clients/radarrClient');
const { getQueue: getSonarrQueue } = require('../clients/sonarrClient');
const { getActiveTorrents, isConfigured: isQbitConfigured } = require('../clients/qbittorrentClient');
const { remember } = require('../utils/cache');
const { formatPanel } = require('../utils/panel');

function humanEta(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0 || seconds > 8640000) {
    return null;
  }

  if (seconds < 60) {
    return `${seconds}s`;
  }

  if (seconds < 3600) {
    return `${Math.round(seconds / 60)} min`;
  }

  if (seconds < 86400) {
    return `${Math.round(seconds / 3600)} h`;
  }

  return `${Math.round(seconds / 86400)} d`;
}

function humanSpeed(bytesPerSec) {
  if (!bytesPerSec || bytesPerSec <= 0) {
    return null;
  }

  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  let size = bytesPerSec;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  return `${size.toFixed(size >= 10 || unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

function formatQueueStatus(item) {
  if (item.progress > 0) {
    return `descargando (${item.progress}%)`;
  }

  if (!item.status) {
    return 'esperando';
  }

  const status = String(item.status).toLowerCase();

  if (status === 'warning') {
    return 'con problema';
  }

  if (status === 'queued') {
    return 'en cola';
  }

  if (status === 'downloading') {
    return 'descargando';
  }

  return status;
}

function formatQueueLine(item, suffix = '') {
  const status = formatQueueStatus(item);
  const icon = status.includes('problema') ? '⚠️' : status.includes('cola') || status === 'esperando' ? '🕒' : '⬇️';
  const extras = [];

  if (item.errorMessage) {
    extras.push(`motivo: ${item.errorMessage}`);
  } else if (item.trackedDownloadState) {
    extras.push(`estado interno: ${item.trackedDownloadState}`);
  }

  return `- ${icon} ${item.title}${suffix}: ${status}${extras.length ? ` | ${extras.join(' | ')}` : ''}`;
}

function partitionQueueItems(items) {
  const statusOf = (item) => String(item.status || '').toLowerCase();
  const isIssue = (item) => ['warning', 'failed', 'error'].includes(statusOf(item));

  return {
    downloading: items.filter((item) => !isIssue(item) && (item.progress > 0 || statusOf(item) === 'downloading')),
    queued: items.filter((item) => !isIssue(item) && item.progress <= 0 && ['queued', 'delay', 'paused', 'pending'].includes(statusOf(item))),
    issues: items.filter((item) => isIssue(item)),
    waiting: items.filter((item) => !isIssue(item) && item.progress <= 0 && !['queued', 'delay', 'paused', 'pending', 'downloading'].includes(statusOf(item))),
  };
}

function buildQueueSectionLines(items, formatter) {
  const parts = partitionQueueItems(items);
  const lines = [];

  if (parts.downloading.length > 0) {
    lines.push('Descargando');
    lines.push(...parts.downloading.map(formatter));
    lines.push('');
  }

  if (parts.queued.length > 0 || parts.waiting.length > 0) {
    lines.push('En espera');
    lines.push(...parts.queued.map(formatter));
    lines.push(...parts.waiting.map(formatter));
    lines.push('');
  }

  if (parts.issues.length > 0) {
    lines.push('Con problema');
    lines.push(...parts.issues.map(formatter));
    lines.push('');
  }

  return lines.filter((line, index, arr) => !(line === '' && (index === arr.length - 1 || arr[index - 1] === '')));
}

function summarizeQueueParts(items) {
  const parts = partitionQueueItems(items);
  return {
    downloading: parts.downloading.length,
    queued: parts.queued.length + parts.waiting.length,
    issues: parts.issues.length,
    total: items.length,
  };
}

function formatSummaryLine(label, summary) {
  return `- ${label}: ${summary.total} total | ${summary.downloading} descargando | ${summary.queued} en espera | ${summary.issues} con problema`;
}

function formatTorrentLine(torrent) {
  const state = String(torrent.state || '').toLowerCase();
  const issueStates = ['error', 'missingfiles', 'stalleddl'];
  const queuedStates = ['queueddl', 'pauseddl', 'metadl', 'forcedmetadl'];
  const icon = issueStates.includes(state) ? '⚠️' : queuedStates.includes(state) ? '🕒' : '⬇️';
  const parts = [`- ${icon} ${torrent.name}: ${torrent.progress}%`];
  const speed = humanSpeed(torrent.dlspeed);
  const eta = humanEta(torrent.eta);
  if (speed) parts.push(speed);
  if (eta) parts.push(`ETA ${eta}`);
  if (state) parts.push(state);
  return parts.join(' | ');
}

async function handleQueue() {
  return remember('command:queue', 30000, async () => {
    const [radarrQueue, sonarrQueue, torrents] = await Promise.all([
      getRadarrQueue().catch(() => []),
      getSonarrQueue().catch(() => []),
      isQbitConfigured() ? getActiveTorrents().catch(() => []) : [],
    ]);

    const radarrMovies = radarrQueue.filter((q) => q.title && q.status !== 'downloadClientUnavailable');
    const sonarrEpisodes = sonarrQueue.filter((q) => q.title);
    const movieSummary = summarizeQueueParts(radarrMovies);
    const seriesSummary = summarizeQueueParts(sonarrEpisodes);

    if (radarrMovies.length === 0 && sonarrEpisodes.length === 0 && torrents.length === 0) {
      return formatPanel('Descargas', [
        {
          lines: ['- No hay descargas activas en este momento'],
        },
      ]);
    }

    return formatPanel('Descargas', [
      {
        title: 'Resumen',
        lines: [
          formatSummaryLine('Películas', movieSummary),
          formatSummaryLine('Series', seriesSummary),
          `- Torrents activos: ${torrents.length}`,
        ],
      },
      {
        title: 'Películas',
        lines: radarrMovies.length === 0 ? ['- Sin películas en cola ahora'] : buildQueueSectionLines(radarrMovies, (item) => formatQueueLine(item)),
      },
      {
        title: 'Series',
        lines: sonarrEpisodes.length === 0
          ? ['- Sin episodios en cola ahora']
          : buildQueueSectionLines(sonarrEpisodes, (item) => {
              const ep = item.episode ? ` ${item.episode}` : '';
              return formatQueueLine(item, ep);
            }),
      },
      {
        title: 'qBittorrent',
        lines: torrents.length === 0
          ? ['- Sin torrents descargando ahora']
          : torrents.slice(0, 10).map((torrent) => formatTorrentLine(torrent)),
      },
    ]);
  });
}

module.exports = { handleQueue };
