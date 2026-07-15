const pendingSelections = new Map();
const EXPIRY_MS = 10 * 60 * 1000;

function setPending(userJid, pending) {
  pendingSelections.set(userJid, {
    ...pending,
    timestamp: Date.now(),
  });

  setTimeout(() => {
    const existing = pendingSelections.get(userJid);
    if (existing && existing.timestamp === getTimestamp(userJid)) {
      pendingSelections.delete(userJid);
    }
  }, EXPIRY_MS);
}

function getPending(userJid) {
  return pendingSelections.get(userJid);
}

function deletePending(userJid) {
  pendingSelections.delete(userJid);
}

function updatePending(userJid, updater) {
  const current = pendingSelections.get(userJid);
  if (!current) {
    return null;
  }

  const next = {
    ...current,
    ...updater(current),
    timestamp: Date.now(),
  };

  pendingSelections.set(userJid, next);
  return next;
}

function getTimestamp(userJid) {
  return pendingSelections.get(userJid)?.timestamp;
}

module.exports = {
  setPending,
  getPending,
  deletePending,
  updatePending,
};
