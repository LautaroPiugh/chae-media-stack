const apiKey = process.env.BAZARR_API_KEY || '';
const baseUrl = process.env.BAZARR_URL || 'http://bazarr:6767';

function isConfigured() {
  return !!(baseUrl && apiKey);
}

function getHeaders() {
  return {
    'X-API-KEY': apiKey,
  };
}

async function runSeriesAction(seriesId, action) {
  if (!isConfigured()) {
    return false;
  }

  const response = await fetch(
    `${baseUrl}/api/series?seriesid=${seriesId}&action=${encodeURIComponent(action)}`,
    {
      method: 'PATCH',
      headers: getHeaders(),
    }
  );

  if (!response.ok) {
    throw new Error(`Bazarr series action error: ${response.status}`);
  }

  return true;
}

async function triggerSeriesSubtitleSearch(seriesId) {
  if (!isConfigured()) {
    return false;
  }

  await runSeriesAction(seriesId, 'sync');
  await runSeriesAction(seriesId, 'scan-disk');
  await runSeriesAction(seriesId, 'search-wanted');
  return true;
}

module.exports = {
  isConfigured,
  triggerSeriesSubtitleSearch,
};
