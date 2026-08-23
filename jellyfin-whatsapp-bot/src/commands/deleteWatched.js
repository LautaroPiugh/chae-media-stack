const { getWatchedMovies } = require('../clients/jellyfinClient');
const { listMovies, deleteMovie } = require('../clients/radarrClient');
const { deleteTorrentsByName } = require('../clients/qbittorrentClient');
const { setPending, getPending, deletePending } = require('../store/pendingSelections');
const { formatInfoPanel, formatErrorPanel } = require('../utils/formatMessage');
const { isAdminUser, formatNoPermission } = require('./admin');

function matchRadarrMovie(radarrMovies, watched) {
  if (watched.tmdbId) {
    const byTmdb = radarrMovies.find((movie) => movie.tmdbId === watched.tmdbId);
    if (byTmdb) {
      return byTmdb;
    }
  }

  const normalize = (value) => String(value || '').toLowerCase().replace(/[^a-z0-9\s]/g, ' ').replace(/\s+/g, ' ').trim();
  const name = normalize(watched.name);

  return radarrMovies.find((movie) => {
    if (!name || normalize(movie.title) !== name) {
      return false;
    }

    return !watched.year || !movie.year || movie.year === watched.year;
  });
}

async function handleWatchedPreview(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  let watched;
  let radarrMovies;

  try {
    [watched, radarrMovies] = await Promise.all([getWatchedMovies(), listMovies()]);
  } catch (error) {
    return formatErrorPanel('Películas vistas', [`- No pude leer las bibliotecas: ${error.message}`]);
  }

  const matches = [];
  const unmatched = [];

  for (const movie of watched) {
    const match = matchRadarrMovie(radarrMovies, movie);
    if (match) {
      matches.push({ jellyfin: movie, radarr: match });
    } else {
      unmatched.push(movie);
    }
  }

  if (matches.length === 0) {
    return formatInfoPanel('Películas vistas', [
      `- Hay ${watched.length} película(s) vistas pero ninguna está en Radarr`,
      '- Nada para eliminar',
    ]);
  }

  const preview = matches.slice(0, 10).map((item) => `- 🎬 ${item.radarr.title} (${item.radarr.year || 's/a'})`);
  const remaining = matches.length - preview.length;

  setPending(userJid, {
    mode: 'delete_watched_confirm',
    type: 'delete_watched',
    items: matches,
    unmatchedCount: unmatched.length,
  });

  return formatInfoPanel('Eliminar películas vistas', [
    `- ${matches.length} película(s) vistas listas para eliminar vía Radarr`,
    ...(unmatched.length > 0 ? [`- ${unmatched.length} vista(s) sin ficha en Radarr se van a saltear`] : []),
    '',
    preview.join('\n'),
    ...(remaining > 0 ? [`- ...y ${remaining} más`] : []),
    '',
    'Acciones',
    '- Esto las quita de Radarr y borra sus archivos del disco',
    '- Escribí exactamente: "confirmar eliminar vistas"',
    '- Para abortar: "/cancelar"',
  ]);
}

async function handleWatchedConfirm(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const pending = getPending(userJid);
  if (!pending || pending.mode !== 'delete_watched_confirm') {
    return formatErrorPanel('Eliminar películas vistas', [
      '- No tenés ninguna eliminación pendiente',
      '- Usá "/vistas" para empezar',
    ]);
  }

  deletePending(userJid);

  const items = pending.items || [];
  let deleted = 0;
  const failed = [];

  for (const item of items) {
    try {
      await deleteMovie(item.radarr.raw?.id ?? item.radarr.id);
      await deleteTorrentsByName(item.radarr.title, 'radarr').catch(() => 0);
      deleted += 1;
    } catch (error) {
      failed.push(`${item.radarr.title} (${item.radarr.year || 's/a'}) — ${error.message}`);
    }
  }

  const lines = [`- ${deleted} de ${items.length} película(s) eliminada(s) de Radarr y del disco`, '- Jellyfin va a actualizar la biblioteca solo'];

  if (failed.length > 0) {
    lines.push('', 'Fallaron:');
    lines.push(...failed.slice(0, 10).map((name) => `- ${name}`));
    if (failed.length > 10) {
      lines.push(`- ...y ${failed.length - 10} más`);
    }
  }

  return formatInfoPanel('Películas vistas eliminadas', lines);
}

module.exports = {
  handleWatchedPreview,
  handleWatchedConfirm,
};
