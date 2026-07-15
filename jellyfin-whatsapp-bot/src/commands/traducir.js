const { execSync } = require('child_process');
const { formatPanel } = require('../utils/panel');
const { formatErrorPanel } = require('../utils/formatMessage');

const SCRIPT_PATH = '/home/chae/scripts/check_es_subs.py';

async function handleTraducir(text) {
  const lower = text.toLowerCase().trim();
  const title = lower.replace('/traducir', '').trim();

  if (!title) {
    return formatErrorPanel('Traducir película', [
      'Uso: /traducir [título de película]',
      'Ejemplo: /traducir The Matrix',
    ]);
  }

  try {
    const output = execSync(
      `python3 "${SCRIPT_PATH}" --translate-movie "${title.replace(/"/g, '\\"')}"`,
      { timeout: 300000, encoding: 'utf-8' }
    ).trim();

    const lines = output.split('\n').filter(l => !l.startsWith('['));
    const clean = lines.join('\n').trim() || output.trim();

    return formatPanel('Traducción', [
      { lines: clean.split('\n') },
    ]);
  } catch (err) {
    return formatErrorPanel('Error de traducción', [
      err.message.substring(0, 200),
    ]);
  }
}

module.exports = { handleTraducir };
