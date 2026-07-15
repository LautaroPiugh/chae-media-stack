const { formatPanel } = require('./panel');

function humanSize(bytes) {
  if (!bytes || bytes <= 0) {
    return '';
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

function radarrMovieMessage(movie, isUpgrade = false) {
  const extra = [];
  if (movie.quality) {
    extra.push(`Calidad: ${movie.quality}`);
  }
  if (movie.size) {
    extra.push(`Tamaño: ${humanSize(movie.size)}`);
  }

  const extraText = extra.length > 0 ? `\n${extra.join('\n')}\n` : '\n';

  if (isUpgrade) {
    return formatPanel('Película actualizada en Jellyfin', [
      {
        lines: [
          `- ✅ ${movie.title} (${movie.year}) fue actualizada con una mejor calidad`,
          ...extra.map((item) => `- ${item}`),
        ],
      },
      {
        title: 'Jellyfin',
        lines: [movie.jellyfinUrl],
      },
    ]);
  }

  return formatPanel('Película lista en Jellyfin', [
    {
      lines: [
        `- ✅ ${movie.title} (${movie.year}) ya terminó de descargarse y fue agregada a tu biblioteca`,
        ...extra.map((item) => `- ${item}`),
      ],
    },
    {
      title: 'Jellyfin',
      lines: [movie.jellyfinUrl],
    },
  ]);
}

function sonarrEpisodeMessage(episode, isUpgrade = false) {
  const seasonEpisode = `S${String(episode.seasonNumber).padStart(2, '0')}E${String(episode.episodeNumber).padStart(2, '0')}`;
  const extra = [];
  if (episode.quality) {
    extra.push(`Calidad: ${episode.quality}`);
  }
  if (episode.size) {
    extra.push(`Tamaño: ${humanSize(episode.size)}`);
  }

  const extraText = extra.length > 0 ? `\n${extra.join('\n')}\n` : '\n';

  if (isUpgrade) {
    return formatPanel('Episodio actualizado en Jellyfin', [
      {
        lines: [
          `- ✅ ${episode.seriesTitle} - ${seasonEpisode} fue actualizado con una mejor calidad`,
          `- Título: ${episode.episodeTitle}`,
          ...extra.map((item) => `- ${item}`),
        ],
      },
      {
        title: 'Jellyfin',
        lines: [episode.jellyfinUrl],
      },
    ]);
  }

  return formatPanel('Episodio disponible en Jellyfin', [
    {
      lines: [
        `- ✅ ${episode.seriesTitle} - ${seasonEpisode} ya fue descargado e importado`,
        `- Título: ${episode.episodeTitle}`,
        ...extra.map((item) => `- ${item}`),
      ],
    },
    {
      title: 'Jellyfin',
      lines: [episode.jellyfinUrl],
    },
  ]);
}

function formatTitleLine(item) {
  const year = item.year || 's/a';
  const originalTitle = (item.originalTitle || '').trim();

  if (originalTitle && originalTitle.toLowerCase() !== (item.title || '').toLowerCase()) {
    return `${item.title} (${year})\nTítulo original: ${originalTitle}`;
  }

  return `${item.title} (${year})`;
}

function appendIndented(lines, value) {
  if (!value) {
    return;
  }

  String(value)
    .split('\n')
    .forEach((line) => lines.push(`   ${line}`));
}

function formatResultLine(index, item, extras = []) {
  const [firstLine, ...rest] = formatTitleLine(item).split('\n');
  const lines = [`${index}. ${firstLine}`];
  rest.forEach((line) => lines.push(`   ${line}`));
  extras.filter(Boolean).forEach((extra) => appendIndented(lines, extra));
  return lines.join('\n');
}

function formatActions(actions) {
  if (!actions.length) {
    return '';
  }

  return `Acciones\n${actions.map((action) => `- ${action}`).join('\n')}`;
}

function formatInfoPanel(title, lines = [], footer = '') {
  return formatPanel(title, [{ lines }], footer);
}

function formatErrorPanel(title, lines = [], footer = '') {
  return formatPanel(title, [{ lines }], footer);
}

function formatBrowsePage(pending) {
  const pageSize = pending.pageSize || 5;
  const page = pending.page || 0;
  const start = page * pageSize;
  const items = pending.results.slice(start, start + pageSize);
  const currentPage = page + 1;
  const totalPages = Math.max(1, Math.ceil(pending.results.length / pageSize));
  const title = pending.type === 'movie' ? '🎬' : '📺';
  const label = pending.type === 'movie' ? 'peli' : 'serie';

  let heading = `${title} Resultados para "${pending.query}"`;
  if (pending.mode === 'catalog') {
    heading = `${title} Catálogo de ${pending.type === 'movie' ? 'películas' : 'series'}`;
  } else if (pending.mode === 'missing') {
    heading = `${title} ${pending.type === 'movie' ? 'Películas' : 'Series'} faltantes`;
  }

  const lines = [`Página ${currentPage} de ${totalPages}`, ''];

  items.forEach((item, idx) => {
    const globalIndex = start + idx + 1;
    const extras = [];

    if (pending.type === 'movie' && item.director) {
      extras.push(`Año: ${item.year || 's/a'}`);
      extras.push(`Director: ${item.director}`);
    } else if (pending.type === 'movie') {
      extras.push(`Año: ${item.year || 's/a'}`);
    }

    if (pending.type === 'series' && pending.mode !== 'search' && typeof item.episodeFileCount === 'number') {
      extras.push(`Episodios: ${item.episodeFileCount}/${item.totalEpisodeCount || item.episodeFileCount}`);
    }

    lines.push(formatResultLine(globalIndex, item, extras), '');
  });

  const actions = [];
  if (pending.mode === 'search') {
    actions.push(`Respondé "${label} <número>" o solo el número`);
  }

  if (currentPage < totalPages) {
    actions.push('Usá "/mas" para ver más resultados');
  }

  actions.push('Usá "/repetir" para volver a mostrar esta lista');
  actions.push('Usá "/cancelar" para cerrar este flujo');

  lines.push(formatActions(actions));
  return formatPanel(heading, [{ lines }]);
}

function formatDeletePage(pending) {
  const pageSize = pending.pageSize || 10;
  const page = pending.page || 0;
  const start = page * pageSize;
  const items = pending.results.slice(start, start + pageSize);
  const currentPage = page + 1;
  const totalPages = Math.max(1, Math.ceil(pending.results.length / pageSize));

  const lines = [`Búsqueda: ${pending.query}`, `Página ${currentPage} de ${totalPages}`, ''];

  items.forEach((item, idx) => {
    const globalIndex = start + idx + 1;
    lines.push(formatResultLine(globalIndex, item, [item.kind === 'movie' ? 'Tipo: película' : 'Tipo: serie']), '');
  });

  const actions = [
    'Respondé "eliminar <número>" para elegir uno',
    'Usá "/repetir" para volver a mostrar esta lista',
    'Usá "/cancelar" para cerrar este flujo',
  ];

  if (currentPage < totalPages) {
    actions.unshift('Usá "/mas" para ver más resultados');
  }

  lines.push(formatActions(actions));
  return formatPanel('Eliminar de biblioteca', [{ lines }]);
}

function formatUpdatePage(pending) {
  const pageSize = pending.pageSize || 10;
  const page = pending.page || 0;
  const start = page * pageSize;
  const items = pending.results.slice(start, start + pageSize);
  const currentPage = page + 1;
  const totalPages = Math.max(1, Math.ceil(pending.results.length / pageSize));

  const lines = [`Búsqueda: ${pending.query}`, `Página ${currentPage} de ${totalPages}`, ''];

  items.forEach((item, idx) => {
    const globalIndex = start + idx + 1;
    const extras = [item.kind === 'movie' ? 'Tipo: película' : 'Tipo: serie'];
    if (item.kind === 'movie') {
      const quality = item.raw?.movieFile?.quality?.quality?.name || item.raw?.movieFile?.quality?.name;
      if (quality) {
        extras.push(`Calidad actual: ${quality}`);
      }
    }

    lines.push(formatResultLine(globalIndex, item, extras), '');
  });

  const actions = [
    'Respondé "actualizar <número>" para elegir qué mejora querés',
    'Usá "/repetir" para volver a mostrar esta lista',
    'Usá "/cancelar" para cerrar este flujo',
  ];

  if (currentPage < totalPages) {
    actions.unshift('Usá "/mas" para ver más resultados');
  }

  lines.push(formatActions(actions));
  return formatPanel('Actualizar búsqueda', [{ lines }]);
}

function formatUpdateQualityPage(pending) {
  const item = pending.item;
  const options = pending.options || [];
  const quality = item?.raw?.movieFile?.quality?.quality?.name || item?.raw?.movieFile?.quality?.name || 'desconocida';

  return formatPanel('Actualizar calidad', [
    {
      lines: [
        `- 🎬 ${item.title} (${item.year || 's/a'})`,
        `- Calidad actual: ${quality}`,
        '',
        'Opciones',
        ...options.map((option, index) => `- ${index + 1}. ${option.label}`),
        '',
        'Acciones',
        '- Respondé "actualizar <número>" o solo el número',
        '- Usá "/cancelar" para cerrar este flujo',
      ],
    },
  ]);
}

function formatRefreshPage(pending) {
  const pageSize = pending.pageSize || 10;
  const page = pending.page || 0;
  const start = page * pageSize;
  const items = pending.results.slice(start, start + pageSize);
  const currentPage = page + 1;
  const totalPages = Math.max(1, Math.ceil(pending.results.length / pageSize));

  const lines = [`Serie: ${pending.query}`, `Página ${currentPage} de ${totalPages}`, ''];

  items.forEach((item, idx) => {
    const globalIndex = start + idx + 1;
    lines.push(formatResultLine(globalIndex, item, [`Episodios: ${item.episodeFileCount}/${item.totalEpisodeCount || item.episodeFileCount}`]), '');
  });

  const actions = [
    'Respondé "refrescar <número>" para ejecutar refresh y rescan',
    'Usá "/repetir" para volver a mostrar esta lista',
    'Usá "/cancelar" para cerrar este flujo',
  ];

  if (currentPage < totalPages) {
    actions.unshift('Usá "/mas" para ver más resultados');
  }

  lines.push(formatActions(actions));
  return formatPanel('Refresh y rescan', [{ lines }]);
}

function formatRequestsPage(pending) {
  const pageSize = pending.pageSize || 10;
  const page = pending.page || 0;
  const start = page * pageSize;
  const items = pending.results.slice(start, start + pageSize);
  const currentPage = page + 1;
  const totalPages = Math.max(1, Math.ceil(pending.results.length / pageSize));

  const lines = [`Página ${currentPage} de ${totalPages}`, ''];

  items.forEach((item, idx) => {
    const globalIndex = start + idx + 1;
    lines.push(formatResultLine(globalIndex, item, item.extras || []), '');
  });

  const actions = [];
  if (currentPage < totalPages) {
    actions.push('Usá "/mas" para ver más resultados');
  }
  actions.push('Usá "/repetir" para volver a mostrar esta lista');
  actions.push('Usá "/cancelar" para cerrar este flujo');

  lines.push(formatActions(actions));
  return formatPanel(pending.heading || 'Pedidos', [{ lines }], pending.footer || '');
}

function formatPendingView(pending) {
  if (!pending) {
    return 'No tenés ningún flujo pendiente.';
  }

  if (pending.mode === 'delete_search') {
    return formatDeletePage(pending);
  }

  if (pending.mode === 'update_search') {
    return formatUpdatePage(pending);
  }

  if (pending.mode === 'update_quality_select') {
    return formatUpdateQualityPage(pending);
  }

  if (pending.mode === 'refresh_search') {
    return formatRefreshPage(pending);
  }

  if (pending.mode === 'requests_page') {
    return formatRequestsPage(pending);
  }

  return formatBrowsePage(pending);
}

module.exports = {
  radarrMovieMessage,
  sonarrEpisodeMessage,
  formatBrowsePage,
  formatPendingView,
  formatInfoPanel,
  formatErrorPanel,
  humanSize,
};
