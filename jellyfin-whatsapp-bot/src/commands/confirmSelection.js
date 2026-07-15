const { getPending, deletePending, setPending } = require('../store/pendingSelections');
const { addMovie, searchExistingMovie } = require('../clients/radarrClient');
const { addSeries, searchExistingSeries, setSeriesSeasonMonitoring } = require('../clients/sonarrClient');
const { triggerSeriesSubtitleSearch } = require('../clients/bazarrClient');
const { formatPanel } = require('../utils/panel');
const { formatErrorPanel, formatInfoPanel } = require('../utils/formatMessage');
const { rememberMediaRequest, notifyAdminQueuedDownload } = require('../utils/requestNotifications');

function getSelectableSeasons(item) {
  return (item.seasons || item.raw?.seasons || [])
    .filter((season) => Number.isInteger(season.seasonNumber) && season.seasonNumber > 0)
    .map((season) => season.seasonNumber)
    .sort((a, b) => a - b);
}

function formatSeasonSelection(item, seasons) {
  return formatPanel(`Temporadas de ${item.title} (${item.year || 's/a'})`, [
    {
      lines: [
        '- Elegí si querés bajar todas las temporadas o solo una',
        '',
        'Opciones',
        '- todas',
        ...seasons.map((seasonNumber) => `- temporada ${seasonNumber}`),
      ],
    },
  ]);
}

function getSeriesMonitorOptions(choice, seasons) {
  if (choice === 'todas') {
    return {
      addOptions: {
        monitor: 1,
        searchForMissingEpisodes: true,
      },
    };
  }

  const match = choice.match(/^(?:temporada\s*)?(\d+)$/i);
  if (!match) {
    return null;
  }

  const seasonNumber = parseInt(match[1], 10);
  if (!seasons.includes(seasonNumber)) {
    return null;
  }

  return {
    addOptions: {
      monitor: 1,
      searchForMissingEpisodes: false,
      searchForCutoffUnmetEpisodes: false,
    },
    selectedSeason: seasonNumber,
  };
}

async function triggerSeriesSubtitleAutomation(seriesId) {
  try {
    await triggerSeriesSubtitleSearch(seriesId);
  } catch (error) {
    console.error(`[Bazarr] No pude disparar la búsqueda de subtítulos para serie ${seriesId}: ${error.message}`);
  }
}

async function addSelectedSeries(item, userJid, options = {}) {
  if (item.raw?.id) {
    if (options.selectedSeason) {
      await setSeriesSeasonMonitoring(item.raw.id, options.selectedSeason);
    }

    await searchExistingSeries(item.raw.id);
    await triggerSeriesSubtitleAutomation(item.raw.id);
    rememberMediaRequest({ mediaType: 'series', mediaId: item.raw.id, requesterJid: userJid, title: item.title, year: item.year });
    await notifyAdminQueuedDownload({ mediaType: 'series', title: item.title, year: item.year, requesterJid: userJid, action: 'relanzada en Sonarr' });

    return formatInfoPanel('Serie ya existente', [
      `- ✅ ${item.title} (${item.year}) ya estaba agregada en Sonarr`,
      '- Relancé la búsqueda de episodios',
      '- También lancé la búsqueda de subtítulos en español en Bazarr',
      '- Te aviso cuando haya novedades',
    ]);
  }

  const createdSeries = await addSeries(item.raw, options);
  if (options.selectedSeason) {
    await setSeriesSeasonMonitoring(createdSeries.id, options.selectedSeason);
    await searchExistingSeries(createdSeries.id);
  }

  await triggerSeriesSubtitleAutomation(createdSeries.id);
  rememberMediaRequest({ mediaType: 'series', mediaId: createdSeries.id, requesterJid: userJid, title: item.title, year: item.year });
  await notifyAdminQueuedDownload({ mediaType: 'series', title: item.title, year: item.year, requesterJid: userJid, action: 'agregada a Sonarr' });

  if (options.selectedSeason) {
    return formatInfoPanel('Serie agregada', [
      `- ✅ ${item.title} (${item.year}) fue agregada a Sonarr`,
      `- Temporada monitoreada: ${options.selectedSeason}`,
      '- También lancé la búsqueda de subtítulos en español en Bazarr',
      '- Te aviso cuando haya episodios disponibles',
    ]);
  }

  return formatInfoPanel('Serie agregada', [
    `- ✅ ${item.title} (${item.year}) fue agregada a Sonarr y enviada a buscar`,
    '- También lancé la búsqueda de subtítulos en español en Bazarr',
    '- Te aviso cuando haya episodios disponibles',
  ]);
}

async function handleSelection(text, userJid, type) {
  const pending = getPending(userJid);

  if (type === 'series' && pending?.mode === 'season_select') {
    const choice = text.replace(/^serie\s*/i, '').trim().toLowerCase();
    const item = pending.item;
    const seasons = pending.seasons || [];
    const monitorOptions = getSeriesMonitorOptions(choice, seasons);

    if (!monitorOptions) {
      return formatSeasonSelection(item, seasons);
    }

    deletePending(userJid);
    return addSelectedSeries(item, userJid, monitorOptions);
  }

  const input = text.replace(/^(peli|serie)\s*/i, '').trim();
  const index = parseInt(input, 10) - 1;

  if (isNaN(index) || index < 0) {
    return formatErrorPanel('Respuesta inválida', [
      '- Usá peli <número> o serie <número>',
      '- Ejemplo: peli 1',
    ]);
  }

  if (!pending || pending.type !== type || pending.mode !== 'search') {
    return formatErrorPanel('Sin búsqueda activa', ['- No tenés ninguna búsqueda pendiente', '- Usá /peli o /serie primero']);
  }

  const selection = pending.results || pending.selection || [];

  if (index >= selection.length) {
    return formatErrorPanel('Número inválido', [`- Elegí entre 1 y ${selection.length}`]);
  }

  const item = selection[index];
  deletePending(userJid);

  try {
    if (type === 'movie') {
      if (item.raw?.id) {
        if (item.raw?.hasFile || item.raw?.movieFile) {
          return formatInfoPanel('Película ya existente', [`- ${item.title} (${item.year}) ya estaba agregada en Radarr y figura como descargada`]);
        }

        await searchExistingMovie(item.raw.id);
        rememberMediaRequest({ mediaType: 'movie', mediaId: item.raw.id, requesterJid: userJid, title: item.title, year: item.year });
        await notifyAdminQueuedDownload({ mediaType: 'movie', title: item.title, year: item.year, requesterJid: userJid, action: 'relanzada en Radarr' });

        return formatInfoPanel('Película ya existente', [
          `- ✅ ${item.title} (${item.year}) ya estaba agregada en Radarr`,
          '- Todavía no figura como descargada',
          '- Relancé la búsqueda y te aviso cuando termine',
        ]);
      }

      const createdMovie = await addMovie(item.raw, {
        qualityProfileId: pending.preferredQualityProfileId || undefined,
      });
      rememberMediaRequest({ mediaType: 'movie', mediaId: createdMovie.id, requesterJid: userJid, title: item.title, year: item.year });
      await notifyAdminQueuedDownload({ mediaType: 'movie', title: item.title, year: item.year, requesterJid: userJid, action: 'agregada a Radarr' });

      return formatInfoPanel('Película agregada', [
        `- ✅ ${item.title} (${item.year}) fue agregada a Radarr y enviada a buscar`,
        ...(pending.preferredQuality ? [`- Preferencia aplicada: ${pending.preferredQuality}`] : []),
        '- Te aviso cuando termine de descargarse',
      ]);
    }

    if (type === 'series') {
      const seasons = getSelectableSeasons(item);

      if (seasons.length > 0 && !item.raw?.id) {
        setPending(userJid, {
          type: 'series',
          mode: 'season_select',
          item,
          seasons,
        });

        return formatSeasonSelection(item, seasons);
      }

      return addSelectedSeries(item, userJid);
    }
  } catch (error) {
    if (error.message.includes('already exists')) {
      return formatErrorPanel(`${type === 'movie' ? 'Película' : 'Serie'} ya existente`, [
        `- ${item.title} (${item.year}) ya estaba agregada en ${type === 'movie' ? 'Radarr' : 'Sonarr'}`,
      ]);
    }

    return formatErrorPanel('No pude completar la acción', [`- ${error.message}`]);
  }
}

module.exports = { handleSelection };
