require('dotenv').config();
const express = require('express');
const pino = require('pino');
const { connectWhatsApp, isWhatsAppConnected } = require('./whatsapp');
const { handleRadarrWebhook } = require('./handlers/radarr');
const { handleSonarrWebhook } = require('./handlers/sonarr');

const logger = pino({ level: 'info' });
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3555;
const SERVICE_NAME = process.env.SERVICE_NAME || 'Jellyfin Notifier';

function validateSecret_query(token, secret) {
  if (!secret) return true;
  return token === secret;
}

function validateSecret_body(authorization, secret) {
  if (!secret) return true;
  return authorization === secret;
}

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: SERVICE_NAME });
});

app.get('/status', (req, res) => {
  res.json({
    whatsapp: isWhatsAppConnected() ? 'connected' : 'disconnected',
  });
});

app.post('/webhook/radarr', async (req, res) => {
  const token = req.query.token;
  const secret = process.env.RADARR_SECRET;

  if (!validateSecret_query(token, secret)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  logger.info({ body: req.body }, 'Webhook received from Radarr');

  const result = await handleRadarrWebhook(req.body);

  if (result.ignored) {
    logger.info(`Event ignored: ${result.reason}`);
    return res.json({ ignored: true, reason: result.reason });
  }

  if (result.sent) {
    return res.json({ success: true });
  } else {
    return res.status(500).json({ error: 'Failed to send message' });
  }
});

app.post('/api/message', async (req, res) => {
  const token = req.query.token;
  const secret = process.env.NOTIFY_SECRET;

  if (!validateSecret_query(token, secret)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const { text } = req.body;
  if (!text) {
    return res.status(400).json({ error: 'Missing text' });
  }

  const sent = await sendWhatsAppMessage(text);
  if (sent) {
    res.json({ success: true });
  } else {
    res.status(500).json({ error: 'Failed to send message' });
  }
});

app.post('/webhook/sonarr', async (req, res) => {
  const token = req.query.token;
  const secret = process.env.SONARR_SECRET;

  if (!validateSecret_query(token, secret)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  logger.info({ body: req.body }, 'Webhook received from Sonarr');

  const result = await handleSonarrWebhook(req.body);

  if (result.ignored) {
    logger.info(`Event ignored: ${result.reason}`);
    return res.json({ ignored: true, reason: result.reason });
  }

  if (result.sent) {
    return res.json({ success: true });
  } else {
    return res.status(500).json({ error: 'Failed to send message' });
  }
});

async function start() {
  await connectWhatsApp(process.env.WHATSAPP_TARGET);

  app.listen(PORT, () => {
    logger.info(`Service started: ${SERVICE_NAME}`);
    logger.info(`Active on port: ${PORT}`);
  });
}

start().catch((err) => {
  logger.error({ err }, 'Failed to start service');
  process.exit(1);
});