const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');

function getHeaders() {
  return {
    'X-Api-Key': config.radarr.apiKey,
    'Content-Type': 'application/json',
  };
}

function scoreMovie(movie, query) {
  const normalizedQuery = query.toLowerCase().trim();
  const title = (movie.title || '').toLowerCase();
  const originalTitle = (movie.originalTitle || '').toLowerCase();
  const cleanTitle = title.replace(/[^a-z0-9\s]/g, ' ').trim();
  const cleanOriginalTitle = originalTitle.replace(/[^a-z0-9\s]/g, ' ').trim();

  if (title === normalizedQuery || originalTitle === normalizedQuery) return 100;
  if (cleanTitle === normalizedQuery || cleanOriginalTitle === normalizedQuery) return 95;
  if (title.startsWith(normalizedQuery)) return 80;
  if (cleanTitle.startsWith(normalizedQuery) || cleanOriginalTitle.startsWith(normalizedQuery)) return 75;
  if (title.includes(normalizedQuery)) return 60;
  if (originalTitle.includes(normalizedQuery)) return 50;
  return 0;
}

function getMovieDirectors(movie) {
  const directors = (movie.credits || [])
    .filter((credit) => credit.personType === 'Director' || credit.job === 'Director')
    .map((credit) => credit.name)
    .filter(Boolean);

  return [...new Set(directors)].join(', ');
}

function getMovieRank(movie, query) {
  const matchScore = scoreMovie(movie, query);
  const popularity = movie.popularity || 0;
  const voteCount = movie.ratings?.votes || movie.voteCount || 0;
  const year = movie.year || 0;
  const currentYear = new Date().getFullYear();
  const agePenalty = year > 0 ? Math.max(0, currentYear - year - 15) * 0.35 : 0;

  return (matchScore * 1000) + popularity + (voteCount * 0.02) - agePenalty;
}

function mapMovie(movie) {
  return {
    id: movie.id,
    title: movie.title,
    originalTitle: movie.originalTitle,
    year: movie.year,
    added: movie.added,
    tmdbId: movie.tmdbId,
    overview: movie.overview,
    remotePoster: movie.remotePoster,
    popularity: movie.popularity || 0,
    voteCount: movie.ratings?.votes || movie.voteCount || 0,
    director: getMovieDirectors(movie),
    genres: movie.genres || [],
    raw: movie,
  };
}

async function searchMovie(query) {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const url = `${config.radarr.url}/api/v3/movie/lookup?term=${encodeURIComponent(query)}`;

  const res = await fetchWithTimeout(url, { headers: getHeaders() });

  if (!res.ok) {
    throw new Error(`Radarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();

  return data
    .sort((a, b) => {
      const rankDiff = getMovieRank(b, query) - getMovieRank(a, query);
      if (rankDiff !== 0) return rankDiff;

      const popularityDiff = (b.popularity || 0) - (a.popularity || 0);
      if (popularityDiff !== 0) return popularityDiff;

      const voteDiff = (b.ratings?.votes || b.voteCount || 0) - (a.ratings?.votes || a.voteCount || 0);
      if (voteDiff !== 0) return voteDiff;

      return (b.year || 0) - (a.year || 0);
    })
    .slice(0, 15)
    .map(mapMovie);
}

async function addMovie(movie, options = {}) {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const url = `${config.radarr.url}/api/v3/movie`;

  const folderName = movie.folder || `${movie.title} (${movie.year})`;
  const rootFolderPath = config.radarr.rootFolder;

  const payload = {
    title: movie.title,
    tmdbId: movie.tmdbId,
    qualityProfileId: options.qualityProfileId || config.radarr.qualityProfileId,
    minimumAvailability: config.radarr.minimumAvailability,
    rootFolderPath,
    path: `${rootFolderPath.replace(/\/$/, '')}/${folderName}`,
    monitored: true,
    addOptions: {
      searchForMovie: true,
    },
  };

  const res = await fetchWithTimeout(url, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Radarr API error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function listQualityProfiles() {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/qualityprofile`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Radarr API error: ${res.status} ${res.statusText}`);
  }

  return await res.json();
}

async function searchExistingMovie(movieId) {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const url = `${config.radarr.url}/api/v3/command`;
  const payload = {
    name: 'MoviesSearch',
    movieIds: [movieId],
  };

  const res = await fetchWithTimeout(url, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Radarr command error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function getMovieById(movieId) {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie/${movieId}`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Radarr API error: ${res.status} ${res.statusText}`);
  }

  return await res.json();
}

async function setMovieQualityProfile(movieId, qualityProfileId) {
  const movie = await getMovieById(movieId);
  movie.qualityProfileId = qualityProfileId;

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie/${movieId}`, {
    method: 'PUT',
    headers: getHeaders(),
    body: JSON.stringify(movie),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Radarr update error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function getQueue() {
  if (!config.radarr.url || !config.radarr.apiKey) {
    return [];
  }

  const url = `${config.radarr.url}/api/v3/queue?page=1`;

  const res = await fetchWithTimeout(url, { headers: getHeaders() });

  if (!res.ok) {
    return [];
  }

  const data = await res.json();

  return (data.records || []).map((item) => ({
    id: item.id,
    title: item.title,
    progress: item.progress ? Math.round(item.progress * 100) : 0,
    status: item.status,
    errorMessage: item.errorMessage || '',
    trackedDownloadState: item.trackedDownloadState || '',
  }));
}

async function cleanupUnavailableQueueItems() {
  if (!config.radarr.url || !config.radarr.apiKey) {
    return 0;
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/queue?page=1&pageSize=100`, { headers: getHeaders() });
  if (!res.ok) {
    return 0;
  }

  const data = await res.json();
  const staleItems = (data.records || []).filter((item) => item.status === 'downloadClientUnavailable');

  for (const item of staleItems) {
    await fetchWithTimeout(`${config.radarr.url}/api/v3/queue/${item.id}?removeFromClient=true&blocklist=true`, {
      method: 'DELETE',
      headers: getHeaders(),
    }).catch(() => null);
  }

  return staleItems.length;
}

async function listMovies() {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Radarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return data
    .filter((movie) => movie.hasFile || movie.movieFile || movie.movieFileId)
    .sort((a, b) => a.title.localeCompare(b.title))
    .map(mapMovie);
}

async function listMissingMovies() {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Radarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return data
    .filter((movie) => movie.monitored && !(movie.hasFile || movie.movieFile || movie.movieFileId))
    .sort((a, b) => a.title.localeCompare(b.title))
    .map(mapMovie);
}

async function searchAllMissingMovies() {
  const missing = await listMissingMovies();
  if (missing.length === 0) return { triggered: 0 };

  const ids = missing.map((m) => m.raw.id);
  const url = `${config.radarr.url}/api/v3/command`;

  await fetchWithTimeout(url, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({ name: 'MoviesSearch', movieIds: ids }),
  });

  return { triggered: ids.length };
}

async function deleteMovie(movieId) {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no está configurado. Revisá RADARR_URL y RADARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie/${movieId}?deleteFiles=true&addImportExclusion=false`, {
    method: 'DELETE',
    headers: getHeaders(),
  });

  if (!res.ok) {
    throw new Error(`Radarr delete error: ${res.status} ${res.statusText}`);
  }
}

async function getAllMovies() {
  if (!config.radarr.url || !config.radarr.apiKey) {
    throw new Error('Radarr no esta configurado. Revisa RADARR_URL y RADARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Radarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return data.map((movie) => ({
    id: movie.id,
    title: movie.title,
    year: movie.year,
    tmdbId: movie.tmdbId,
    hasFile: movie.hasFile || !!movie.movieFile,
    monitored: movie.monitored,
    status: movie.status,
  }));
}

async function lookupByTmdbId(tmdbId) {
  if (!config.radarr.url || !config.radarr.apiKey) {
    return null;
  }

  const res = await fetchWithTimeout(`${config.radarr.url}/api/v3/movie/lookup?term=tmdb:${tmdbId}`, {
    headers: getHeaders(),
  });

  if (!res.ok) return null;

  const data = await res.json();
  return data[0] || null;
}

module.exports = {
  searchMovie,
  addMovie,
  getMovieById,
  listQualityProfiles,
  searchExistingMovie,
  setMovieQualityProfile,
  listMovies,
  listMissingMovies,
  getAllMovies,
  lookupByTmdbId,
  deleteMovie,
  cleanupUnavailableQueueItems,
  searchAllMissingMovies,
  getQueue,
};
