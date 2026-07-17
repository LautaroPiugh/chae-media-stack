const { getTrending } = require('../clients/tmdbClient');
const { getWatchedMovies } = require('../clients/jellyfinClient');
const { getAllMovies, addMovie, lookupByTmdbId } = require('../clients/radarrClient');
const { getPending, deletePending } = require('../store/pendingSelections');
const { rememberMediaRequest, notifyAdminQueuedDownload } = require('../utils/requestNotifications');
const { formatPanel } = require('../utils/panel');
const { formatInfoPanel, formatErrorPanel } = require('../utils/formatMessage');
const { setPending } = require('../store/pendingSelections');
const { isAdminUser, formatNoPermission } = require('./admin');

async function fetchTrending() {
  const trending = await getTrending('week');
  const [watchedMovies, radarrMovies] = await Promise.all([
    getWatchedMovies().catch(() => []),
    getAllMovies().catch(() => []),
  ]);

  const watchedTmdbIds = new Set(watchedMovies.map((m) => m.tmdbId).filter(Boolean));
  const radarrTmdbIds = new Set(radarrMovies.map((m) => m.tmdbId).filter(Boolean));

  const now = new Date();

  const filtered = trending.filter((m) => {
    if (!m.release_date) return false;
    const release = new Date(m.release_date);
    if (isNaN(release.getTime()) || release > now) return false;
    return true;
  });

  const candidates = filtered.filter(
    (m) => !watchedTmdbIds.has(m.tmdbId) && !radarrTmdbIds.has(m.tmdbId)
  );

  const results = await Promise.allSettled(
    candidates.map(async (m) => {
      const radarrLookup = await lookupByTmdbId(m.tmdbId);
      if (radarrLookup) {
        const status = (radarrLookup.status || '').toLowerCase();
        if (status !== 'released' && status !== 'incinemas') {
          return null;
        }
      }
      return m;
    })
  );

  return results
    .map((r) => (r.status === 'fulfilled' ? r.value : null))
    .filter(Boolean);
}

async function handleTrending(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  try {
    const movies = await fetchTrending();

    if (movies.length === 0) {
      return formatPanel('Tendencias', [
        { lines: ['No hay tendencias disponibles para descargar esta semana'] },
      ]);
    }

    const total = Math.min(movies.length, 20);
    const lines = movies.slice(0, total).map(
      (m, i) => `${i + 1}. ${m.title} (${m.year || 's/a'})`
    );

    setPending(userJid, {
      mode: 'trending_select',
      movies: movies.slice(0, total),
    });

    return formatInfoPanel('Tendencias que no viste', [
      ...lines,
      '',
      `Quedaron ${total} tendencias que no viste`,
      'Cuantas queres descargar? (envia un numero)',
    ]);
  } catch (e) {
    return formatErrorPanel('Tendencias', [`Error: ${e.message}`]);
  }
}

async function handleTrendingSelect(userJid, count) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const pending = getPending(userJid);
  if (!pending || pending.mode !== 'trending_select') {
    return null;
  }

  const movies = pending.movies || [];
  const selected = movies.slice(0, count);

  if (selected.length === 0) {
    deletePending(userJid);
    return formatErrorPanel('Tendencias', ['No quedan peliculas disponibles']);
  }

  deletePending(userJid);

  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const added = [];
  const errors = [];

  for (const movie of selected) {
    try {
      const movieData = {
        title: movie.title,
        tmdbId: movie.tmdbId,
        year: movie.year,
      };
      const created = await addMovie(movieData);
      added.push(movie.title);
      rememberMediaRequest({
        mediaType: 'movie',
        mediaId: created.id,
        requesterJid: userJid,
        title: movie.title,
        year: movie.year,
      });
      notifyAdminQueuedDownload({
        mediaType: 'movie',
        title: movie.title,
        year: movie.year,
        requesterJid: userJid,
        action: 'desde tendencias',
      });
    } catch (e) {
      errors.push(`${movie.title}: ${e.message}`);
    }
  }

  const lines = [];
  if (added.length > 0) {
    lines.push(`Agregue ${added.length} pelicula${added.length === 1 ? '' : 's'} a Radarr:`);
    lines.push(...added.map((t) => `- ${t}`));
  }
  if (errors.length > 0) {
    lines.push('', 'Errores:');
    lines.push(...errors.map((e) => `- ${e}`));
  }

  return formatInfoPanel('Tendencias descargadas', lines);
}

module.exports = { handleTrending, handleTrendingSelect };
