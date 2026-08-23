const { isAdminUser } = require('./admin');
const { formatNoPermission } = require('./admin');
const { formatPanel } = require('../utils/panel');

function getDefaultSections() {
  return [
    {
      title: 'Uso diario',
      lines: [
        '- /status',
        '- /cola',
        '- /pedidos',
        '- /mispedidos',
        '- /espacio',
        '- /buscar nombre',
      ],
    },
    {
      title: 'Buscar y agregar',
      lines: [
        '- /peli nombre',
        '- /serie nombre',
        '- /buscar nombre para orientarte rápido',
        '- respondé peli 1, serie 2 o solo 7',
      ],
    },
    {
      title: 'Biblioteca',
      lines: [
        '- /catalogo',
        '- /faltantes',
        '- /ultimo',
        '- /azar',
        '- /recomendar [genero]',
      ],
    },
    {
      title: 'Gestion',
      lines: [
        '- /actualizar nombre',
      ],
    },
    {
      title: 'Navegacion',
      lines: [
        '- /mas',
        '- /repetir',
        '- /cancelar',
      ],
    },
  ];
}

function getAdminSection() {
  return {
    title: 'Admin',
    lines: [
      '- /refrescar nombre',
      '- /eliminar nombre',
      '- /vistas',
      '- /limpiartorrents',
      '- /reconectar',
      '- /reiniciar',
      '- /agu-whitelist dominio',
      '- /agu-off',
      '- /agu-on',
      '- /agu-status',
      '- /descargar-tendencias',
      '- /actualizarsistema',
      '- /actualizarsistema estado',
    ],
  };
}

function handleHelp(userJid, text = '/ayuda') {
  const lower = String(text || '/ayuda').toLowerCase().trim();
  const adminView = lower === '/ayuda admin' || lower === '/help admin';
  const admin = isAdminUser(userJid);

  if (adminView && !admin) {
    return formatNoPermission();
  }

  if (adminView) {
    return formatPanel('Jellyfin WhatsApp Bot Admin', [
      getAdminSection(),
      {
        title: 'Flujos compartidos',
        lines: [
          '- /actualizar nombre',
          '- /peli nombre',
          '- /serie nombre',
          '- /buscar nombre',
          '- /status',
          '- /cola',
          '- /pedidos',
          '- /mispedidos',
          '- /espacio',
        ],
      },
    ], 'Tip: usá /ayuda para volver al panel general.');
  }

  const sections = [
    ...getDefaultSections(),
  ];

  if (admin) {
    sections.push(getAdminSection());
  }

  return formatPanel('Jellyfin WhatsApp Bot', sections, 'Tip: pedime una peli o una serie y te guio paso a paso.');
}

module.exports = { handleHelp };
