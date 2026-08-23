const { fetchWithTimeout } = require('../utils/http');
const config = require('../config');

function isConfigured() {
  return !!(config.qbittorrent.url && config.qbittorrent.username && config.qbittorrent.password);
}

async function login() {
  if (!isConfigured()) {
    throw new Error('qBittorrent no está configurado. Revisá QBITTORRENT_URL, QBITTORRENT_USERNAME y QBITTORRENT_PASSWORD.');
  }

  const body = new URLSearchParams({
    username: config.qbittorrent.username,
    password: config.qbittorrent.password,
  });

  const response = await fetchWithTimeout(`${config.qbittorrent.url}/api/v2/auth/login`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  });

  if (!response.ok) {
    throw new Error(`qBittorrent auth error: ${response.status}`);
  }

  const cookie = response.headers.get('set-cookie');
  if (!cookie) {
    throw new Error('qBittorrent no devolvió cookie de sesión.');
  }

  return cookie.split(';')[0];
}

async function getActiveTorrents() {
  const cookie = await login();
  const response = await fetchWithTimeout(`${config.qbittorrent.url}/api/v2/torrents/info?filter=active`, {
    headers: {
      Cookie: cookie,
    },
  });

  if (!response.ok) {
    throw new Error(`qBittorrent torrents error: ${response.status}`);
  }

  const torrents = await response.json();
  return torrents.map((torrent) => ({
    name: torrent.name,
    progress: Math.round((torrent.progress || 0) * 100),
    state: torrent.state,
    eta: torrent.eta,
    dlspeed: torrent.dlspeed || 0,
  }));
}

async function listTorrents() {
  const cookie = await login();
  const response = await fetchWithTimeout(`${config.qbittorrent.url}/api/v2/torrents/info`, {
    headers: {
      Cookie: cookie,
    },
  });

  if (!response.ok) {
    throw new Error(`qBittorrent torrents error: ${response.status}`);
  }

  return await response.json();
}

async function deleteTorrentsByName(query, category = null) {
  const normalized = String(query || '').toLowerCase().trim();
  if (!normalized) {
    return 0;
  }

  const torrents = await listTorrents();
  const matches = torrents.filter((torrent) => {
    const sameCategory = !category || torrent.category === category;
    return sameCategory && String(torrent.name || '').toLowerCase().includes(normalized);
  });

  if (matches.length === 0) {
    return 0;
  }

  const cookie = await login();
  const body = new URLSearchParams({
    hashes: matches.map((torrent) => torrent.hash).join('|'),
    deleteFiles: 'true',
  });

  const response = await fetchWithTimeout(`${config.qbittorrent.url}/api/v2/torrents/delete`, {
    method: 'POST',
    headers: {
      Cookie: cookie,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  });

  if (!response.ok) {
    throw new Error(`qBittorrent delete error: ${response.status}`);
  }

  return matches.length;
}

async function deleteCompletedTorrents() {
  const torrents = await listTorrents();
  const matches = torrents.filter((torrent) => (torrent.progress || 0) >= 1);

  if (matches.length === 0) {
    return 0;
  }

  const cookie = await login();
  const body = new URLSearchParams({
    hashes: matches.map((torrent) => torrent.hash).join('|'),
    deleteFiles: 'false',
  });

  const response = await fetchWithTimeout(`${config.qbittorrent.url}/api/v2/torrents/delete`, {
    method: 'POST',
    headers: {
      Cookie: cookie,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  });

  if (!response.ok) {
    throw new Error(`qBittorrent delete error: ${response.status}`);
  }

  return matches.length;
}

module.exports = {
  deleteCompletedTorrents,
  deleteTorrentsByName,
  isConfigured,
  getActiveTorrents,
  listTorrents,
};
