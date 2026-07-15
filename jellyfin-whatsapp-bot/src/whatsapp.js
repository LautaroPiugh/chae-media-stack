const { default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys');
const qrcode = require('qrcode-terminal');
const pino = require('pino');
const config = require('./config');
const { numberToJid } = require('./utils/jid');
const { authDir, ensureAuthDir } = require('./utils/auth');

let sock = null;
let connected = false;
let messageHandler = null;
let startPromise = null;
let manualReconnect = false;

const logger = pino({ level: 'info' });

function isGroupMessage(jid) {
  return jid && jid.includes('@g.us');
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
      console.log('\n📱 Scan the QR code below with WhatsApp:\n');
      qrcode.generate(qr, { small: true });
      console.log('\n');
    }
    if (connection === 'open') {
      connected = true;
      manualReconnect = false;
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

  sock.ev.on('qr', (qr) => {
    console.log('\n📱 Scan the QR code below with WhatsApp:\n');
    qrcode.generate(qr, { small: true });
    console.log('\n');
  });

  sock.ev.on('messages.upsert', async ({ messages }) => {
    for (const msg of messages) {
      if (!msg.message) continue;
      if (msg.key.fromMe) continue;

      const jid = msg.key.remoteJid;

      console.log(`[WhatsApp] Message from JID: ${jid}`);

      if (isGroupMessage(jid)) {
        console.log('[WhatsApp] Ignored: group message');
        continue;
      }

      const text = msg.message.conversation || msg.message.extendedTextMessage?.text || '';
      if (!text.trim()) continue;

      console.log(`[WhatsApp] Processing: "${text}"`);

      if (messageHandler) {
        await messageHandler(text.trim(), jid);
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

  console.log(`[WhatsApp] Sending message to JID: ${targetJid}`);

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
  onMessage,
  reconnectWhatsApp,
};
