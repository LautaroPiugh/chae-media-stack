const pino = require('pino');
const makeWASocket = require('@whiskeysockets/baileys').default;
const { useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys');
const qrcodeTerminal = require('qrcode-terminal');
const { handleCommand } = require('./commands');

const logger = pino({ level: 'info' });

let sock = null;
let isConnected = false;

function toJid(number) {
  const clean = number.replace(/\D/g, '');
  return `${clean}@s.whatsapp.net`;
}

async function connectWhatsApp(targetNumber) {
  const { version } = await fetchLatestBaileysVersion();
  const { state, saveCreds } = await useMultiFileAuthState('./auth');

  sock = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: true,
    logger,
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', ({ connection, lastDisconnect }) => {
    if (connection === 'open') {
      isConnected = true;
      logger.info('WhatsApp connected');
    } else if (connection === 'close') {
      isConnected = false;
      const shouldReconnect = lastDisconnect?.error?.output?.statusCode !== 401;
      if (shouldReconnect) {
        logger.warn('WhatsApp disconnected, reconnecting...');
        connectWhatsApp(targetNumber);
      }
    }
  });

  sock.ev.on('qr', (qr) => {
    logger.info('QR generated - scan with your WhatsApp');
    qrcodeTerminal.generate(qr, { small: true });
  });

  sock.ev.on('messages.upsert', async ({ messages }) => {
    for (const msg of messages) {
      if (msg.key && msg.key.fromMe) continue;
      if (!msg.message?.conversation && !msg.message?.extendedTextMessage?.text) continue;
      const text = msg.message.conversation || msg.message.extendedTextMessage.text;
      if (!text.startsWith('/')) continue;
      const sender = msg.key.remoteJid;
      if (!sender || !targetNumber) continue;
      const targetJid = toJid(targetNumber);
      if (sender !== targetJid) continue;
      try {
        const reply = await handleCommand(text, sock);
        if (reply) {
          await sock.sendMessage(sender, { text: reply });
        }
      } catch (err) {
        logger.error({ err }, 'Error handling command');
        await sock.sendMessage(sender, { text: `Error: ${err.message}` });
      }
    }
  });

  return sock;
}

function getSock() {
  return sock;
}

function isWhatsAppConnected() {
  return isConnected;
}

async function sendWhatsAppMessage(text) {
  const sock = getSock();
  if (!sock || !isConnected) {
    logger.error('WhatsApp not connected, cannot send message');
    return false;
  }

  const jid = toJid(process.env.WHATSAPP_TARGET || '');

  try {
    await sock.sendMessage(jid, { text });
    logger.info('Message sent successfully');
    return true;
  } catch (err) {
    logger.error({ err }, 'Failed to send message');
    return false;
  }
}

module.exports = {
  connectWhatsApp,
  getSock,
  isWhatsAppConnected,
  sendWhatsAppMessage,
  toJid,
};