const config = require('../config');

function getHeaders() {
  return {
    'X-Api-Key': config.jellyseerr.apiKey,
    'Content-Type': 'application/json',
  };
}

function isConfigured() {
  return !!(config.jellyseerr.url && config.jellyseerr.apiKey);
}

async function getStatus() {
  if (!isConfigured()) {
    throw new Error('Jellyseerr no está configurado.');
  }

  const res = await fetch(`${config.jellyseerr.url}/api/v1/status`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Jellyseerr status error: ${res.status}`);
  }

  return res.json();
}

async function getRequests(take = 10, skip = 0) {
  if (!isConfigured()) {
    throw new Error('Jellyseerr no está configurado.');
  }

  const res = await fetch(`${config.jellyseerr.url}/api/v1/request?take=${take}&skip=${skip}`, { headers: getHeaders() });
  if (!res.ok) {
    throw new Error(`Jellyseerr request error: ${res.status}`);
  }

  return res.json();
}

async function getPendingRequests() {
  const payload = await getRequests(50, 0);
  return (payload.results || []).filter((request) => ![3, 5].includes(request.status));
}

module.exports = {
  isConfigured,
  getStatus,
  getRequests,
  getPendingRequests,
};
