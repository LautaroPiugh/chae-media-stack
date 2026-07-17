const config = require('../config');
const crypto = require('crypto');
const { isSameWhatsAppUser, normalizeUserJid } = require('../utils/jid');
const { reconnectWhatsApp } = require('../whatsapp');
const { formatPanel } = require('../utils/panel');
const { deleteCompletedTorrents } = require('../clients/qbittorrentClient');

let adminVerified = new Set();

function isAdminUser(userJid) {
  const normalizedJid = normalizeUserJid(userJid);

  if (!normalizedJid) {
    return false;
  }

  if (adminVerified.has(normalizedJid)) {
    return true;
  }

  return isOwnerUser(normalizedJid);
}

function verifyAdmin(code) {
  const expected = String(config.admin.registerCode || '');
  const provided = String(code || '');
  if (!expected || expected === 'CHANGEME_STRONG_CODE' || !provided) {
    return false;
  }

  const expectedBuffer = Buffer.from(expected);
  const providedBuffer = Buffer.from(provided);
  return expectedBuffer.length === providedBuffer.length && crypto.timingSafeEqual(expectedBuffer, providedBuffer);
}

function isAdminRegistrationConfigured() {
  const code = String(config.admin.registerCode || '');
  return !!code && code !== 'CHANGEME_STRONG_CODE';
}

function isOwnerUser(userJid) {
  return !!config.whatsapp.owner && isSameWhatsAppUser(config.whatsapp.owner, userJid);
}

function markAdminVerified(userJid) {
  const normalizedJid = normalizeUserJid(userJid);
  if (!normalizedJid || !isOwnerUser(normalizedJid)) {
    return false;
  }

  adminVerified.add(normalizedJid);
  console.log('[Admin] Owner session verified');
  return true;
}

function formatNoPermission() {
  return formatPanel('Permiso denegado', [
    {
      lines: [
        '- Este comando es solo para admin',
        '- Podés seguir usando busquedas, descargas y biblioteca',
      ],
    },
  ]);
}

function handleRestart(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  setTimeout(() => {
    process.exit(0);
  }, 1500);

  return formatPanel('Reinicio del bot', [
    {
      lines: [
        '- Limpio memoria temporal',
        '- Reinicio el proceso completo',
        '- Si corre con Docker, vuelve solo en unos segundos',
      ],
    },
  ]);
}

async function handleReconnect(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  try {
    await reconnectWhatsApp();
    return formatPanel('Reconexión de WhatsApp', [
      {
        lines: [
          '- Reinicié solo la conexión de WhatsApp',
          '- El resto del bot siguió corriendo normal',
        ],
      },
    ]);
  } catch (error) {
    return `No pude reconectar WhatsApp. ${error.message}`;
  }
}

async function handleCleanTorrents(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  try {
    const deleted = await deleteCompletedTorrents();
    if (deleted === 0) {
      return formatPanel('Limpieza de torrents', [
        {
          lines: ['- No había torrents completos para limpiar'],
        },
      ]);
    }

    return formatPanel('Limpieza de torrents', [
      {
        lines: [
          `- Eliminé ${deleted} torrent${deleted === 1 ? '' : 's'} completado${deleted === 1 ? '' : 's'} de qBittorrent`,
          '- No borré los archivos importados del disco',
        ],
      },
    ]);
  } catch (error) {
    return formatPanel('Limpieza de torrents', [
      {
        lines: [`- No pude limpiar torrents: ${error.message}`],
      },
    ]);
  }
}

module.exports = {
  handleCleanTorrents,
  formatNoPermission,
  handleReconnect,
  handleRestart,
  isAdminRegistrationConfigured,
  isAdminUser,
  isOwnerUser,
  markAdminVerified,
  verifyAdmin,
};
