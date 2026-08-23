const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');

function getHeaders() {
  return {
    Authorization: `Bearer ${config.tmdb.accessToken}`,
    'Content-Type': 'application/json',
  };
}

function isConfigured() {
  return !!(config.tmdb.accessToken || config.tmdb.apiKey);
}

async function getTrending(timeWindow = 'week') {
  if (!isConfigured()) {
    throw new Error('TMDB no esta configurado. Revisa TMDB_API_KEY en .env.');
  }

  const res = await fetchWithTimeout(
    `https://api.themoviedb.org/3/trending/movie/${timeWindow}?language=es`,
    { headers: getHeaders() }
  );

  if (!res.ok) {
    throw new Error(`TMDB API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();

  return (data.results || []).map((movie) => ({
    tmdbId: movie.id,
    title: movie.title,
    originalTitle: movie.original_title,
    release_date: movie.release_date || '',
    year: movie.release_date ? new Date(movie.release_date).getFullYear() : 0,
    overview: movie.overview || '',
    voteAverage: movie.vote_average || 0,
    popularity: movie.popularity || 0,
    posterPath: movie.poster_path || '',
  }));
}

module.exports = { isConfigured, getTrending };
