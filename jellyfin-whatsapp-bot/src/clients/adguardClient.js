const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');

const REQUEST_TIMEOUT_MS = 10000;

function isPlaceholder(value) {
  return String(value || '').startsWith('CHANGEME');
}

function isConfigured() {
  return !!(
    config.adguard.url
    && config.adguard.username
    && config.adguard.password
    && !isPlaceholder(config.adguard.username)
    && !isPlaceholder(config.adguard.password)
  );
}

function getBaseUrl() {
  return String(config.adguard.url || '').replace(/\/+$/, '').replace(/\/control$/, '');
}

async function request(path, { method = 'GET', body } = {}) {
  if (!isConfigured()) {
    throw new Error('AdGuard API no configurada');
  }

  const credentials = Buffer.from(`${config.adguard.username}:${config.adguard.password}`).toString('base64');
  const response = await fetchWithTimeout(`${getBaseUrl()}/control${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      Authorization: `Basic ${credentials}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });

  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw new Error('AdGuard rechazo las credenciales');
    }
    throw new Error(`AdGuard API respondio ${response.status}`);
  }

  const text = await response.text();
  const contentType = response.headers.get('content-type') || '';
  return text && contentType.includes('application/json') ? JSON.parse(text) : (text || null);
}

async function getStatus() {
  return request('/status');
}

async function setProtection(enabled) {
  await request('/protection', {
    method: 'POST',
    body: enabled ? { enabled: true } : { enabled: false, duration: 0 },
  });
}

async function addWhitelistRule(rule) {
  const filtering = await request('/filtering/status');
  const rules = Array.isArray(filtering?.user_rules) ? filtering.user_rules : [];
  if (rules.includes(rule)) {
    return false;
  }

  await request('/filtering/set_rules', {
    method: 'POST',
    body: { rules: [...rules, rule] },
  });
  return true;
}

module.exports = {
  addWhitelistRule,
  getStatus,
  isConfigured,
  setProtection,
};
