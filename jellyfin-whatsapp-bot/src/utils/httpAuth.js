const crypto = require('crypto');

const PLACEHOLDER_SECRETS = new Set([
  'CHANGEME',
  'CHANGEME_STRONG_CODE',
  'CHANGEME_STRONG_TOKEN',
]);

function isSecretConfigured(secret) {
  const value = String(secret || '');
  return !!value && !PLACEHOLDER_SECRETS.has(value);
}

function isValidToken(expected, provided) {
  const expectedValue = String(expected || '');
  const providedValue = String(provided || '');
  if (!isSecretConfigured(expectedValue) || !providedValue) {
    return false;
  }

  const expectedBuffer = Buffer.from(expectedValue);
  const providedBuffer = Buffer.from(providedValue);
  return expectedBuffer.length === providedBuffer.length && crypto.timingSafeEqual(expectedBuffer, providedBuffer);
}

module.exports = { isSecretConfigured, isValidToken };
