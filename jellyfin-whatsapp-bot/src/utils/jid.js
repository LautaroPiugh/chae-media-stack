function cleanDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function normalizeWhatsAppNumber(number) {
  const raw = String(number || '').trim();
  return /^\+?\d+$/.test(raw) ? raw.replace(/^\+/, '') : '';
}

function numberToJid(number) {
  const normalized = normalizeUserJid(number);
  return normalized || '';
}

function jidToDigits(jid) {
  const normalized = normalizeUserJid(jid);
  return normalized ? normalized.split('@')[0] : '';
}

function isSameWhatsAppUser(numberOrJid, jid) {
  const left = normalizeUserJid(numberOrJid);
  const right = normalizeUserJid(jid);

  if (!left || !right) {
    return false;
  }

  return left === right;
}

function getAuthorizedSenderJid(messageKey, owner) {
  const candidates = [messageKey?.remoteJid, messageKey?.senderPn];
  for (const candidate of candidates) {
    if (isSameWhatsAppUser(owner, candidate)) {
      return normalizeUserJid(candidate);
    }
  }

  return '';
}

function isValidJid(jid) {
  const raw = String(jid || '').trim();
  return raw.includes('@') && !!normalizeUserJid(raw);
}

function normalizeUserJid(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (!raw) {
    return '';
  }

  if (!raw.includes('@')) {
    if (!/^\+?\d+$/.test(raw)) {
      return '';
    }

    const number = normalizeWhatsAppNumber(raw);
    return number ? `${number}@s.whatsapp.net` : '';
  }

  const match = raw.match(/^\+?(\d+)(?::\d+)?@(s\.whatsapp\.net|lid)$/);
  if (!match) {
    return '';
  }

  const [, user, server] = match;
  const normalizedUser = server === 's.whatsapp.net' ? normalizeWhatsAppNumber(user) : user;
  return normalizedUser ? `${normalizedUser}@${server}` : '';
}

module.exports = {
  cleanDigits,
  getAuthorizedSenderJid,
  normalizeWhatsAppNumber,
  normalizeUserJid,
  numberToJid,
  jidToDigits,
  isSameWhatsAppUser,
  isValidJid,
};
