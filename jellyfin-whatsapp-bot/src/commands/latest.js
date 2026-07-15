const { listMovies } = require('../clients/radarrClient');
const { listSeries } = require('../clients/sonarrClient');
const { formatPanel } = require('../utils/panel');

function getAddedTimestamp(item) {
  const rawValue = item.added || item.raw?.added || item.raw?.addedAt;
  const timestamp = rawValue ? new Date(rawValue).getTime() : 0;
  return Number.isFinite(timestamp) ? timestamp : 0;
}

function formatDate(item) {
  const rawValue = item.added || item.raw?.added || item.raw?.addedAt;
  if (!rawValue) {
    return 'fecha no disponible';
  }

  const date = new Date(rawValue);
  if (Number.isNaN(date.getTime())) {
    return 'fecha no disponible';
  }

  return date.toLocaleDateString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  });
}

async function handleLatest() {
  const [movies, series] = await Promise.all([
    listMovies().catch(() => []),
    listSeries().catch(() => []),
  ]);

  const pool = [
    ...movies.map((item) => ({ ...item, kind: 'movie' })),
    ...series.map((item) => ({ ...item, kind: 'series' })),
  ].sort((a, b) => getAddedTimestamp(b) - getAddedTimestamp(a));

  if (pool.length === 0) {
    return 'No encontré contenido descargado para mostrarte lo último agregado.';
  }

  return formatPanel('Recién agregado', [
    {
      title: 'Últimos 5',
      lines: pool.slice(0, 5).flatMap((item, index) => [
        `${index + 1}. ${item.kind === 'movie' ? '🎬' : '📺'} ${item.title} (${item.year || 's/a'})`,
        `   Agregado: ${formatDate(item)}`,
      ]),
    },
  ]);
}

module.exports = {
  handleLatest,
};
