const config = require('../config');
const { sendWhatsAppMessage } = require('../whatsapp');
const { isSameWhatsAppUser, numberToJid, jidToDigits } = require('./jid');
const { formatPanel } = require('./panel');
const { rememberRequest, getRequesterJids } = require('../store/requestOrigins');
const { getDiskSummary } = require('./diskSummary');

function getAdminJid() {
  return config.whatsapp.owner ? numberToJid(config.whatsapp.owner) : null;
}

function getRequesterLabel(requesterJid) {
  const digits = jidToDigits(requesterJid);
  return digits ? `+${digits}` : 'desconocido';
}

function isOwnerRequest(requesterJid) {
  return !!(config.whatsapp.owner && requesterJid && isSameWhatsAppUser(config.whatsapp.owner, requesterJid));
}

function isOwnerJid(jid) {
  return !!(config.whatsapp.owner && jid && isSameWhatsAppUser(config.whatsapp.owner, jid));
}

function dedupeRecipientJids(jids) {
  const recipients = [];

  for (const jid of jids) {
    if (!jid) {
      continue;
    }

    if (recipients.some((existing) => isSameWhatsAppUser(existing, jid))) {
      continue;
    }

    recipients.push(jid);
  }

  return recipients;
}

function buildDiskLines(disk) {
  if (!disk) {
    return [];
  }

  return [
    `- Pool: ${disk.pool.used} / ${disk.pool.total} usado (${disk.pool.usedPct}%)`,
    `- Pool libre: ${disk.pool.free}`,
    `- Disco 1: ${disk.media1.used} / ${disk.media1.total} usado (${disk.media1.usedPct}%)`,
    `- Disco 1 libre: ${disk.media1.free}`,
    `- Disco 2: ${disk.media2.used} / ${disk.media2.total} usado (${disk.media2.usedPct}%)`,
    `- Disco 2 libre: ${disk.media2.free}`,
  ];
}

function appendOwnerDiskSummary(message, disk) {
  const lines = buildDiskLines(disk);
  if (lines.length === 0) {
    return message;
  }

  return `${message}\n\nEspacio\n${lines.join('\n')}`;
}

async function notifyAdminQueuedDownload({ mediaType, title, year, requesterJid, action }) {
  const adminJid = getAdminJid();
  if (!adminJid || isOwnerRequest(requesterJid)) {
    return;
  }

  const disk = await getDiskSummary();
  const lines = [
    `- ${mediaType === 'movie' ? '🎬' : '📺'} ${title} (${year || 's/a'})`,
    `- Acción: ${action}`,
    `- Pedido por: ${getRequesterLabel(requesterJid)}`,
  ];

  lines.push(...buildDiskLines(disk));

  const message = formatPanel('Descarga encolada', [{ lines }]);
  await sendWhatsAppMessage(message, adminJid);
}

function rememberMediaRequest({ mediaType, mediaId, requesterJid, title, year }) {
  rememberRequest(mediaType, mediaId, requesterJid, { title, year });
}

function getCompletionRecipients(mediaType, mediaId) {
  const adminJid = getAdminJid();
  const recipients = [];

  if (adminJid) {
    recipients.push(adminJid);
  }

  for (const requesterJid of getRequesterJids(mediaType, mediaId)) {
    if (requesterJid) {
      recipients.push(requesterJid);
    }
  }

  return dedupeRecipientJids(recipients);
}

async function sendCompletionMessage(mediaType, mediaId, message) {
  const recipients = getCompletionRecipients(mediaType, mediaId);
  if (recipients.length === 0) {
    const disk = await getDiskSummary();
    await sendWhatsAppMessage(appendOwnerDiskSummary(message, disk));
    return;
  }

  const disk = await getDiskSummary();

  for (const recipient of recipients) {
    const finalMessage = isOwnerJid(recipient) ? appendOwnerDiskSummary(message, disk) : message;
    await sendWhatsAppMessage(finalMessage, recipient);
  }
}

module.exports = {
  rememberMediaRequest,
  notifyAdminQueuedDownload,
  sendCompletionMessage,
  getCompletionRecipients,
};
