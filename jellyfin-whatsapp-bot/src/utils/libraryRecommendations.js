const { listMovies } = require('../clients/radarrClient');
const { listSeries } = require('../clients/sonarrClient');
const { isConfigured: isJellyfinConfigured, getUserLibraryItems } = require('../clients/jellyfinClient');
const { formatPanel } = require('./panel');

function normalize(text) {
  return String(text || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function getGenres(item) {
  return item.jellyfin?.Genres || item.raw?.genres || item.genres || [];
}

function getRating(item) {
  return item.jellyfin?.CommunityRating || item.raw?.ratings?.imdb?.value || item.raw?.ratings?.value || item.rating || 0;
}

function isPlayed(item) {
  return !!(item.jellyfin?.UserData?.Played || item.jellyfin?.UserData?.PlayedPercentage >= 90);
}

function getTrailerUrl(item) {
  const trailer = (item.jellyfin?.RemoteTrailers || []).find((entry) => /youtube/i.test(entry?.Url || ''));
  return trailer?.Url || '';
}

function getOverview(item) {
  return (item.jellyfin?.Overview || item.raw?.overview || item.overview || '').trim();
}

function getLookupKeys(item, type) {
  const keys = new Set();
  const titleKey = `${normalize(item.title)}:${item.year || 0}`;
  keys.add(titleKey);

  if (type === 'movie' && item.tmdbId) {
    keys.add(`tmdb:${item.tmdbId}`);
  }

  if (type === 'series' && item.tvdbId) {
    keys.add(`tvdb:${item.tvdbId}`);
  }

  return [...keys];
}

function buildJellyfinIndex(items) {
  const index = new Map();

  items.forEach((item) => {
    const titleKey = `${normalize(item.Name)}:${item.ProductionYear || 0}`;
    index.set(titleKey, item);

    if (item.ProviderIds?.Tmdb) {
      index.set(`tmdb:${item.ProviderIds.Tmdb}`, item);
    }

    if (item.ProviderIds?.Tvdb) {
      index.set(`tvdb:${item.ProviderIds.Tvdb}`, item);
    }
  });

  return index;
}

async function enrichPool(items, type) {
  if (!isJellyfinConfigured()) {
    return items.map((item) => ({ ...item, type, jellyfin: null }));
  }

  const jellyfinItems = await getUserLibraryItems(type === 'movie' ? ['Movie'] : ['Series']).catch(() => []);
  const index = buildJellyfinIndex(jellyfinItems);

  return items.map((item) => {
    const match = getLookupKeys(item, type).map((key) => index.get(key)).find(Boolean) || null;
    return { ...item, type, jellyfin: match };
  });
}

function filterByGenre(pool, genre) {
  if (!genre) {
    return pool;
  }

  const wanted = normalize(genre);
  const aliases = {
    accion: ['accion', 'action'],
    comedia: ['comedia', 'comedy'],
    drama: ['drama'],
    terror: ['terror', 'horror'],
    horror: ['horror', 'terror'],
    romance: ['romance', 'romantic'],
    suspenso: ['suspenso', 'thriller'],
    thriller: ['thriller', 'suspenso'],
    misterio: ['misterio', 'mystery'],
    aventura: ['aventura', 'adventure'],
    fantasia: ['fantasia', 'fantasy'],
    animacion: ['animacion', 'animation'],
    documental: ['documental', 'documentary'],
    'ciencia ficcion': ['ciencia ficcion', 'science fiction', 'sci fi', 'scifi'],
  };

  const candidates = aliases[wanted] || [wanted];
  return pool.filter((item) => getGenres(item).some((entry) => candidates.some((candidate) => normalize(entry).includes(candidate))));
}

function preferUnwatched(pool) {
  const unwatched = pool.filter((item) => !isPlayed(item));
  return unwatched.length > 0 ? unwatched : pool;
}

function pickRandom(items) {
  return items[Math.floor(Math.random() * items.length)];
}

function formatSuggestion(item, heading, reason) {
  const lines = [`- ${item.type === 'movie' ? '🎬' : '📺'} ${item.title} (${item.year || 's/a'})`];

  if (item.director) {
    lines.push(`- Director: ${item.director}`);
  }

  const genres = getGenres(item);
  if (genres.length) {
    lines.push(`- Géneros: ${genres.slice(0, 3).join(', ')}`);
  }

  if (isPlayed(item)) {
    lines.push('- Estado: ya visto');
  } else if (item.jellyfin) {
    lines.push('- Estado: no visto');
  }

  const overview = getOverview(item);
  if (overview) {
    lines.push('', `Sinopsis\n${overview.slice(0, 280)}${overview.length > 280 ? '...' : ''}`);
  }

  const trailerUrl = getTrailerUrl(item);
  if (trailerUrl) {
    lines.push('', `Trailer\n${trailerUrl}`);
  }

  return formatPanel(heading, [{ lines }], `Motivo: ${reason}.`);
}

async function getLibraryPool(type = 'all') {
  const [movies, series] = await Promise.all([
    type !== 'series' ? listMovies().catch(() => []) : [],
    type !== 'movie' ? listSeries().catch(() => []) : [],
  ]);

  const [moviePool, seriesPool] = await Promise.all([
    type !== 'series' ? enrichPool(movies, 'movie') : [],
    type !== 'movie' ? enrichPool(series, 'series') : [],
  ]);

  return [...moviePool, ...seriesPool];
}

async function getRandomSuggestion(type = 'all') {
  const pool = preferUnwatched(await getLibraryPool(type));
  if (pool.length === 0) {
    return null;
  }

  return pickRandom(pool);
}

async function getRecommendedSuggestion(type = 'all', genre = '') {
  let pool = await getLibraryPool(type);
  pool = preferUnwatched(filterByGenre(pool, genre));

  if (pool.length === 0) {
    return null;
  }

  pool.sort((a, b) => getRating(b) - getRating(a));
  const top = pool.slice(0, Math.min(pool.length, 20));
  return pickRandom(top);
}

module.exports = {
  getRandomSuggestion,
  getRecommendedSuggestion,
  formatSuggestion,
};
