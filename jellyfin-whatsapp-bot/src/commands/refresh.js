const { listSeries, refreshExistingSeries, rescanExistingSeries } = require('../clients/sonarrClient');
const { setPending, getPending, deletePending } = require('../store/pendingSelections');
const { searchLocal } = require('../utils/librarySearch');
const { formatPendingView, formatErrorPanel, formatInfoPanel } = require('../utils/formatMessage');
const { isAdminUser, formatNoPermission } = require('./admin');

async function handleRefreshSearch(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const query = text.replace(/^\/(?:refrescar|refresh|rescaneo|rescan)( serie)?\s*/i, '').trim();

  if (!query) {
    return formatErrorPanel('Refresh y rescan', [
      '- Usá /refrescar seguido del nombre de la serie',
      '- Ejemplo: /refrescar modern family',
    ]);
  }

  const results = searchLocal(await listSeries(), query, 20).map((item) => ({ ...item, kind: 'series' }));

  if (results.length === 0) {
    return formatErrorPanel('Sin resultados', [`- No encontré ninguna serie descargada para refrescar con "${query}"`]);
  }

  const pending = {
    mode: 'refresh_search',
    type: 'refresh',
    query,
    results,
    page: 0,
    pageSize: 10,
  };

  setPending(userJid, pending);
  return formatPendingView(pending);
}

async function handleRefreshSelect(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const pending = getPending(userJid);
  if (!pending || pending.mode !== 'refresh_search') {
    return formatErrorPanel('Refresh y rescan', ['- No tenés ningún refresh pendiente']);
  }

  const index = parseInt(text.replace(/^(?:refrescar|refresh|rescaneo|rescan)\s*/i, '').trim(), 10) - 1;
  if (Number.isNaN(index) || index < 0 || index >= pending.results.length) {
    return formatErrorPanel('Número inválido', [`- Elegí entre 1 y ${pending.results.length}`]);
  }

  const item = pending.results[index];
  deletePending(userJid);

  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  await refreshExistingSeries(item.raw.id);
  await rescanExistingSeries(item.raw.id);

  return formatInfoPanel('Serie refrescada', [
    `- 📺 ${item.title} (${item.year || 's/a'})`,
    '- Relancé el refresh de metadata',
    '- Relancé el rescan de archivos en Sonarr',
  ]);
}

module.exports = {
  handleRefreshSearch,
  handleRefreshSelect,
};
