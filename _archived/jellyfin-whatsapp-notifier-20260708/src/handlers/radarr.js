const { sendWhatsAppMessage } = require('../whatsapp');
const { formatMovieMessage } = require('../utils/formatMessage');

const processedEvents = new Map();
const EVENT_TTL_MS = 10 * 60 * 1000;

function getEventKey(eventType, movieId, movieFileId) {
  return `radarr:${movieId}:${movieFileId}:${eventType}`;
}

function isEventDuplicate(movieId, movieFileId, eventType) {
  const key = getEventKey(eventType, movieId, movieFileId);
  if (processedEvents.has(key)) {
    return true;
  }
  processedEvents.set(key, true);
  setTimeout(() => processedEvents.delete(key), EVENT_TTL_MS);
  return false;
}

const VALID_EVENTS = ['Download', 'Upgrade'];

async function handleRadarrWebhook(payload) {
  const eventType = payload?.eventType;

  if (eventType === 'Test') {
    return { ignored: true, reason: 'Test event' };
  }

  if (!VALID_EVENTS.includes(eventType)) {
    return { ignored: true, reason: `Event type ${eventType} not relevant` };
  }

  const movieId = payload?.movie?.id;
  const movieFileId = payload?.movieFile?.id;
  const movie = payload?.movie;
  const isUpgrade = payload?.isUpgrade === true;

  if (!movieId || !movieFileId) {
    return { ignored: true, reason: 'Missing movie or file ID' };
  }

  if (isEventDuplicate(movieId, movieFileId, eventType)) {
    return { ignored: true, reason: 'Duplicate event' };
  }

  const message = formatMovieMessage(movie, isUpgrade);
  const sent = await sendWhatsAppMessage(message);

  return { sent, isUpgrade };
}

module.exports = { handleRadarrWebhook };