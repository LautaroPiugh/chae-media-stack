const test = require('node:test');
const assert = require('node:assert/strict');

process.env.BOT_ADMIN_TOKEN = 'test-only-bot-admin-token';
process.env.WHATSAPP_UPDATE_NOTIFY_TOKEN = 'test-only-update-token';
process.env.RADARR_SECRET = 'test-only-radarr-token';
process.env.SONARR_SECRET = 'test-only-sonarr-token';
process.env.UPTIME_KUMA_SECRET = 'test-only-uptime-token';

const { app } = require('../src/server');

let server;
let baseUrl;

test.before(async () => {
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', () => {
      baseUrl = `http://127.0.0.1:${server.address().port}`;
      resolve();
    });
  });
});

test.after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

test('/health exposes only minimal public state', async () => {
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});

test('/status requires the bot admin token', async () => {
  const unauthorized = await fetch(`${baseUrl}/status`);
  assert.equal(unauthorized.status, 401);

  const authorized = await fetch(`${baseUrl}/status`, {
    headers: { 'x-bot-admin-token': process.env.BOT_ADMIN_TOKEN },
  });
  assert.equal(authorized.status, 200);
  assert.deepEqual(await authorized.json(), { ok: true, whatsappConnected: false });
});

test('/update-ready requires the update token', async () => {
  const unauthorized = await fetch(`${baseUrl}/update-ready`);
  assert.equal(unauthorized.status, 401);

  const authorized = await fetch(`${baseUrl}/update-ready`, {
    headers: { 'x-update-token': process.env.WHATSAPP_UPDATE_NOTIFY_TOKEN },
  });
  assert.equal(authorized.status, 200);
  assert.deepEqual(await authorized.json(), { ok: true, whatsappConnected: false });
});

test('message-triggering HTTP endpoints reject missing tokens', async () => {
  const requests = [
    fetch(`${baseUrl}/test-whatsapp`),
    fetch(`${baseUrl}/notify/system-update`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ message: 'test' }),
    }),
    fetch(`${baseUrl}/webhook/radarr`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ eventType: 'Test' }),
    }),
    fetch(`${baseUrl}/webhook/sonarr`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ eventType: 'Test' }),
    }),
    fetch(`${baseUrl}/webhook/uptime-kuma`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ message: 'test' }),
    }),
  ];

  const responses = await Promise.all(requests);
  assert.deepEqual(responses.map((response) => response.status), [401, 401, 401, 401, 401]);
});

test('Radarr and Sonarr accept their configured webhook tokens', async () => {
  const radarr = await fetch(`${baseUrl}/webhook/radarr?token=${encodeURIComponent(process.env.RADARR_SECRET)}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ eventType: 'Test' }),
  });
  assert.equal(radarr.status, 200);

  const sonarr = await fetch(`${baseUrl}/webhook/sonarr`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-webhook-token': process.env.SONARR_SECRET,
    },
    body: JSON.stringify({ eventType: 'Test' }),
  });
  assert.equal(sonarr.status, 200);
});
