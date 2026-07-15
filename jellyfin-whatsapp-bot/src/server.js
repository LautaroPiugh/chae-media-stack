const express = require('express');
const config = require('./config');
const { startWhatsApp, isWhatsAppConnected, sendWhatsAppMessage, onMessage } = require('./whatsapp');
const { router: radarrWebhook } = require('./handlers/radarrWebhook');
const { router: sonarrWebhook } = require('./handlers/sonarrWebhook');
const { processCommand } = require('./commands');
const { startAlerts } = require('./alerts');

const app = express();
app.use(express.json());

app.get('/health', (req, res) => {
  res.json({
    ok: true,
    service: config.serviceName,
  });
});

app.get('/status', (req, res) => {
  res.json({
    ok: true,
    whatsappConnected: isWhatsAppConnected(),
  });
});

app.get('/test-whatsapp', async (req, res) => {
  const sent = await sendWhatsAppMessage('🧪 Test message from Jellyfin WhatsApp Bot');
  res.json({ ok: sent });
});

app.post('/notify/system-update', async (req, res) => {
  const expectedToken = config.whatsapp.updateNotifyToken;
  const providedToken = req.get('x-update-token') || '';

  if (!expectedToken || providedToken !== expectedToken) {
    res.status(401).json({ ok: false, error: 'unauthorized' });
    return;
  }

  const message = String(req.body?.message || '').trim();
  if (!message) {
    res.status(400).json({ ok: false, error: 'missing_message' });
    return;
  }

  const sent = await sendWhatsAppMessage(message);
  res.json({ ok: sent });
});

const { router: uptimeKumaWebhook } = require('./handlers/uptimeKumaWebhook');
app.use('/webhook', radarrWebhook);
app.use('/webhook', sonarrWebhook);
app.use('/webhook', uptimeKumaWebhook);

async function init() {
  await startWhatsApp();
  startAlerts();

  onMessage(async (text, userJid) => {
    const response = await processCommand(text, userJid);
    if (response) {
      await sendWhatsAppMessage(response, userJid);
    }
  });

  app.listen(config.port, () => {
    console.log(`🚀 ${config.serviceName} running on port ${config.port}`);
    console.log(`📋 Health: http://localhost:${config.port}/health`);
    console.log(`📋 Status: http://localhost:${config.port}/status`);
    console.log(`📋 Radarr Webhook: POST http://localhost:${config.port}/webhook/radarr`);
    console.log(`📋 Sonarr Webhook: POST http://localhost:${config.port}/webhook/sonarr`);
  });
}

init();
