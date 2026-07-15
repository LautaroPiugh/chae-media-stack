const { execSync } = require('child_process');

const SCRIPT_PATH = '/home/chae/scripts/check_es_subs.py';

async function traducirCommand(args) {
  if (args.length === 0) {
    return 'Uso: /traducir [título de película]\nEjemplo: /traducir The Matrix';
  }

  const title = args.join(' ');

  try {
    const output = execSync(
      `python3 "${SCRIPT_PATH}" --translate-movie "${title.replace(/"/g, '\\"')}"`,
      { timeout: 300000, encoding: 'utf-8' }
    ).trim();

    const lines = output.split('\n').filter(l => !l.startsWith('['));
    return lines.join('\n').trim() || output.trim();
  } catch (err) {
    return `Error ejecutando traducción: ${err.message.substring(0, 200)}`;
  }
}

module.exports = { traducirCommand };
