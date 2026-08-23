const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');

function getHeaders() {
  return {
    Authorization: `MediaBrowser Token="${config.jellyfin.apiKey}"`,
    'Content-Type': 'application/json',
  };
}

function isConfigured() {
  return !!(config.jellyfin.url && config.jellyfin.apiKey && config.jellyfin.userId);
}

async function getUserLibraryItems(includeItemTypes = ['Movie', 'Series']) {
  if (!isConfigured()) {
    return [];
  }

  const params = new URLSearchParams({
    Recursive: 'true',
    IncludeItemTypes: includeItemTypes.join(','),
    Fields: 'Overview,Genres,ProductionYear,RemoteTrailers,ProviderIds,UserData,CommunityRating',
    SortBy: 'SortName',
  });

  const res = await fetchWithTimeout(`${config.jellyfin.url}/Users/${config.jellyfin.userId}/Items?${params.toString()}`, {
    headers: getHeaders(),
  });

  if (!res.ok) {
    throw new Error(`Jellyfin items error: ${res.status}`);
  }

  const payload = await res.json();
  return payload.Items || [];
}

async function getWatchedMovies() {
  if (!isConfigured()) {
    return [];
  }

  const params = new URLSearchParams({
    Recursive: 'true',
    IncludeItemTypes: 'Movie',
    IsPlayed: 'true',
    Fields: 'ProviderIds,UserData,ProductionYear',
  });

  const res = await fetchWithTimeout(`${config.jellyfin.url}/Users/${config.jellyfin.userId}/Items?${params.toString()}`, {
    headers: getHeaders(),
  });

  if (!res.ok) {
    throw new Error(`Jellyfin watched items error: ${res.status}`);
  }

  const payload = await res.json();

  return (payload.Items || []).map((item) => ({
    id: item.Id,
    name: item.Name,
    year: item.ProductionYear || 0,
    tmdbId: item.ProviderIds?.Tmdb ? parseInt(item.ProviderIds.Tmdb, 10) : null,
    played: item.UserData?.Played || false,
  }));
}

async function deleteJellyfinItem(itemId) {
  const res = await fetchWithTimeout(`${config.jellyfin.url}/Items/${itemId}`, {
    method: 'DELETE',
    headers: getHeaders(),
  });

  if (!res.ok && res.status !== 204) {
    throw new Error(`Jellyfin delete error: ${res.status}`);
  }

  return true;
}

module.exports = {
  isConfigured,
  getUserLibraryItems,
  getWatchedMovies,
  deleteJellyfinItem,
};
