const config = require('../config');
const { isSameWhatsAppUser } = require('../utils/jid');
const { reconnectWhatsApp } = require('../whatsapp');
const { formatPanel } = require('../utils/panel');
const { deleteCompletedTorrents } = require('../clients/qbittorrentClient');

let adminVerified = new Set();

function isAdminUser(userJid) {
  const userClean = (userJid || '').replace(/\D/g, '');

  if (adminVerified.has(userClean)) {
    return true;
  }

  const ownerNumber = config.whatsapp.owner;
  if (!ownerNumber) {
    return false;
  }

  const ownerClean = ownerNumber.replace(/\D/g, '');

  const exactMatch = ownerClean === userClean;
  const suffixMatch = ownerClean === userClean.slice(-10) || userClean === ownerClean.slice(-10);
  const lidMatch = userClean.endsWith(ownerClean) || userClean.endsWith(ownerClean.slice(-10));

  const result = exactMatch || suffixMatch || lidMatch;
  return result;
}

function verifyAdmin(code) {
  return code === '0420';
}

function markAdminVerified(userJid) {
  const userClean = (userJid || '').replace(/\D/g, '');
  if (userClean) {
    adminVerified.add(userClean);
    console.log(`[Admin] User ${userClean} marked as verified admin`);
  }
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
  isAdminUser,
  markAdminVerified,
};
