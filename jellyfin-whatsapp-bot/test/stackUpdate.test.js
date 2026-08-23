const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');

process.env.WHATSAPP_OWNER = '5491112345678';

const {
  CONFIRMATION_TTL_MS,
  cancelConfirmation,
  consumeConfirmation,
  createConfirmation,
  formatStatus,
} = require('../src/commands/stackUpdate');
const { signRequest } = require('../src/clients/updateBrokerClient');

const ownerJid = '5491112345678@s.whatsapp.net';
const anotherJid = '5499912345678@s.whatsapp.net';

test('system update confirmation is scoped to the requesting user and single-use', () => {
  const now = 1_700_000_000_000;
  const preview = { services: ['radarr'] };
  const code = createConfirmation(ownerJid, preview, now);

  assert.match(code, /^\d{6}$/);
  assert.deepEqual(consumeConfirmation(anotherJid, code, now), { ok: false, reason: 'missing' });
  assert.deepEqual(consumeConfirmation(ownerJid, '000000', now), { ok: false, reason: 'invalid' });
  assert.deepEqual(consumeConfirmation(ownerJid, code, now), { ok: true, preview });
  assert.deepEqual(consumeConfirmation(ownerJid, code, now), { ok: false, reason: 'missing' });
});

test('system update confirmation expires after ten minutes', () => {
  const now = 1_700_000_000_000;
  const code = createConfirmation(ownerJid, {}, now);
  assert.deepEqual(
    consumeConfirmation(ownerJid, code, now + CONFIRMATION_TTL_MS + 1),
    { ok: false, reason: 'expired' },
  );
});

test('system update confirmation can be cancelled', () => {
  const code = createConfirmation(ownerJid, {});
  assert.equal(cancelConfirmation(ownerJid), true);
  assert.deepEqual(consumeConfirmation(ownerJid, code), { ok: false, reason: 'missing' });
});

test('broker request signature covers method, path and body', () => {
  const secret = 'test-secret-with-more-than-32-characters';
  const timestamp = '1700000000';
  const nonce = '1234567890abcdef';
  const body = '{}';
  const expected = crypto.createHmac('sha256', secret)
    .update(`${timestamp}\n${nonce}\nPOST\n/v1/start\n${body}`)
    .digest('hex');

  assert.equal(signRequest(secret, timestamp, nonce, 'POST', '/v1/start', body), expected);
  assert.notEqual(signRequest(secret, timestamp, nonce, 'POST', '/v1/preview', body), expected);
});

test('broker start signature binds the approved Git commit', () => {
  const secret = 'test-secret-with-more-than-32-characters';
  const timestamp = '1700000000';
  const nonce = '1234567890abcdef';
  const first = JSON.stringify({ approvedCommit: 'a'.repeat(40), approvedTreeHash: 'c'.repeat(64) });
  const second = JSON.stringify({ approvedCommit: 'b'.repeat(40), approvedTreeHash: 'c'.repeat(64) });

  assert.notEqual(
    signRequest(secret, timestamp, nonce, 'POST', '/v1/start', first),
    signRequest(secret, timestamp, nonce, 'POST', '/v1/start', second),
  );
});

test('status formatter reports progress without logs or secrets', () => {
  const result = formatStatus({
    id: 'abc123',
    status: 'running',
    phase: 'services',
    current: 'radarr',
    completed: ['prowlarr', 'sonarr'],
    message: 'Actualizando radarr',
  });

  assert.match(result, /En ejecución/);
  assert.match(result, /Objetivo actual: radarr/);
  assert.match(result, /prowlarr, sonarr/);
});
