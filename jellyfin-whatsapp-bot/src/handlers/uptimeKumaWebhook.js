const express = require('express');
const config = require('../config');
const { sendWhatsAppMessage } = require('../whatsapp');
const { isValidToken } = require('../utils/httpAuth');

const router = express.Router();

router.post('/uptime-kuma', async (req, res) => {
  const providedToken = req.get('x-update-token') || req.get('x-webhook-token') || '';
  if (!isValidToken(config.webhooks.uptimeKumaSecret, providedToken)) {
    return res.status(401).json({ ok: false, error: 'unauthorized' });
  }

  const payload = req.body;

  let message = payload?.message || payload?.msg || '';

  if (message) {
    await sendWhatsAppMessage(message);
  }

  return res.json({ ok: true });
});

module.exports = { router };
