const { searchMovie } = require('../clients/radarrClient');
const { searchSeries } = require('../clients/sonarrClient');
const { formatPanel } = require('../utils/panel');
const { formatErrorPanel } = require('../utils/formatMessage');

function formatSearchLines(items, type) {
  if (items.length === 0) {
    return ['- Sin resultados'];
  }

  return items.slice(0, 5).map((item, index) => `- ${index + 1}. ${item.title} (${item.year || 's/a'})`);
}

async function handleSearch(text) {
  const query = text.replace(/^\/buscar\s*/i, '').trim();

  if (!query) {
    return formatErrorPanel('Buscar', [
      '- Usá /buscar seguido del nombre',
      '- Ejemplo: /buscar matrix',
    ]);
  }

  const [movies, series] = await Promise.all([
    searchMovie(query).catch(() => []),
    searchSeries(query).catch(() => []),
  ]);

  if (movies.length === 0 && series.length === 0) {
    return formatErrorPanel('Buscar', [`- No encontré resultados para "${query}"`]);
  }

  return formatPanel(`Buscar: ${query}`, [
    {
      title: 'Películas',
      lines: [
        ...formatSearchLines(movies, 'movie'),
        ...(movies.length > 0 ? ['', `- Para pedir una película: /peli ${query}`] : []),
      ],
    },
    {
      title: 'Series',
      lines: [
        ...formatSearchLines(series, 'series'),
        ...(series.length > 0 ? ['', `- Para pedir una serie: /serie ${query}`] : []),
      ],
    },
  ], 'Tip: /buscar orienta; /peli y /serie abren el flujo interactivo para agregar.');
}

module.exports = {
  handleSearch,
};
