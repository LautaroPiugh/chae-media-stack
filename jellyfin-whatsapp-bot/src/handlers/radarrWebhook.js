const express = require('express');
const config = require('../config');
const { isDuplicate } = require('../utils/dedupe');
const { radarrMovieMessage } = require('../utils/formatMessage');
const { sendCompletionMessage } = require('../utils/requestNotifications');

const router = express.Router();

const IGNORED_EVENTS = ['Test', 'Rename', 'MovieFileDelete'];
const VALID_EVENTS = ['Download', 'Upgrade', 'HealthIssue', 'HealthRestored'];

function getQuality(movieFile) {
  return movieFile?.quality?.quality?.name || movieFile?.quality?.name || '';
}

function validateSecret(req, secret) {
  if (!secret) return true;
  return req.query.token === secret;
}

router.post('/radarr', async (req, res) => {
  if (!validateSecret(req, config.radarr.secret)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const event = req.body;
  console.log(`[Radarr webhook] Event received: ${event?.eventType || 'unknown'}`);

  if (!event || !event.eventType) {
    return res.status(400).json({ error: 'Invalid payload' });
  }

  if (IGNORED_EVENTS.includes(event.eventType)) {
    return res.json({ ok: true, reason: 'ignored event' });
  }

  if (!VALID_EVENTS.includes(event.eventType)) {
    return res.json({ ok: true, reason: 'unhandled event type' });
  }

  if (event.eventType === 'HealthIssue' || event.eventType === 'HealthRestored') {
    const isHealthy = event.eventType === 'HealthRestored';
    const { sendWhatsAppMessage } = require('../whatsapp');
    const icon = isHealthy ? '🟢' : '🔴';
    const msg = `${icon} Radarr: ${event.message || (isHealthy ? 'Salud restaurada' : 'Problema de salud')}`;
    await sendWhatsAppMessage(msg);
    return res.json({ ok: true });
  }

  if (!event.movie) {
    return res.status(400).json({ error: 'Missing movie data' });
  }

  const movieFile = event.movieFile || event.movie?.movieFile;
  if (!movieFile) {
    console.log('[Radarr webhook] Ignored: no movie file in payload');
    return res.json({ ok: true, reason: 'no movie file' });
  }

  const dedupeKey = getKey('radarr', event.movie.id, movieFile.id, event.eventType);

  if (isDuplicate(dedupeKey)) {
    return res.json({ ok: true, reason: 'duplicate event' });
  }

  const isUpgrade = event.eventType === 'Upgrade';

  const message = radarrMovieMessage({
    title: event.movie.title,
    year: event.movie.year,
    quality: getQuality(movieFile),
    size: movieFile.size,
    jellyfinUrl: config.jellyfin.url,
  }, isUpgrade);

  await sendCompletionMessage('movie', event.movie.id, message);
  console.log(`[Radarr webhook] Notification sent for ${event.movie.title}`);

  res.json({ ok: true });
});

module.exports = { router, getKey };

function getKey(...parts) {
  return parts.join(':');
}
