const { getPendingRequests, isConfigured } = require('../clients/jellyseerrClient');
const { listRequests: listRememberedRequests } = require('../store/requestOrigins');
const { isSameWhatsAppUser } = require('../utils/jid');
const { setPending } = require('../store/pendingSelections');
const { remember } = require('../utils/cache');
const { formatPanel } = require('../utils/panel');
const { formatErrorPanel, formatPendingView } = require('../utils/formatMessage');

function formatRequestType(request) {
  return request.type === 'tv' ? '📺 Serie' : '🎬 Película';
}

function formatRequestStatus(request) {
  const status = request.status;

  if (status === 1) {
    return 'pendiente';
  }

  if (status === 2) {
    return 'aprobado';
  }

  if (status === 4) {
    return 'procesando';
  }

  return `estado ${status}`;
}

function getRequestTitle(request) {
  return request.media?.title || request.media?.name || request.media?.originalName || request.subject || 'Sin título';
}

function getRequestYear(request) {
  return request.media?.releaseDate?.slice?.(0, 4)
    || request.media?.firstAirDate?.slice?.(0, 4)
    || request.media?.year
    || 's/a';
}

function getRequestedBy(request) {
  return request.requestedBy?.displayName || request.requestedBy?.username || request.requestedBy?.email || 'usuario desconocido';
}

function buildJellyseerrRequestItem(request) {
  return {
    title: `${formatRequestType(request)} ${getRequestTitle(request)}`,
    year: getRequestYear(request),
    extras: [
      `Estado: ${formatRequestStatus(request)}`,
      `Pedido por: ${getRequestedBy(request)}`,
      ...(request.media?.tmdbId ? [`TMDB: ${request.media.tmdbId}`] : []),
    ],
  };
}

function buildRememberedRequestItem(request) {
  const title = request.metadata?.title || `${request.mediaType === 'movie' ? '🎬' : '📺'} pedido`;
  const year = request.metadata?.year || 's/a';
  const requesters = request.requesters || [];

  return {
    title,
    year,
    extras: [
      `Tipo: ${request.mediaType === 'movie' ? 'película' : 'serie'}`,
      `Solicitantes guardados: ${requesters.length}`,
    ],
  };
}

function buildRequestsPending({ heading, footer, results }) {
  return {
    mode: 'requests_page',
    type: 'requests',
    heading,
    footer,
    results,
    page: 0,
    pageSize: 10,
  };
}

async function handleRequests(userJid) {
  if (!isConfigured()) {
    return 'Jellyseerr no está configurado todavía.';
  }

  return remember('command:requests', 30000, async () => {
    const requests = await getPendingRequests();
    if (requests.length === 0) {
      return formatPanel('Pedidos de Jellyseerr', [
        {
          lines: ['- No hay pedidos pendientes ahora mismo'],
        },
      ], 'Tip: usá "/mispedidos" para ver lo pedido desde este bot.');
    }

    const pending = buildRequestsPending({
      heading: 'Pedidos de Jellyseerr',
      footer: 'Tip: usá "/cola" para ver qué ya está bajando o "/mispedidos" para ver lo tuyo.',
      results: requests.map(buildJellyseerrRequestItem),
    });

    if (userJid) {
      setPending(userJid, pending);
    }

    return formatPendingView(pending);
  });
}

async function handleMyRequests(userJid) {
  if (!userJid) {
    return formatErrorPanel('Mis pedidos', ['- No pude identificar tu usuario de WhatsApp']);
  }

  const requests = listRememberedRequests().filter((request) =>
    (request.requesters || []).some((requesterJid) => isSameWhatsAppUser(requesterJid, userJid))
  );

  if (requests.length === 0) {
    return formatPanel('Mis pedidos', [
      {
        lines: ['- No encontré pedidos recientes hechos desde este bot para tu usuario'],
      },
    ]);
  }

  const pending = buildRequestsPending({
    heading: 'Mis pedidos',
    footer: 'Tip: esto muestra pedidos recientes recordados por el bot durante los últimos días.',
    results: requests.map(buildRememberedRequestItem),
  });

  setPending(userJid, pending);
  return formatPendingView(pending);
}

module.exports = {
  handleRequests,
  handleMyRequests,
};
