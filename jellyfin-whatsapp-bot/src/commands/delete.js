const { listMovies, deleteMovie } = require('../clients/radarrClient');
const { listSeries, deleteSeries } = require('../clients/sonarrClient');
const { deleteTorrentsByName } = require('../clients/qbittorrentClient');
const { setPending, getPending, deletePending } = require('../store/pendingSelections');
const { searchLocal } = require('../utils/librarySearch');
const { formatPendingView, formatErrorPanel, formatInfoPanel } = require('../utils/formatMessage');
const { isAdminUser, formatNoPermission } = require('./admin');

async function handleDeleteSearch(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const query = text.replace(/^\/eliminar( peli| serie)?\s*/i, '').trim();
  const lower = text.toLowerCase();

  if (!query) {
    return formatErrorPanel('Eliminar de biblioteca', [
      '- Usá "/eliminar nombre"',
      '- Ejemplo: "/eliminar matrix"',
    ]);
  }

  let results = [];
  if (lower.startsWith('/eliminar peli')) {
    results = searchLocal(await listMovies(), query, 30).map((item) => ({ ...item, kind: 'movie' }));
  } else if (lower.startsWith('/eliminar serie')) {
    results = searchLocal(await listSeries(), query, 30).map((item) => ({ ...item, kind: 'series' }));
  } else {
    const [movies, series] = await Promise.all([listMovies(), listSeries()]);
    results = [
      ...searchLocal(movies, query, 20).map((item) => ({ ...item, kind: 'movie' })),
      ...searchLocal(series, query, 20).map((item) => ({ ...item, kind: 'series' })),
    ].slice(0, 30);
  }

  if (results.length === 0) {
    return formatErrorPanel('Sin resultados', [`- No encontré nada descargado para eliminar con "${query}"`]);
  }

  const pending = {
    mode: 'delete_search',
    type: 'delete',
    query,
    results,
    page: 0,
    pageSize: 10,
  };

  setPending(userJid, pending);
  return formatPendingView(pending);
}

function handleDeleteSelect(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const pending = getPending(userJid);
  if (!pending || pending.mode !== 'delete_search') {
    return formatErrorPanel('Eliminar de biblioteca', ['- No tenés ninguna eliminación pendiente']);
  }

  const index = parseInt(text.replace(/^eliminar\s*/i, '').trim(), 10) - 1;
  if (Number.isNaN(index) || index < 0 || index >= pending.results.length) {
    return formatErrorPanel('Número inválido', [`- Elegí entre 1 y ${pending.results.length}`]);
  }

  const item = pending.results[index];
  setPending(userJid, {
    mode: 'delete_confirm',
    type: 'delete',
    item,
  });

  return formatInfoPanel('Confirmación de borrado', [
    `- ${item.kind === 'movie' ? '🎬' : '📺'} ${item.title} (${item.year || 's/a'})`,
    `- Esto la quita de ${item.kind === 'movie' ? 'Radarr' : 'Sonarr'} y borra sus archivos del disco`,
    '',
    'Acciones',
    '- Escribí exactamente: "confirmar eliminar"',
    '- Para abortar: "/cancelar"',
  ]);
}

async function handleDeleteConfirm(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const pending = getPending(userJid);
  if (!pending || pending.mode !== 'delete_confirm' || !pending.item) {
    return formatErrorPanel('Confirmación de borrado', ['- No tenés ninguna eliminación pendiente para confirmar']);
  }

  const item = pending.item;
  deletePending(userJid);

  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  if (item.kind === 'movie') {
    await deleteMovie(item.raw.id);
    await deleteTorrentsByName(item.title, 'radarr').catch(() => 0);
    return formatInfoPanel('Película eliminada', [`- ${item.title} (${item.year || 's/a'}) fue eliminada de Radarr y del disco`]);
  }

  await deleteSeries(item.raw.id);
  await deleteTorrentsByName(item.title, 'sonarr').catch(() => 0);
  return formatInfoPanel('Serie eliminada', [`- ${item.title} (${item.year || 's/a'}) fue eliminada de Sonarr y del disco`]);
}

module.exports = {
  handleDeleteSearch,
  handleDeleteSelect,
  handleDeleteConfirm,
};
