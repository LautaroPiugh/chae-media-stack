const { getRecommendedSuggestion, formatSuggestion } = require('../utils/libraryRecommendations');
const { formatErrorPanel } = require('../utils/formatMessage');

async function handleRecommend(text) {
  const lower = text.toLowerCase().trim();
  const type = lower.includes(' serie') || lower.endsWith('serie') ? 'series' : lower.includes(' peli') || lower.endsWith('peli') ? 'movie' : 'all';
  const genre = lower.replace('/recomendar', '').replace(/\bpeli\b|\bserie\b/g, '').trim();
  const item = await getRecommendedSuggestion(type === 'series' ? 'series' : type, genre);

  if (!item) {
    return formatErrorPanel('Recomendación', [genre ? `- No encontré nada descargado para el género "${genre}"` : '- No encontré contenido descargado para recomendar']);
  }

  return formatSuggestion(item, item.type === 'movie' ? 'Recomendación de peli' : 'Recomendación de serie', genre ? `te la elegí por género: ${genre}` : 'te la elegí por catálogo y preferencia por no visto');
}

module.exports = {
  handleRecommend,
};
