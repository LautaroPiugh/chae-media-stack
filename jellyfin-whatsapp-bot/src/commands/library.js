const { setPending } = require('../store/pendingSelections');
const { formatBrowsePage } = require('../utils/formatMessage');
const { listMovies, listMissingMovies } = require('../clients/radarrClient');
const { listSeries, listMissingSeries } = require('../clients/sonarrClient');

async function handleCatalog(text, userJid) {
  const lower = text.toLowerCase().trim();

  if (lower === '/catalogo') {
    const [movies, series] = await Promise.all([
      listMovies().catch(() => []),
      listSeries().catch(() => []),
    ]);

    return [
      '📚 Catálogo',
      '',
      `🎬 Películas descargadas: ${movies.length}`,
      `📺 Series con episodios: ${series.length}`,
      '',
      'Acciones',
      '- "/catalogo pelis"',
      '- "/catalogo series"',
      '- "/azar"',
      '- "/recomendar [género]"',
    ].join('\n');
  }

  if (!lower.includes('peli') && !lower.includes('serie')) {
    return 'Usá "/catalogo pelis" o "/catalogo series" para abrir una lista navegable.';
  }

  const isMovie = lower.includes('peli');
  const results = isMovie ? await listMovies() : await listSeries();
  const pending = {
    type: isMovie ? 'movie' : 'series',
    mode: 'catalog',
    query: isMovie ? 'películas descargadas' : 'series descargadas',
    results,
    page: 0,
    pageSize: 10,
  };

  setPending(userJid, pending);
  return formatBrowsePage(pending);
}

async function handleMissing(text, userJid) {
  const lower = text.toLowerCase().trim();

  if (lower === '/faltantes') {
    const [movies, series] = await Promise.all([
      listMissingMovies().catch(() => []),
      listMissingSeries().catch(() => []),
    ]);

    return [
      '📦 Faltantes',
      '',
      `🎬 Películas pendientes: ${movies.length}`,
      `📺 Series pendientes: ${series.length}`,
      '',
      'Acciones',
      '- "/faltantes pelis"',
      '- "/faltantes series"',
      '- "/cola"',
      '- "/actualizar nombre"',
    ].join('\n');
  }

  if (!lower.includes('peli') && !lower.includes('serie')) {
    return 'Usá "/faltantes pelis" o "/faltantes series" para abrir una lista navegable.';
  }

  const isMovie = lower.includes('peli');
  const results = isMovie ? await listMissingMovies() : await listMissingSeries();
  const pending = {
    type: isMovie ? 'movie' : 'series',
    mode: 'missing',
    query: isMovie ? 'películas pendientes' : 'series pendientes',
    results,
    page: 0,
    pageSize: 10,
  };

  setPending(userJid, pending);
  return formatBrowsePage(pending);
}

module.exports = {
  handleCatalog,
  handleMissing,
};
