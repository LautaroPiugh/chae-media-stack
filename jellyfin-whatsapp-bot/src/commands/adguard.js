const {
  addWhitelistRule,
  getStatus,
  isConfigured,
  setProtection,
} = require('../clients/adguardClient');
const { formatPanel } = require('../utils/panel');
const { isAdminUser, formatNoPermission } = require('./admin');

function isValidDomain(domain) {
  if (!domain || domain.length > 253) {
    return false;
  }

  const labels = domain.split('.');
  return labels.length >= 2 && labels.every((label) => (
    label.length >= 1
    && label.length <= 63
    && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label)
  ));
}

async function handleAdguardWhitelist(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }
  if (!isConfigured()) {
    return formatPanel('AdGuard Whitelist', [{ lines: ['AdGuard API no esta configurada'] }]);
  }

  const domain = text.replace(/^\/agu-whitelist\s*/i, '').trim().toLowerCase();
  if (!domain) {
    return formatPanel('AdGuard Whitelist', [
      { lines: ['Falta el dominio', '', 'Uso: /agu-whitelist <dominio>', 'Ej: /agu-whitelist ejemplo.com'] },
    ]);
  }
  if (!isValidDomain(domain)) {
    return formatPanel('AdGuard Whitelist', [{ lines: ['Dominio invalido'] }]);
  }

  const rule = `@@||${domain}^`;

  try {
    const added = await addWhitelistRule(rule);
    if (!added) {
      return formatPanel('AdGuard Whitelist', [{ lines: [`${domain} ya esta en la whitelist`] }]);
    }
    return formatPanel('AdGuard Whitelist', [{ lines: [`${domain} agregado a la whitelist`] }]);
  } catch {
    return formatPanel('AdGuard Whitelist', [{ lines: ['No se pudo actualizar la whitelist'] }]);
  }
}

async function handleAdguardOff(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }
  if (!isConfigured()) {
    return formatPanel('AdGuard', [{ lines: ['AdGuard API no esta configurada'] }]);
  }

  try {
    await setProtection(false);
    return formatPanel('AdGuard', [{ lines: ['Proteccion desactivada; el servicio DNS sigue activo'] }]);
  } catch {
    return formatPanel('AdGuard', [{ lines: ['No se pudo desactivar la proteccion'] }]);
  }
}

async function handleAdguardOn(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }
  if (!isConfigured()) {
    return formatPanel('AdGuard', [{ lines: ['AdGuard API no esta configurada'] }]);
  }

  try {
    await setProtection(true);
    return formatPanel('AdGuard', [{ lines: ['Proteccion activada'] }]);
  } catch {
    return formatPanel('AdGuard', [{ lines: ['No se pudo activar la proteccion'] }]);
  }
}

async function handleAdguardStatus(userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }
  if (!isConfigured()) {
    return formatPanel('AdGuard', [{ lines: ['AdGuard API no esta configurada'] }]);
  }

  try {
    const status = await getStatus();
    const service = status?.running ? 'activo' : 'no disponible';
    const protection = status?.protection_enabled ? 'activada' : 'desactivada';
    return formatPanel('AdGuard', [{ lines: [`- Servicio DNS: ${service}`, `- Proteccion: ${protection}`] }]);
  } catch {
    return formatPanel('AdGuard', [{ lines: ['No se pudo consultar AdGuard'] }]);
  }
}

module.exports = { handleAdguardWhitelist, handleAdguardOff, handleAdguardOn, handleAdguardStatus };
