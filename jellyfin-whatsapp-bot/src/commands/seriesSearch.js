const { searchSeries } = require('../clients/sonarrClient');
const { setPending } = require('../store/pendingSelections');
const { formatBrowsePage, formatErrorPanel } = require('../utils/formatMessage');

async function handleSeriesSearch(text, userJid) {
  const query = text.replace(/^\/serie\s*/i, '').replace(/^\/series\s*/i, '').trim();

  if (!query) {
    return formatErrorPanel('Búsqueda de serie', [
      '- Usá /serie seguido del nombre de la serie',
      '- Ejemplo: /serie breaking bad',
    ]);
  }

  try {
    const results = await searchSeries(query);

    if (!results || results.length === 0) {
      return formatErrorPanel('Sin resultados', [`- No encontré series para "${query}"`]);
    }

    setPending(userJid, {
      type: 'series',
      mode: 'search',
      query,
      results,
      page: 0,
      pageSize: 5,
    });

    return formatBrowsePage({
      type: 'series',
      mode: 'search',
      query,
      results,
      page: 0,
      pageSize: 5,
    });
  } catch (error) {
    return formatErrorPanel('Error en Sonarr', ['- No pude buscar en Sonarr', `- ${error.message}`]);
  }
}

module.exports = { handleSeriesSearch };
