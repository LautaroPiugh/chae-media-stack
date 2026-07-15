const { existsSync, readFileSync, writeFileSync } = require('fs');
const { join } = require('path');
const { authDir, ensureAuthDir } = require('../utils/auth');

const storagePath = join(authDir, 'request-origins.json');
const requests = new Map();
const EXPIRY_MS = 7 * 24 * 60 * 60 * 1000;

loadRequests();

function getKey(mediaType, mediaId) {
  return `${mediaType}:${mediaId}`;
}

function rememberRequest(mediaType, mediaId, requesterJid, metadata = {}) {
  if (!mediaType || !mediaId || !requesterJid) {
    return;
  }

  const key = getKey(mediaType, mediaId);
  const existing = requests.get(key);
  const requesters = new Set(existing?.requesters || []);
  requesters.add(requesterJid);

  const value = {
    mediaType,
    mediaId,
    requesters: [...requesters],
    metadata: {
      ...(existing?.metadata || {}),
      ...metadata,
    },
    timestamp: Date.now(),
  };

  requests.set(key, value);
  persistRequests();

  setTimeout(() => {
    const current = requests.get(key);
    if (current && current.timestamp === value.timestamp) {
      requests.delete(key);
      persistRequests();
    }
  }, EXPIRY_MS);
}

function getRequest(mediaType, mediaId) {
  if (!mediaType || !mediaId) {
    return null;
  }

  return requests.get(getKey(mediaType, mediaId)) || null;
}

function getRequesterJids(mediaType, mediaId) {
  return getRequest(mediaType, mediaId)?.requesters || [];
}

function listRequests() {
  return [...requests.values()].sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0));
}

function loadRequests() {
  try {
    ensureAuthDir();
    if (!existsSync(storagePath)) {
      return;
    }

    const raw = JSON.parse(readFileSync(storagePath, 'utf8'));
    const now = Date.now();
    for (const [key, value] of Object.entries(raw || {})) {
      if (value?.timestamp && now - value.timestamp < EXPIRY_MS) {
        requests.set(key, value);
      }
    }
  } catch {
    // ignore corrupted cache and rebuild it as requests come in
  }
}

function persistRequests() {
  try {
    ensureAuthDir();
    const serializable = Object.fromEntries(requests.entries());
    writeFileSync(storagePath, JSON.stringify(serializable, null, 2));
  } catch {
    // ignore persistence failures, in-memory behavior still works
  }
}

module.exports = {
  rememberRequest,
  getRequest,
  getRequesterJids,
  listRequests,
};
