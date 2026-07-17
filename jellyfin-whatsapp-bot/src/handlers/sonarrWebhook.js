const express = require('express');
const config = require('../config');
const { isDuplicate } = require('../utils/dedupe');
const { sonarrEpisodeMessage } = require('../utils/formatMessage');
const { sendCompletionMessage } = require('../utils/requestNotifications');
const { isValidToken } = require('../utils/httpAuth');

const router = express.Router();

const IGNORED_EVENTS = ['Test', 'Rename', 'EpisodeFileDelete'];
const VALID_EVENTS = ['Download', 'Upgrade', 'HealthIssue', 'HealthRestored'];

function getQuality(episodeFile) {
  return episodeFile?.quality?.quality?.name || episodeFile?.quality?.name || '';
}

function validateSecret(req, secret) {
  const provided = req.get('x-webhook-token') || req.query.token || '';
  return isValidToken(secret, provided);
}

router.post('/sonarr', async (req, res) => {
  if (!validateSecret(req, config.sonarr.secret)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const event = req.body;
  console.log(`[Sonarr webhook] Event received: ${event?.eventType || 'unknown'}`);

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
    const { sendWhatsAppMessage } = require('../whatsapp');
    const isHealthy = event.eventType === 'HealthRestored';
    const icon = isHealthy ? '🟢' : '🔴';
    const msg = `${icon} Sonarr: ${event.message || (isHealthy ? 'Salud restaurada' : 'Problema de salud')}`;
    await sendWhatsAppMessage(msg);
    return res.json({ ok: true });
  }

  if (!event.episodes || event.episodes.length === 0) {
    return res.json({ ok: true, reason: 'no episodes' });
  }

  const episodeFile = event.episodeFile || event.episodes[0]?.episodeFile;
  if (!episodeFile) {
    console.log('[Sonarr webhook] No episode file in payload, sending basic notification');
  }

  const series = event.series;
  if (!series) {
    return res.status(400).json({ error: 'Missing series data' });
  }

  const episodeIds = event.episodes.map((ep) => ep.id).join(',');
  const dedupeKey = getKey('sonarr', series.id, episodeFile?.id || episodeIds, event.eventType);

  if (isDuplicate(dedupeKey)) {
    return res.json({ ok: true, reason: 'duplicate event' });
  }

  const isUpgrade = event.eventType === 'Upgrade';
  const messages = [];

  if (event.episodes.length === 1) {
    const ep = event.episodes[0];
    messages.push(sonarrEpisodeMessage({
      seriesTitle: series.title,
      seasonNumber: ep.seasonNumber,
      episodeNumber: ep.episodeNumber,
      episodeTitle: ep.title,
      quality: getQuality(episodeFile),
      size: episodeFile?.size,
      jellyfinUrl: config.jellyfin.url,
    }, isUpgrade));
  } else {
    for (const ep of event.episodes) {
      messages.push(sonarrEpisodeMessage({
        seriesTitle: series.title,
        seasonNumber: ep.seasonNumber,
        episodeNumber: ep.episodeNumber,
        episodeTitle: ep.title,
        quality: getQuality(episodeFile),
        size: episodeFile?.size,
        jellyfinUrl: config.jellyfin.url,
      }, isUpgrade));
    }
  }

  for (const msg of messages) {
    await sendCompletionMessage('series', series.id, msg);
  }

  console.log('[Sonarr webhook] Notification sent');

  res.json({ ok: true });
});

module.exports = { router, getKey };

function getKey(...parts) {
  return parts.join(':');
}
