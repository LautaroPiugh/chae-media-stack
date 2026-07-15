const config = require('../config');

function getHeaders() {
  return {
    'X-Emby-Token': config.jellyfin.apiKey,
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

  const res = await fetch(`${config.jellyfin.url}/Users/${config.jellyfin.userId}/Items?${params.toString()}`, {
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

  const res = await fetch(`${config.jellyfin.url}/Users/${config.jellyfin.userId}/Items?${params.toString()}`, {
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

module.exports = {
  isConfigured,
  getUserLibraryItems,
  getWatchedMovies,
};
