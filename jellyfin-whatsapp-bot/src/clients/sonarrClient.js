const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');

function getHeaders() {
  return {
    'X-Api-Key': config.sonarr.apiKey,
    'Content-Type': 'application/json',
  };
}

function scoreSeries(series, query) {
  const normalizedQuery = query.toLowerCase().trim();
  const title = (series.title || '').toLowerCase();
  const originalTitle = (series.originalTitle || '').toLowerCase();
  const cleanTitle = title.replace(/[^a-z0-9\s]/g, ' ').trim();
  const cleanOriginalTitle = originalTitle.replace(/[^a-z0-9\s]/g, ' ').trim();

  if (title === normalizedQuery || originalTitle === normalizedQuery) return 100;
  if (cleanTitle === normalizedQuery || cleanOriginalTitle === normalizedQuery) return 95;
  if (title.startsWith(normalizedQuery) || originalTitle.startsWith(normalizedQuery)) return 80;
  if (cleanTitle.startsWith(normalizedQuery) || cleanOriginalTitle.startsWith(normalizedQuery)) return 75;
  if (title.includes(normalizedQuery) || originalTitle.includes(normalizedQuery)) return 60;
  return 0;
}

function getSeriesRank(series, query) {
  const matchScore = scoreSeries(series, query);
  const rating = series.ratings?.value || 0;
  const popularity = series.popularity || 0;
  const voteCount = series.statistics?.voteCount || series.voteCount || 0;
  const year = series.year || 0;
  const currentYear = new Date().getFullYear();
  const agePenalty = year > 0 ? Math.max(0, currentYear - year - 15) * 0.3 : 0;

  return (matchScore * 1000) + (rating * 20) + popularity + (voteCount * 0.02) - agePenalty;
}

function mapSeries(series) {
  return {
    title: series.title,
    originalTitle: series.originalTitle,
    year: series.year,
    added: series.added,
    tvdbId: series.tvdbId,
    overview: series.overview,
    remotePoster: series.remotePoster,
    popularity: series.popularity || 0,
    rating: series.ratings?.value || 0,
    episodeFileCount: series.statistics?.episodeFileCount || 0,
    totalEpisodeCount: series.statistics?.totalEpisodeCount || 0,
    seasons: series.seasons || [],
    genres: series.genres || [],
    raw: series,
  };
}

async function searchSeries(query) {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const url = `${config.sonarr.url}/api/v3/series/lookup?term=${encodeURIComponent(query)}`;

  const res = await fetchWithTimeout(url, { headers: getHeaders() });

  if (!res.ok) {
    throw new Error(`Sonarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();

  return data
    .sort((a, b) => {
      const rankDiff = getSeriesRank(b, query) - getSeriesRank(a, query);
      if (rankDiff !== 0) return rankDiff;

      const ratingDiff = (b.ratings?.value || 0) - (a.ratings?.value || 0);
      if (ratingDiff !== 0) return ratingDiff;

      return (b.year || 0) - (a.year || 0);
    })
    .slice(0, 15)
    .map(mapSeries);
}

async function addSeries(series, options = {}) {
  const url = `${config.sonarr.url}/api/v3/series`;

  const payload = {
    title: series.title,
    tvdbId: series.tvdbId,
    qualityProfileId: config.sonarr.qualityProfileId,
    languageProfileId: config.sonarr.languageProfileId,
    rootFolderPath: config.sonarr.rootFolder,
    seasonFolder: true,
    monitored: true,
    ...options,
  };

  if (!payload.addOptions) {
    payload.addOptions = {
      monitor: 1,
      searchForMissingEpisodes: true,
    };
  }

  const res = await fetchWithTimeout(url, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Sonarr API error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function getSeriesById(seriesId) {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/series/${seriesId}`, {
    headers: getHeaders(),
  });

  if (!res.ok) {
    throw new Error(`Sonarr API error: ${res.status} ${res.statusText}`);
  }

  return await res.json();
}

async function setSeriesSeasonMonitoring(seriesId, selectedSeason) {
  const series = await getSeriesById(seriesId);

  series.seasons = (series.seasons || []).map((season) => ({
    ...season,
    monitored: season.seasonNumber === selectedSeason,
  }));

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/series/${seriesId}`, {
    method: 'PUT',
    headers: getHeaders(),
    body: JSON.stringify(series),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Sonarr update error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function searchExistingSeries(seriesId) {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const url = `${config.sonarr.url}/api/v3/command`;
  const payload = {
    name: 'SeriesSearch',
    seriesId,
  };

  const res = await fetchWithTimeout(url, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Sonarr command error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function refreshExistingSeries(seriesId) {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/command`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      name: 'RefreshSeries',
      seriesId,
    }),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Sonarr command error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function rescanExistingSeries(seriesId) {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/command`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      name: 'RescanSeries',
      seriesId,
    }),
  });

  if (!res.ok) {
    const error = await res.json().catch(() => ({}));
    throw new Error(`Sonarr command error: ${res.status} - ${JSON.stringify(error)}`);
  }

  return await res.json();
}

async function getQueue() {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    return [];
  }

  const url = `${config.sonarr.url}/api/v3/queue?page=1`;

  const res = await fetchWithTimeout(url, { headers: getHeaders() });

  if (!res.ok) {
    return [];
  }

  const data = await res.json();

  return (data.records || []).map((item) => ({
    title: item.series?.title || item.title,
    episode: item.episode?.episodeNumber ? `S${String(item.episode.seasonNumber).padStart(2, '0')}E${String(item.episode.episodeNumber).padStart(2, '0')}` : '',
    progress: item.progress ? Math.round(item.progress * 100) : 0,
    status: item.status,
    errorMessage: item.errorMessage || '',
    trackedDownloadState: item.trackedDownloadState || '',
  }));
}

async function listSeries() {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/series`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Sonarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return data
    .filter((series) => (series.statistics?.episodeFileCount || 0) > 0)
    .sort((a, b) => a.title.localeCompare(b.title))
    .map(mapSeries);
}

async function listMissingSeries() {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/series`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Sonarr API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return data
    .filter((series) => series.monitored && ((series.statistics?.episodeFileCount || 0) < (series.statistics?.totalEpisodeCount || 0) || (series.statistics?.episodeFileCount || 0) === 0))
    .sort((a, b) => a.title.localeCompare(b.title))
    .map(mapSeries);
}

async function searchAllMissingSeries() {
  const missing = await listMissingSeries();
  if (missing.length === 0) return { triggered: 0 };

  const url = `${config.sonarr.url}/api/v3/command`;
  let triggered = 0;

  for (const s of missing) {
    await fetchWithTimeout(url, {
      method: 'POST',
      headers: getHeaders(),
      body: JSON.stringify({ name: 'SeriesSearch', seriesId: s.raw.id }),
    });
    triggered++;
  }

  return { triggered };
}

async function deleteSeries(seriesId) {
  if (!config.sonarr.url || !config.sonarr.apiKey) {
    throw new Error('Sonarr no está configurado. Revisá SONARR_URL y SONARR_API_KEY.');
  }

  const res = await fetchWithTimeout(`${config.sonarr.url}/api/v3/series/${seriesId}?deleteFiles=true&addImportListExclusion=false`, {
    method: 'DELETE',
    headers: getHeaders(),
  });

  if (!res.ok) {
    throw new Error(`Sonarr delete error: ${res.status} ${res.statusText}`);
  }
}

module.exports = {
  searchSeries,
  addSeries,
  getSeriesById,
  setSeriesSeasonMonitoring,
  searchExistingSeries,
  refreshExistingSeries,
  rescanExistingSeries,
  listSeries,
  listMissingSeries,
  searchAllMissingSeries,
  deleteSeries,
  getQueue,
};
