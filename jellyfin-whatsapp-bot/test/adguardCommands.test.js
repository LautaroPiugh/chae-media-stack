const test = require('node:test');
const assert = require('node:assert/strict');

process.env.WHATSAPP_OWNER = '5491112345678';
process.env.ADGUARD_URL = 'http://adguard.test:3000';
process.env.ADGUARD_USERNAME = 'test-admin';
process.env.ADGUARD_PASSWORD = 'test-only-password';

const { processCommand } = require('../src/commands');
const config = require('../src/config');

const ownerJid = '5491112345678@s.whatsapp.net';
const otherJid = '5491199999999@s.whatsapp.net';
const originalFetch = global.fetch;
const calls = [];
let protectionEnabled = true;
let userRules = ['||blocked.example^'];
const expectedAuthorization = `Basic ${Buffer.from('test-admin:test-only-password').toString('base64')}`;

function jsonResponse(value) {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
}

test.before(() => {
  global.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    assert.equal(options.headers.Authorization, expectedAuthorization);

    const path = new URL(url).pathname;
    if (path === '/control/status') {
      return jsonResponse({ running: true, protection_enabled: protectionEnabled });
    }
    if (path === '/control/protection') {
      protectionEnabled = JSON.parse(options.body).enabled;
      return new Response('', { status: 200 });
    }
    if (path === '/control/filtering/status') {
      return jsonResponse({ user_rules: userRules });
    }
    if (path === '/control/filtering/set_rules') {
      userRules = JSON.parse(options.body).rules;
      return new Response('', { status: 200 });
    }
    return new Response('', { status: 404 });
  };
});

test.after(() => {
  global.fetch = originalFetch;
});

test('AdGuard status uses the HTTP API', async () => {
  const response = await processCommand('/agu-status', ownerJid);
  assert.match(response, /Servicio DNS: activo/);
  assert.match(response, /Proteccion: activada/);
  assert.equal(calls.at(-1).url, 'http://adguard.test:3000/control/status');
});

test('AdGuard commands reject non-admin users before calling the API', async () => {
  const callCount = calls.length;
  const response = await processCommand('/agu-off', otherJid);
  assert.match(response, /Permiso denegado/);
  assert.equal(calls.length, callCount);
});

test('AdGuard commands fail closed with placeholder credentials', async () => {
  const callCount = calls.length;
  const password = config.adguard.password;
  config.adguard.password = 'CHANGEME_STRONG_PASSWORD';

  try {
    const response = await processCommand('/agu-status', ownerJid);
    assert.match(response, /API no esta configurada/);
    assert.equal(calls.length, callCount);
  } finally {
    config.adguard.password = password;
  }
});

test('AdGuard off and on toggle protection without stopping DNS', async () => {
  const off = await processCommand('/agu-off', ownerJid);
  assert.match(off, /servicio DNS sigue activo/);
  assert.equal(protectionEnabled, false);

  const on = await processCommand('/agu-on', ownerJid);
  assert.match(on, /Proteccion activada/);
  assert.equal(protectionEnabled, true);
});

test('AdGuard whitelist preserves existing rules and avoids duplicates', async () => {
  const added = await processCommand('/agu-whitelist allowed.example', ownerJid);
  assert.match(added, /agregado a la whitelist/);
  assert.deepEqual(userRules, ['||blocked.example^', '@@||allowed.example^']);

  const duplicate = await processCommand('/agu-whitelist allowed.example', ownerJid);
  assert.match(duplicate, /ya esta en la whitelist/);
  assert.deepEqual(userRules, ['||blocked.example^', '@@||allowed.example^']);
});

test('AdGuard whitelist reports its usage when the domain is missing', async () => {
  const callCount = calls.length;
  const response = await processCommand('/agu-whitelist', ownerJid);
  assert.match(response, /Uso: \/agu-whitelist <dominio>/);
  assert.equal(calls.length, callCount);
});
