function normalize(text) {
  return (text || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function scoreMatch(item, query) {
  const normalizedQuery = normalize(query);
  const title = normalize(item.title);
  const originalTitle = normalize(item.originalTitle);

  if (title === normalizedQuery || originalTitle === normalizedQuery) return 100;
  if (title.startsWith(normalizedQuery) || originalTitle.startsWith(normalizedQuery)) return 80;
  if (title.includes(normalizedQuery) || originalTitle.includes(normalizedQuery)) return 60;
  return 0;
}

function searchLocal(items, query, limit = 10) {
  return items
    .map((item) => ({ item, score: scoreMatch(item, query) }))
    .filter(({ score }) => score > 0)
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return (b.item.year || 0) - (a.item.year || 0);
    })
    .slice(0, limit)
    .map(({ item }) => item);
}

module.exports = {
  normalize,
  scoreMatch,
  searchLocal,
};
