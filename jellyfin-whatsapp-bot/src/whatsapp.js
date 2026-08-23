const { default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys');
const { unlink } = require('fs/promises');
const { join } = require('path');
const qrcode = require('qrcode');
const pino = require('pino');
const config = require('./config');
const { getAuthorizedSenderJid, numberToJid } = require('./utils/jid');
const { authDir, ensureAuthDir } = require('./utils/auth');

const qrPath = join(authDir, 'whatsapp-qr.png');

let sock = null;
let connected = false;
let messageHandler = null;
let startPromise = null;
let manualReconnect = false;

const logger = pino({ level: 'info' });

function renderCompactQr(value) {
  const matrix = qrcode.create(value, { errorCorrectionLevel: 'L' }).modules;
  const margin = 4;
  const width = matrix.size + margin * 2;
  const height = matrix.size + margin * 2;
  const dots = [
    [0, 0, 0x01], [0, 1, 0x02], [0, 2, 0x04], [1, 0, 0x08],
    [1, 1, 0x10], [1, 2, 0x20], [0, 3, 0x40], [1, 3, 0x80],
  ];
  const lines = [];

  for (let y = 0; y < height; y += 4) {
    let line = '';
    for (let x = 0; x < width; x += 2) {
      let pattern = 0;
      for (const [dx, dy, bit] of dots) {
        const moduleX = x + dx - margin;
        const moduleY = y + dy - margin;
        if (moduleX >= 0 && moduleY >= 0 && moduleX < matrix.size && moduleY < matrix.size
          && matrix.get(moduleX, moduleY)) {
          pattern |= bit;
        }
      }
      line += String.fromCodePoint(0x2800 + pattern);
    }
    lines.push(line);
  }

  return lines.join('\n');
}

function publishQr(qr) {
  console.log(`\n📱 Scan this compact WhatsApp QR:\n\n${renderCompactQr(qr)}\n`);
  qrcode.toFile(qrPath, qr, { width: 192, margin: 1 })
    .then(() => console.log(`📱 WhatsApp QR ready: ${qrPath}`))
    .catch((error) => console.error(`[WhatsApp] Could not save QR: ${error.message}`));
}

function isGroupMessage(jid) {
  return jid && jid.includes('@g.us');
}

function isLiveMessageBatch(type, requestId) {
  return type === 'notify' && !requestId;
}

async function startWhatsApp() {
  if (startPromise) {
    return startPromise;
  }

  startPromise = (async () => {
  ensureAuthDir();

  const { state, saveCreds } = await useMultiFileAuthState(authDir);

  const { version } = await fetchLatestBaileysVersion({});

  sock = makeWASocket({
    auth: state,
    version,
    logger,
    shouldSyncHistoryMessage: () => false,
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', async ({ connection, lastDisconnect, qr }) => {
    if (qr) {
      publishQr(qr);
    }
    if (connection === 'open') {
      connected = true;
      manualReconnect = false;
      unlink(qrPath).catch(() => {});
      console.log('✅ WhatsApp connected');
    } else if (connection === 'close') {
      connected = false;
      const shouldReconnect = !manualReconnect && lastDisconnect?.error?.output?.statusCode !== 403;
      if (shouldReconnect) {
        console.log('⚠️ WhatsApp disconnected. Reconnecting...');
        setTimeout(() => {
          startWhatsApp().catch((error) => console.error('[WhatsApp] Reconnect failed:', error.message));
        }, 5000);
      }
    } else if (connection === 'error') {
      console.log('❌ WhatsApp connection error');
      connected = false;
    }
  });

  sock.ev.on('messages.upsert', async ({ messages, type, requestId }) => {
    if (!isLiveMessageBatch(type, requestId)) {
      console.log('[WhatsApp] Ignored: non-live message batch');
      return;
    }

    for (const msg of messages) {
      if (!msg.message) continue;
      if (msg.key.fromMe) continue;

      const jid = msg.key.remoteJid;

      if (isGroupMessage(jid)) {
        console.log('[WhatsApp] Ignored: group message');
        continue;
      }

      const senderJid = getAuthorizedSenderJid(msg.key, config.whatsapp.owner);
      if (!senderJid) {
        console.warn('[WhatsApp] Ignored: unauthorized sender');
        continue;
      }

      const text = msg.message.conversation || msg.message.extendedTextMessage?.text || '';
      if (!text.trim()) continue;

      console.log('[WhatsApp] Processing authorized command');

      if (messageHandler) {
        await messageHandler(text.trim(), senderJid);
      }
    }
  });

    return sock;
  })();

  try {
    return await startPromise;
  } finally {
    startPromise = null;
  }
}

async function reconnectWhatsApp() {
  manualReconnect = true;
  connected = false;

  if (sock) {
    try {
      sock.end(new Error('Manual reconnect requested'));
    } catch {
      // ignore and start a fresh socket below
    }
  }

  await new Promise((resolve) => setTimeout(resolve, 1000));
  return startWhatsApp();
}

async function sendWhatsAppMessage(text, jid = null) {
  if (!sock || !connected) {
    console.error('[WhatsApp] Not connected, cannot send');
    return false;
  }

  const targetJid = jid || numberToJid(config.whatsapp.owner);

  try {
    await sock.sendMessage(targetJid, { text: String(text) });
    console.log('[WhatsApp] Message sent successfully');
    return true;
  } catch (err) {
    console.error(`[WhatsApp] Failed to send: ${err.message}`);
    return false;
  }
}

function isWhatsAppConnected() {
  return connected;
}

function onMessage(handler) {
  messageHandler = handler;
}

module.exports = {
  startWhatsApp,
  sendWhatsAppMessage,
  isWhatsAppConnected,
  isLiveMessageBatch,
  onMessage,
  reconnectWhatsApp,
};
