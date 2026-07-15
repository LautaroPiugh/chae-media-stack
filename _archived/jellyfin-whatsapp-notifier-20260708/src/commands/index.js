const { subsCommand } = require('./subs');
const { traducirCommand } = require('./traducir');

async function handleCommand(text, sock) {
  const parts = text.trim().split(/\s+/);
  const cmd = parts[0].toLowerCase();
  const args = parts.slice(1);

  switch (cmd) {
    case '/subs':
      return subsCommand();
    case '/traducir':
      return traducirCommand(args);
    default:
      return `Comando no reconocido. Disponibles: /subs, /traducir [película]`;
  }
}

module.exports = { handleCommand };
