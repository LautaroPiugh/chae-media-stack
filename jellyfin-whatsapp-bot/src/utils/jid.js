function cleanDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function normalizeWhatsAppNumber(number) {
  const cleaned = cleanDigits(number);

  if (cleaned.startsWith('549')) {
    return cleaned;
  }

  if (cleaned.length === 10) {
    return `549${cleaned}`;
  }

  if (cleaned.length === 12 && cleaned.startsWith('54')) {
    return `549${cleaned.slice(2)}`;
  }

  return cleaned;
}

function numberToJid(number) {
  return `${normalizeWhatsAppNumber(number)}@s.whatsapp.net`;
}

function jidToDigits(jid) {
  return cleanDigits(String(jid || '').split('@')[0]);
}

function isSameWhatsAppUser(numberOrJid, jid) {
  const left = normalizeWhatsAppNumber(numberOrJid);
  const right = normalizeWhatsAppNumber(jidToDigits(jid));

  if (!left || !right) {
    return false;
  }

  return left === right || left.slice(-10) === right.slice(-10);
}

function isValidJid(jid) {
  return jid && jid.includes('@s.whatsapp.net');
}

module.exports = {
  cleanDigits,
  normalizeWhatsAppNumber,
  numberToJid,
  jidToDigits,
  isSameWhatsAppUser,
  isValidJid,
};
