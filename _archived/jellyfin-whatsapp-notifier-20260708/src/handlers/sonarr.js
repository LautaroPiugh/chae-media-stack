const { sendWhatsAppMessage } = require('../whatsapp');
const { formatEpisodeMessage } = require('../utils/formatMessage');

const processedEvents = new Map();
const EVENT_TTL_MS = 10 * 60 * 1000;

function getEventKey(seriesId, episodeId, episodeFileId, eventType) {
  return `sonarr:${seriesId}:${episodeId}:${episodeFileId}:${eventType}`;
}

function isEventDuplicate(seriesId, episodeId, episodeFileId, eventType) {
  const key = getEventKey(seriesId, episodeId, episodeFileId, eventType);
  if (processedEvents.has(key)) {
    return true;
  }
  processedEvents.set(key, true);
  setTimeout(() => processedEvents.delete(key), EVENT_TTL_MS);
  return false;
}

const VALID_EVENTS = ['Download', 'Upgrade'];

async function handleSonarrWebhook(payload) {
  const eventType = payload?.eventType;

  if (eventType === 'Test') {
    return { ignored: true, reason: 'Test event' };
  }

  if (!VALID_EVENTS.includes(eventType)) {
    return { ignored: true, reason: `Event type ${eventType} not relevant` };
  }

  const seriesId = payload?.series?.id;
  const episodes = payload?.episodes;
  const series = payload?.series;
  const isUpgrade = payload?.isUpgrade === true;

  if (!seriesId || !episodes || episodes.length === 0) {
    return { ignored: true, reason: 'Missing series or episodes' };
  }

  for (const ep of episodes) {
    const episodeId = ep.id;
    const episodeFileId = ep.episodeFileId || payload?.episodeFile?.id;

    if (isEventDuplicate(seriesId, episodeId, episodeFileId, eventType)) {
      return { ignored: true, reason: 'Duplicate event' };
    }
  }

  const message = formatEpisodeMessage(series, episodes, isUpgrade);
  if (!message) {
    return { ignored: true, reason: 'Failed to format message' };
  }

  const sent = await sendWhatsAppMessage(message);

  return { sent, isUpgrade };
}

module.exports = { handleSonarrWebhook };