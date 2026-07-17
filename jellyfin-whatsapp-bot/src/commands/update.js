const { listMovies, listQualityProfiles, searchExistingMovie, setMovieQualityProfile, searchAllMissingMovies } = require('../clients/radarrClient');
const { listSeries, searchExistingSeries, searchAllMissingSeries } = require('../clients/sonarrClient');
const { setPending, getPending, deletePending } = require('../store/pendingSelections');
const { searchLocal } = require('../utils/librarySearch');
const { formatPendingView, formatErrorPanel, formatInfoPanel } = require('../utils/formatMessage');
const { rememberMediaRequest, notifyAdminQueuedDownload } = require('../utils/requestNotifications');
const { formatPanel } = require('../utils/panel');
const { isAdminUser, formatNoPermission } = require('./admin');

function getCurrentMovieQuality(item) {
  return item.raw?.movieFile?.quality?.quality?.name || item.raw?.movieFile?.quality?.name || 'desconocida';
}

function normalizeQualityLabel(value) {
  const lower = String(value || '').toLowerCase();
  if (lower.includes('2160') || lower.includes('4k')) {
    return '4k';
  }

  if (lower.includes('1080')) {
    return '1080p';
  }

  if (lower.includes('720')) {
    return '720p';
  }

  return 'otro';
}

async function getMovieUpgradeOptions(currentQuality) {
  const profiles = await listQualityProfiles();
  const current = normalizeQualityLabel(currentQuality);
  const options = [];

  if (current !== '1080p' && current !== '4k') {
    const hd1080 = profiles.find((profile) => String(profile.name || '').toLowerCase().includes('1080p'));
    if (hd1080) {
      options.push({ key: '1080p', label: '1080p (Full HD)', qualityProfileId: hd1080.id });
    }

    const qhd1440 = profiles.find((profile) => {
      const name = String(profile.name || '').toLowerCase();
      return name.includes('1440p') || name.includes('2k');
    });

    if (qhd1440) {
      options.push({ key: '1440p', label: '1440p (2K)', qualityProfileId: qhd1440.id });
    }
  }

  if (current !== '4k') {
    const ultraHd = profiles.find((profile) => {
      const name = String(profile.name || '').toLowerCase();
      return name.includes('ultra-hd') || name.includes('4k');
    });

    if (ultraHd) {
      options.push({ key: '2160p', label: '2160p (4K)', qualityProfileId: ultraHd.id });
    }
  }

  return options;
}

function formatMovieUpdateOptions(item, options) {
  return formatPanel('Actualizar calidad', [
    {
      lines: [
        `- 🎬 ${item.title} (${item.year || 's/a'})`,
        `- Calidad actual: ${getCurrentMovieQuality(item)}`,
        '',
        'Opciones',
        ...options.map((option, index) => `- ${index + 1}. ${option.label}`),
        '',
        'Acciones',
        '- Respondé "actualizar <número>" o solo el número',
        '- Usá "/cancelar" para cerrar este flujo',
      ],
    },
  ]);
}

async function handleUpdateSearch(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const query = text.replace(/^\/actualizar( peli| serie)?\s*/i, '').trim();
  const lower = text.toLowerCase();

  if (!query) {
    return formatErrorPanel('Actualizar búsqueda', [
      '- Usá "/actualizar nombre"',
      '- Ejemplo: "/actualizar matrix"',
    ]);
  }

  let results = [];
  if (lower.startsWith('/actualizar peli')) {
    results = searchLocal(await listMovies(), query, 20).map((item) => ({ ...item, kind: 'movie' }));
  } else if (lower.startsWith('/actualizar serie')) {
    results = searchLocal(await listSeries(), query, 20).map((item) => ({ ...item, kind: 'series' }));
  } else {
    const [movies, series] = await Promise.all([listMovies(), listSeries()]);
    results = [
      ...searchLocal(movies, query, 15).map((item) => ({ ...item, kind: 'movie' })),
      ...searchLocal(series, query, 15).map((item) => ({ ...item, kind: 'series' })),
    ].slice(0, 20);
  }

  if (results.length === 0) {
    return formatErrorPanel('Sin resultados', [`- No encontré nada en tu biblioteca para actualizar con "${query}"`]);
  }

  const pending = {
    mode: 'update_search',
    type: 'update',
    query,
    results,
    page: 0,
    pageSize: 10,
  };

  setPending(userJid, pending);

  return formatPendingView(pending);
}

async function handleUpdateSelect(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const pending = getPending(userJid);
  if (!pending || !['update_search', 'update_quality_select'].includes(pending.mode)) {
    return formatErrorPanel('Actualizar búsqueda', ['- No tenés ninguna actualización pendiente']);
  }

  const index = parseInt(text.replace(/^actualizar\s*/i, '').trim(), 10) - 1;
  if (pending.mode === 'update_quality_select') {
    if (Number.isNaN(index) || index < 0 || index >= pending.options.length) {
      return formatErrorPanel('Número inválido', [`- Elegí entre 1 y ${pending.options.length}`]);
    }

    const item = pending.item;
    const option = pending.options[index];
    deletePending(userJid);

    if (!isAdminUser(userJid)) {
      return formatNoPermission();
    }

    await setMovieQualityProfile(item.raw.id, option.qualityProfileId);
    await searchExistingMovie(item.raw.id);
    rememberMediaRequest({ mediaType: 'movie', mediaId: item.raw.id, requesterJid: userJid, title: item.title, year: item.year });
    await notifyAdminQueuedDownload({ mediaType: 'movie', title: item.title, year: item.year, requesterJid: userJid, action: `upgrade a ${option.label} en Radarr` });

    return formatInfoPanel('Upgrade relanzado', [
      `- 🎬 ${item.title} (${item.year || 's/a'})`,
      `- Calidad actual: ${getCurrentMovieQuality(item)}`,
      `- Calidad objetivo: ${option.label}`,
      '- Mandé a buscar una mejor versión en Radarr',
    ]);
  }

  if (Number.isNaN(index) || index < 0 || index >= pending.results.length) {
    return formatErrorPanel('Número inválido', [`- Elegí entre 1 y ${pending.results.length}`]);
  }

  const item = pending.results[index];

  if (item.kind === 'movie') {
    const options = await getMovieUpgradeOptions(getCurrentMovieQuality(item));
    if (options.length === 0) {
      deletePending(userJid);
      return formatInfoPanel('Sin upgrade disponible', [
        `- 🎬 ${item.title} (${item.year || 's/a'})`,
        `- Calidad actual: ${getCurrentMovieQuality(item)}`,
        '- Ya está en la calidad más alta que tengo configurada para ofrecerte',
      ]);
    }

    setPending(userJid, {
      mode: 'update_quality_select',
      type: 'update',
      item,
      options,
    });

    return formatMovieUpdateOptions(item, options);
  }

  deletePending(userJid);

  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  await searchExistingSeries(item.raw.id);
  rememberMediaRequest({ mediaType: 'series', mediaId: item.raw.id, requesterJid: userJid, title: item.title, year: item.year });
  await notifyAdminQueuedDownload({ mediaType: 'series', title: item.title, year: item.year, requesterJid: userJid, action: 'actualizada en Sonarr' });
  return formatInfoPanel('Búsqueda relanzada', [`- 📺 ${item.title} (${item.year || 's/a'})`, '- Mandé a buscar de nuevo en Sonarr']);
}

async function handleActualizarMass(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const [movies, series] = await Promise.all([
    searchAllMissingMovies().catch(() => ({ triggered: 0 })),
    searchAllMissingSeries().catch(() => ({ triggered: 0 })),
  ]);

  const total = movies.triggered + series.triggered;

  return formatInfoPanel('Búsqueda masiva iniciada', [
    total > 0
      ? `- Buscando ${total} faltante(s) entre Radarr y Sonarr`
      : '- No hay nada faltante para buscar',
    ...(movies.triggered > 0 ? [`- Películas: ${movies.triggered}`] : []),
    ...(series.triggered > 0 ? [`- Series: ${series.triggered}`] : []),
    '',
    '- Revisá /cola para ver el estado',
  ]);
}

module.exports = {
  handleUpdateSearch,
  handleUpdateSelect,
  handleActualizarMass,
};
