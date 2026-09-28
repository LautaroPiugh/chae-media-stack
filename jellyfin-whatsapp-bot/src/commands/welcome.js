const { readFileSync, writeFileSync, existsSync } = require('fs');
const { join } = require('path');

const { formatPanel } = require('../utils/panel');
const { authDir } = require('../utils/auth');

/**
 * Where non-owner users are pointed at the web UI. Kept in one place so a
 * domain change does not have to hunt through the command handlers.
 */
const PUBLIC_JELLYFIN_URL = process.env.PUBLIC_JELLYFIN_URL || 'https://jellyfin.lolisticos.com';

// Which JIDs have already seen the greeting. Persisted next to the session so a
// restart does not greet everyone again.
const GREETED_FILE = join(authDir, 'greeted-users.json');

function readGreeted() {
  try {
    if (!existsSync(GREETED_FILE)) {
      return [];
    }
    const parsed = JSON.parse(readFileSync(GREETED_FILE, 'utf8'));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    // An unreadable marker only costs one extra greeting, never a crash.
    return [];
  }
}

function hasBeenWelcomed(jid) {
  return readGreeted().includes(String(jid || ''));
}

function markWelcomed(jid) {
  const key = String(jid || '');
  if (!key) {
    return;
  }
  const greeted = readGreeted();
  if (greeted.includes(key)) {
    return;
  }
  greeted.push(key);
  try {
    writeFileSync(GREETED_FILE, JSON.stringify(greeted, null, 2), { mode: 0o600 });
  } catch {
    // Keep the in-process view consistent even if the write fails.
  }
}

function handleWelcome() {
  return formatPanel(
    'Bienvenido al bot del servidor',
    [
      {
        title: 'Como pedir peliculas y series',
        lines: [
          '- /peli nombre de la pelicula',
          '- /serie nombre de la serie',
          '- /buscar nombre para orientarte rapido',
          '- Te muestro opciones y contestas "peli 1" o "serie 2"',
        ],
      },
      {
        title: 'Ver que esta pasando',
        lines: [
          '- /status        estado del servidor',
          '- /cola          descargas en curso',
          '- /pedidos       pedidos pendientes',
          '- /espacio       espacio en disco',
          '- /subs          estado de subtitulos en espanol',
        ],
      },
      {
        title: 'Explorar la biblioteca',
        lines: [
          '- /catalogo      peliculas y series disponibles',
          '- /faltantes     lo que se pidio y no esta',
          '- /azar          recomendacion al azar',
          '- /ultimo        lo ultimo agregado',
        ],
      },
      {
        title: 'Para ver peliculas y series',
        lines: [
          `- ${PUBLIC_JELLYFIN_URL}`,
          '- Necesitas tu propia cuenta para entrar.',
          '- Si no tenes usuario, pedilo y te lo creo.',
        ],
      },
      {
        title: 'Navegar resultados',
        lines: [
          '- /mas           ver mas resultados',
          '- /repetir       repetir la ultima lista',
          '- /cancelar      cancelar',
          '- /ayuda         todos los comandos',
        ],
      },
    ],
    ' cualquier duda, /ayuda',
  );
}

module.exports = {
  handleWelcome,
  hasBeenWelcomed,
  markWelcomed,
  PUBLIC_JELLYFIN_URL,
};
