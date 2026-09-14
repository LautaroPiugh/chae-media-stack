const { readdirSync, readFileSync } = require('fs');
const { join } = require('path');

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

// LID -> phone mapping: WhatsApp DMs arrive with @lid jids whose digits are
// not the phone number. Baileys stores the mapping in the auth dir as
// lid-mapping-<phone>.json (phone -> lid) and lid-mapping-<lid>_reverse.json.
function resolveLidToPhone(lidUser) {
  const raw = String(lidUser || '').toLowerCase();
  if (!raw.endsWith('@lid')) {
    return '';
  }

  const lidDigits = cleanDigits(raw.split('@')[0]);
  if (!lidDigits) {
    return '';
  }

  const authDir = join(__dirname, '../../auth');
  try {
    const reversePath = join(authDir, `lid-mapping-${lidDigits}_reverse.json`);
    return cleanDigits(readFileSync(reversePath, 'utf8'));
  } catch {
    // fall through to reverse index scan
  }

  try {
    for (const file of readdirSync(authDir)) {
      if (!file.startsWith('lid-mapping-') || file.endsWith('_reverse.json')) {
        continue;
      }
      const mapping = cleanDigits(readFileSync(join(authDir, file), 'utf8'));
      if (mapping === lidDigits) {
        return cleanDigits(file.replace(/^lid-mapping-/, '').replace(/\.json$/, ''));
      }
    }
  } catch {
    // auth dir not readable yet
  }

  return '';
}

function getAuthorizedSenderJid(messageKey, owner) {
  const ownerDigits = cleanDigits(owner);
  if (!ownerDigits) {
    return '';
  }

  const candidates = [messageKey?.remoteJid, messageKey?.senderPn, messageKey?.participantPn];

  for (const candidate of candidates) {
    if (isSameWhatsAppUser(owner, candidate)) {
      return normalizeUserJid(candidate);
    }
  }

  // Same digits on a different server (e.g. phone delivered as @lid alias).
  for (const candidate of candidates) {
    if (candidate && cleanDigits(candidate) === ownerDigits) {
      return normalizeUserJid(owner);
    }
  }

  // @lid sender: resolve through the LID mapping stored by Baileys.
  for (const candidate of candidates) {
    const phone = resolveLidToPhone(candidate);
    if (phone && phone === ownerDigits) {
      return normalizeUserJid(owner);
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
