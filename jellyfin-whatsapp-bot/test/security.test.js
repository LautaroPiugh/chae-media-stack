const test = require('node:test');
const assert = require('node:assert/strict');

process.env.WHATSAPP_OWNER = '5491112345678';
process.env.ADMIN_REGISTER_CODE = 'test-only-strong-admin-code';

const {
  getAuthorizedSenderJid,
  isSameWhatsAppUser,
  normalizeUserJid,
  numberToJid,
} = require('../src/utils/jid');
const { isSecretConfigured, isValidToken } = require('../src/utils/httpAuth');
const { processCommand } = require('../src/commands');
const { isLiveMessageBatch } = require('../src/whatsapp');

const ownerJid = '5491112345678@s.whatsapp.net';
const differentJid = '5499912345678@s.whatsapp.net';

test('normalizes a configured owner to a canonical WhatsApp JID', () => {
  assert.equal(numberToJid('+5491112345678'), ownerJid);
  assert.equal(normalizeUserJid('5491112345678:12@s.whatsapp.net'), ownerJid);
});

test('compares complete canonical JIDs without suffix matching', () => {
  assert.equal(isSameWhatsAppUser(process.env.WHATSAPP_OWNER, ownerJid), true);
  assert.equal(isSameWhatsAppUser(process.env.WHATSAPP_OWNER, differentJid), false);
  assert.equal(isSameWhatsAppUser(process.env.WHATSAPP_OWNER, '1112345678@s.whatsapp.net'), false);
  assert.equal(isSameWhatsAppUser(process.env.WHATSAPP_OWNER, '5491112345678@lid'), false);
});

test('accepts an exact phone identity supplied for an owner LID message', () => {
  const senderJid = getAuthorizedSenderJid({
    remoteJid: '123456789012345@lid',
    senderPn: ownerJid,
  }, process.env.WHATSAPP_OWNER);

  assert.equal(senderJid, ownerJid);
  assert.equal(getAuthorizedSenderJid({
    remoteJid: '123456789012345@lid',
    senderPn: differentJid,
  }, process.env.WHATSAPP_OWNER), '');
});

test('processes only live Baileys notification batches', () => {
  assert.equal(isLiveMessageBatch('notify'), true);
  assert.equal(isLiveMessageBatch('append'), false);
  assert.equal(isLiveMessageBatch('notify', 'history-request'), false);
});

test('HTTP tokens fail closed for missing and placeholder secrets', () => {
  assert.equal(isSecretConfigured(''), false);
  assert.equal(isSecretConfigured('CHANGEME_STRONG_TOKEN'), false);
  assert.equal(isValidToken('', 'anything'), false);
  assert.equal(isValidToken('CHANGEME_STRONG_TOKEN', 'CHANGEME_STRONG_TOKEN'), false);
  assert.equal(isValidToken('test-only-strong-token', 'wrong-token'), false);
  assert.equal(isValidToken('test-only-strong-token', 'test-only-strong-token'), true);
});

test('/registraradmin requires the exact owner and configured code', async () => {
  const unauthorized = await processCommand('/registraradmin test-only-strong-admin-code', differentJid);
  assert.match(unauthorized, /Permiso denegado/);

  const wrongCode = await processCommand('/registraradmin wrong-code', ownerJid);
  assert.match(wrongCode, /Código inválido/);

  const verified = await processCommand('/registraradmin test-only-strong-admin-code', ownerJid);
  assert.match(verified, /Admin verificado/);
});

test('/traducir rejects a non-admin before starting a process', async () => {
  const response = await processCommand('/traducir test title', differentJid);
  assert.match(response, /Permiso denegado/);
});

test('/actualizar rejects a non-admin before changing service state', async () => {
  const response = await processCommand('/actualizar test title', differentJid);
  assert.match(response, /Permiso denegado/);
});
