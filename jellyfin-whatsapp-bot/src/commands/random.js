const { getRandomSuggestion, formatSuggestion } = require('../utils/libraryRecommendations');
const { formatErrorPanel } = require('../utils/formatMessage');

async function handleRandom(text) {
  const lower = text.toLowerCase().trim();
  const type = lower.includes('serie') ? 'series' : lower.includes('peli') ? 'movie' : 'all';
  const item = await getRandomSuggestion(type === 'series' ? 'series' : type);

  if (!item) {
    return formatErrorPanel('Random', ['- No encontré contenido descargado para elegir al azar']);
  }

  return formatSuggestion(item, item.type === 'movie' ? 'Peli random' : 'Serie random', 'elección al azar dentro de tu biblioteca');
}

module.exports = {
  handleRandom,
};
