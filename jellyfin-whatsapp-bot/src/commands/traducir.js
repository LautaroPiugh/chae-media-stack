const { execFile } = require('child_process');
const { promisify } = require('util');
const { isAdminUser, formatNoPermission } = require('./admin');
const { formatPanel } = require('../utils/panel');
const { formatErrorPanel } = require('../utils/formatMessage');
const path = require('path');

const SCRIPT_PATH = path.join(__dirname, '../../../scripts/check_es_subs.py');
const execFileAsync = promisify(execFile);
const MAX_TITLE_LENGTH = 200;

async function handleTraducir(text, userJid) {
  if (!isAdminUser(userJid)) {
    return formatNoPermission();
  }

  const title = text.replace(/^\/traducir\s*/i, '').trim();

  if (!title) {
    return formatErrorPanel('Traducir película', [
      'Uso: /traducir [título de película]',
      'Ejemplo: /traducir The Matrix',
    ]);
  }

  if (title.length > MAX_TITLE_LENGTH || /[\x00-\x1f\x7f]/.test(title)) {
    return formatErrorPanel('Traducir película', ['El título contiene caracteres inválidos o es demasiado largo']);
  }

  try {
    const { stdout } = await execFileAsync(
      'python3',
      [SCRIPT_PATH, '--translate-movie', title],
      { timeout: 300000, encoding: 'utf-8', maxBuffer: 1024 * 1024 }
    );
    const output = stdout.trim();

    const lines = output.split('\n').filter(l => !l.startsWith('['));
    const clean = lines.join('\n').trim() || output.trim();

    return formatPanel('Traducción', [
      { lines: clean.split('\n') },
    ]);
  } catch (err) {
    return formatErrorPanel('Error de traducción', [
      `El proceso de traducción falló${err.code ? ` (${err.code})` : ''}`,
    ]);
  }
}

module.exports = { handleTraducir };
