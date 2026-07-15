const { handleHelp } = require('./help');
const { handleStatus } = require('./status');
const { handleMovieSearch } = require('./movieSearch');
const { handleSeriesSearch } = require('./seriesSearch');
const { handleSearch } = require('./search');
const { handleSelection } = require('./confirmSelection');
const { handleQueue } = require('./queue');
const { handleRepeat, handleMore, handleCancel } = require('./searchFlow');
const { handleCatalog, handleMissing } = require('./library');
const { handleDownloads } = require('./downloads');
const { handleRequests, handleMyRequests } = require('./requests');
const { handleSpace } = require('./space');
const { handleRandom } = require('./random');
const { handleRecommend } = require('./recommend');
const { handleDeleteSearch, handleDeleteSelect, handleDeleteConfirm } = require('./delete');
const { handleUpdateSearch, handleUpdateSelect, handleActualizarMass } = require('./update');
const { handleRefreshSearch, handleRefreshSelect } = require('./refresh');
const { handleLatest } = require('./latest');
const { handleReconnect, handleRestart, handleCleanTorrents, isAdminUser, formatNoPermission, markAdminVerified } = require('./admin');
const { handleSubs } = require('./subs');
const { handleTraducir } = require('./traducir');
const { handleAdguardWhitelist, handleAdguardOff, handleAdguardOn, handleAdguardStatus } = require('./adguard');
const { handleTrending, handleTrendingSelect } = require('./trending');
const { formatPanel } = require('../utils/panel');
const { getPending } = require('../store/pendingSelections');
const { formatErrorPanel } = require('../utils/formatMessage');

function getFallbackMessage(text, isAdmin) {
  const lower = text.toLowerCase().trim();
  const suggestions = [];

  if (lower.includes('estado') || lower.includes('anda') || lower.includes('funciona')) {
    suggestions.push('/status');
  }

  if (lower.includes('peli') || lower.includes('pelicula') || lower.includes('movie')) {
    suggestions.push('/peli nombre');
  }

  if (lower.includes('serie') || lower.includes('capitulo') || lower.includes('episodio')) {
    suggestions.push('/serie nombre');
  }

  if (lower.includes('buscar') || lower.includes('encontrar')) {
    suggestions.push('/buscar nombre');
  }

  if (lower.includes('cola') || lower.includes('torrent') || lower.includes('descarga')) {
    suggestions.push('/cola');
  }

  if (lower.includes('pedido') || lower.includes('request')) {
    suggestions.push('/pedidos');
  }

  if (lower.includes('mispedidos') || lower.includes('mis pedidos')) {
    suggestions.push('/mispedidos');
  }

  if (lower.includes('espacio') || lower.includes('disco') || lower.includes('almacenamiento')) {
    suggestions.push('/espacio');
  }

  if (lower.includes('borrar') || lower.includes('eliminar')) {
    if (isAdmin) {
      suggestions.push('/eliminar nombre');
    }
  }

  if (lower.includes('actualizar') || lower.includes('buscar de nuevo') || lower.includes('reintentar')) {
    suggestions.push('/actualizar nombre');
    if (isAdmin) {
      suggestions.push('/actualizar todo — buscar faltantes');
      suggestions.push('/refrescar nombre');
    }
  }

  if (lower.includes('ultimo') || lower.includes('último') || lower.includes('recien') || lower.includes('recién')) {
    suggestions.push('/ultimo');
  }

  const uniqueSuggestions = [...new Set(suggestions)].slice(0, 3);
  if (uniqueSuggestions.length === 0) {
    return formatErrorPanel('Mensaje no reconocido', [
      '- Usá un comando válido',
      '- Probá con /ayuda',
    ]);
  }

  return formatErrorPanel('Mensaje no reconocido', [
    '- Tal vez querías usar:',
    ...uniqueSuggestions.map((item) => `- ${item}`),
  ]);
}

function processCommand(text, userJid) {
  const lower = text.toLowerCase().trim();
  const isAdmin = isAdminUser(userJid);

  if (lower === '/ayuda' || lower === '/help' || lower === '/ayuda admin' || lower === '/help admin') {
    return handleHelp(userJid, text);
  }

  if (lower === '/status') {
    return handleStatus();
  }

  if (lower === '/buscar' || lower.startsWith('/buscar ')) {
    return handleSearch(text);
  }

  if (lower === '/reiniciar') {
    return handleRestart(userJid);
  }

  if (lower === '/reconectar') {
    return handleReconnect(userJid);
  }

  if (lower === '/limpiartorrents' || lower === '/limpiar torrents') {
    return handleCleanTorrents(userJid);
  }

  if (lower === '/registraradmin' || lower === '/verifyadmin') {
    markAdminVerified(userJid);
    return formatPanel('Admin verificado', [
      {
        lines: [
          '- Tu sesión fue registrada como admin',
          '- Los comandos admin ahora están disponibles',
          '- Podés usar /reiniciar, /eliminar, /refrescar, etc.',
        ],
      },
    ]);
  }

  if (lower === '/pedidos' || lower === '/requests') {
    return handleRequests(userJid);
  }

  if (lower === '/mispedidos' || lower === '/mis pedidos') {
    return handleMyRequests(userJid);
  }

  if (lower === '/espacio') {
    return handleSpace();
  }

  if (lower === '/ultimo' || lower === '/último' || lower === '/recien agregado' || lower === '/recién agregado') {
    return handleLatest();
  }

  if (lower === '/actualizar' || lower === '/actualizar todo' || lower === '/actualizar all') {
    if (!isAdmin) return formatNoPermission();
    return handleActualizarMass(userJid);
  }

  if (lower.startsWith('/actualizar')) {
    return handleUpdateSearch(text, userJid);
  }

  if (lower.startsWith('/refrescar') || lower.startsWith('/refresh') || lower.startsWith('/rescaneo') || lower.startsWith('/rescan')) {
    if (!isAdmin) {
      return formatNoPermission();
    }

    return handleRefreshSearch(text, userJid);
  }

  if (lower === '/azar' || lower.startsWith('/azar ') || lower === '/random' || lower.startsWith('/random ')) {
    return handleRandom(text);
  }

  if (lower === '/recomendar' || lower.startsWith('/recomendar ')) {
    return handleRecommend(text);
  }

  if (lower === '/subs' || lower === '/subtitulos') {
    return handleSubs();
  }

  if (lower.startsWith('/traducir')) {
    return handleTraducir(text);
  }

  if (lower === '/peli' || lower === '/pelicula' || lower.startsWith('/peli ') || lower.startsWith('/pelicula ')) {
    return handleMovieSearch(text, userJid);
  }

  if (lower === '/serie' || lower === '/series' || lower.startsWith('/serie ') || lower.startsWith('/series ')) {
    return handleSeriesSearch(text, userJid);
  }

  if (lower === '/cola') {
    return handleQueue();
  }

  if (lower === '/descargas') {
    return handleDownloads();
  }

  if (lower === '/catalogo' || lower.startsWith('/catalogo ')) {
    return handleCatalog(text, userJid);
  }

  if (lower === '/faltantes' || lower.startsWith('/faltantes ')) {
    return handleMissing(text, userJid);
  }

  if (lower === '/mas') {
    return handleMore(userJid);
  }

  if (lower === '/repetir') {
    return handleRepeat(userJid);
  }

  if (lower === '/cancelar') {
    return handleCancel(userJid);
  }

  if (lower === 'confirmar eliminar') {
    if (!isAdmin) {
      return formatNoPermission();
    }

    return handleDeleteConfirm(userJid);
  }

  if (lower.startsWith('/eliminar')) {
    if (!isAdmin) {
      return formatNoPermission();
    }

    return handleDeleteSearch(text, userJid);
  }

  if (lower.startsWith('eliminar ')) {
    if (!isAdmin) {
      return formatNoPermission();
    }

    return handleDeleteSelect(text, userJid);
  }

  if (lower.startsWith('actualizar ')) {
    return handleUpdateSelect(text, userJid);
  }

  if (lower.startsWith('refrescar ') || lower.startsWith('refresh ') || lower.startsWith('rescaneo ') || lower.startsWith('rescan ')) {
    if (!isAdmin) {
      return formatNoPermission();
    }

    return handleRefreshSelect(text, userJid);
  }

  if (lower.startsWith('peli ') && userJid) {
    return handleSelection(text, userJid, 'movie');
  }

  if (lower.startsWith('serie ') && userJid) {
    return handleSelection(text, userJid, 'series');
  }

  if ((lower === 'todas' || lower.startsWith('temporada ')) && userJid) {
    const pending = getPending(userJid);
    if (pending?.mode === 'season_select' && pending.type === 'series') {
      return handleSelection(`serie ${text.trim()}`, userJid, 'series');
    }
  }

  if (/^\d+$/.test(lower) && userJid) {
    const pending = getPending(userJid);
    if (pending?.mode === 'update_quality_select') {
      return handleUpdateSelect(`actualizar ${lower}`, userJid);
    }

    if (pending?.mode === 'trending_select') {
      return handleTrendingSelect(userJid, parseInt(lower, 10));
    }

    if (!pending || !['search', 'season_select'].includes(pending.mode)) {
      return null;
    }

    const prefix = pending.mode === 'season_select' ? 'serie' : pending.type === 'movie' ? 'peli' : 'serie';
    return handleSelection(`${prefix} ${lower}`, userJid, pending.type);
  }

  if (lower.startsWith('/agu-whitelist ')) {
    if (!isAdmin) return formatNoPermission();
    return handleAdguardWhitelist(text);
  }

  if (lower === '/agu-off') {
    if (!isAdmin) return formatNoPermission();
    return handleAdguardOff();
  }

  if (lower === '/agu-on') {
    if (!isAdmin) return formatNoPermission();
    return handleAdguardOn();
  }

  if (lower === '/agu-status') {
    if (!isAdmin) return formatNoPermission();
    return handleAdguardStatus();
  }

  if (lower === '/descargar-tendencias' || lower === '/tendencias') {
    if (!isAdmin) return formatNoPermission();
    return handleTrending(userJid);
  }

  return getFallbackMessage(text, isAdmin);
}

module.exports = { processCommand };
