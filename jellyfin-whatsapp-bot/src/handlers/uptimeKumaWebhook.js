const express = require('express');
const { sendWhatsAppMessage } = require('../whatsapp');

const router = express.Router();

router.post('/uptime-kuma', async (req, res) => {
  const payload = req.body;

  let message = payload?.message || payload?.msg || '';

  if (message) {
    await sendWhatsAppMessage(message);
  }

  res.json({ ok: true });
});

module.exports = { router };
