const { statfs } = require('fs/promises');

function humanSize(bytes) {
  if (!bytes || bytes <= 0) {
    return '0 B';
  }

  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = bytes;
  let unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }

  return `${size.toFixed(size >= 10 || unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

async function readPathStats(path) {
  const stats = await statfs(path);
  const free = stats.bavail * stats.bsize;
  const total = stats.blocks * stats.bsize;
  const used = Math.max(0, total - free);
  const usedPct = total > 0 ? ((used / total) * 100).toFixed(1) : '0.0';

  return {
    used: humanSize(used),
    free: humanSize(free),
    total: humanSize(total),
    usedPct,
  };
}

async function getDiskSummary() {
  try {
    const [pool, media1, media2] = await Promise.all([
      readPathStats('/mnt/media'),
      readPathStats('/mnt/media1'),
      readPathStats('/mnt/media2'),
    ]);

    return {
      pool,
      media1,
      media2,
    };
  } catch {
    return null;
  }
}

module.exports = {
  getDiskSummary,
};
