function formatMovieMessage(movie, isUpgrade = false) {
  const title = movie?.title || 'Unknown';
  const year = movie?.year || 'Unknown';

  const emoji = isUpgrade ? '🎬' : '🎬';
  const action = isUpgrade ? 'actualizada' : 'lista';

  return `${emoji} Película ${action} en Jellyfin

✅ ${title} (${year}) ya terminó de descargarse y fue ${isUpgrade ? 'actualizada' : 'agregada'} a tu biblioteca.

Ya podés verla desde Jellyfin:
${process.env.JELLYFIN_URL || 'https://jellyfin.local'}`;
}

function formatEpisodeMessage(series, episodes, isUpgrade = false) {
  const seriesTitle = series?.title || 'Unknown';

  if (!episodes || episodes.length === 0) {
    return null;
  }

  if (episodes.length === 1) {
    const ep = episodes[0];
    const season = String(ep.seasonNumber || 0).padStart(2, '0');
    const episode = String(ep.episodeNumber || 0).padStart(2, '0');
    const episodeTitle = ep.title || 'Unknown';

    return `${isUpgrade ? '📺 Episodio actualizado' : '📺 Episodio disponible'} en Jellyfin

✅ ${seriesTitle} — S${season}E${episode} ya fue descargado${isUpgrade ? ' y actualizado' : ''} e importado.

Título: ${episodeTitle}

Ya podés verlo desde Jellyfin:
${process.env.JELLYFIN_URL || 'https://jellyfin.local'}`;
  }

  const episodeList = episodes.map((ep) => {
    const season = String(ep.seasonNumber || 0).padStart(2, '0');
    const episode = String(ep.episodeNumber || 0).padStart(2, '0');
    return `S${season}E${episode} - ${ep.title || 'Unknown'}`;
  }).join('\n');

  return `${isUpgrade ? '📺 Episodios actualizados' : '📺 Episodios disponibles'} en Jellyfin

✅ ${seriesTitle} — ${episodes.length} episodio${episodes.length > 1 ? 's' : ''} ya fuero${isUpgrade ? 'n actualizados' : 'n descargados'} e importados.

Episodios:
${episodeList}

Ya podés verlos desde Jellyfin:
${process.env.JELLYFIN_URL || 'https://jellyfin.local'}`;
}

module.exports = {
  formatMovieMessage,
  formatEpisodeMessage,
};