const { searchMovie, listQualityProfiles } = require('../clients/radarrClient');
const { setPending } = require('../store/pendingSelections');
const { formatBrowsePage, formatErrorPanel } = require('../utils/formatMessage');

function parseMovieQuery(rawQuery) {
  const query = rawQuery.trim();
  const match = query.match(/\s+(4k|2160p|1080p)$/i);
  if (!match) {
    return { query, preferredQuality: null };
  }

  return {
    query: query.slice(0, -match[0].length).trim(),
    preferredQuality: match[1].toLowerCase(),
  };
}

async function resolveQualityProfileId(preferredQuality) {
  if (!preferredQuality) {
    return null;
  }

  const profiles = await listQualityProfiles();
  const wants4k = preferredQuality === '4k' || preferredQuality === '2160p';
  const preferredNames = wants4k
    ? ['ultra-hd', '4k']
    : ['hd-1080p', '1080p'];

  const match = profiles.find((profile) =>
    preferredNames.some((name) => String(profile.name || '').toLowerCase().includes(name))
  );

  return match?.id || null;
}

async function handleMovieSearch(text, userJid) {
  const rawQuery = text.replace(/^\/peli\s*/i, '').replace(/^\/pelicula\s*/i, '').trim();
  const { query, preferredQuality } = parseMovieQuery(rawQuery);

  if (!query) {
    return formatErrorPanel('Búsqueda de película', [
      '- Usá /peli seguido del nombre de la película',
      '- Ejemplo: /peli matrix',
    ]);
  }

  try {
    const preferredQualityProfileId = await resolveQualityProfileId(preferredQuality);
    const results = await searchMovie(query);

    if (!results || results.length === 0) {
      return formatErrorPanel('Sin resultados', [`- No encontré películas para "${query}"`]);
    }

    setPending(userJid, {
      type: 'movie',
      mode: 'search',
      query,
      preferredQuality,
      preferredQualityProfileId,
      results,
      page: 0,
      pageSize: 5,
    });

    return formatBrowsePage({
      type: 'movie',
      mode: 'search',
      query,
      results,
      page: 0,
      pageSize: 5,
    });
  } catch (error) {
    return formatErrorPanel('Error en Radarr', ['- No pude buscar en Radarr', `- ${error.message}`]);
  }
}

module.exports = { handleMovieSearch };
