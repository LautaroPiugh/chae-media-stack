const dedupe = new Map();
const EXPIRY_MS = 10 * 60 * 1000;

function getKey(...parts) {
  return parts.join(':');
}

function isDuplicate(key) {
  if (dedupe.has(key)) {
    return true;
  }
  dedupe.set(key, true);
  setTimeout(() => dedupe.delete(key), EXPIRY_MS);
  return false;
}

function clearDedupe() {
  dedupe.clear();
}

module.exports = {
  isDuplicate,
  clearDedupe,
};