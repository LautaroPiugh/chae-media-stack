const config = require('../config');
const { formatPanel } = require('../utils/panel');

async function fetchBazarr(path) {
  try {
    const url = `${config.bazarr.url}${path}`;
    const res = await fetch(url, {
      headers: { 'X-API-KEY': config.bazarr.apiKey },
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  }
}

async function handleSubs() {
  const [moviesData, seriesData] = await Promise.all([
    fetchBazarr('/api/movies?limit=500'),
    fetchBazarr('/api/series?limit=100'),
  ]);

  const movies = moviesData?.data || [];
  const series = seriesData?.data || [];

  if (!movies.length && !series.length) {
    return formatPanel('Subtítulos ES', [
      { lines: ['No se pudo conectar con Bazarr o no hay contenido.'] },
    ]);
  }

  let movieOk = 0, movieMissing = 0;
  for (const m of movies) {
    const subs = m.subtitles || [];
    const es = subs.some(s => ['es', 'ea', 'sp'].includes(s.code2));
    if (es) movieOk++; else movieMissing++;
  }

  let seriesOk = 0, seriesMissing = 0;
  const missingDetails = [];

  for (const s of series) {
    const epData = await fetchBazarr(`/api/episodes?seriesid%5B%5D=${s.sonarrSeriesId}`);
    const eps = epData?.data || [];
    let sOk = 0, sMiss = 0;
    for (const ep of eps) {
      if (ep.season === 0) continue;
      const subs = ep.subtitles || [];
      const es = subs.some(sb => ['es', 'ea', 'sp'].includes(sb.code2));
      if (es) sOk++; else sMiss++;
    }
    seriesOk += sOk;
    seriesMissing += sMiss;
    if (sMiss > 0) {
      missingDetails.push(`${s.title}: ${sMiss} ep. sin ES`);
    }
  }

  const sections = [
    {
      title: 'Películas',
      lines: [
        `- Con ES: ${movieOk}`,
        movieMissing > 0 ? `- Sin ES: ${movieMissing}` : null,
      ].filter(Boolean),
    },
    {
      title: 'Series',
      lines: [
        `- Episodios con ES: ${seriesOk}`,
        seriesMissing > 0 ? `- Episodios sin ES: ${seriesMissing}` : null,
      ].filter(Boolean),
    },
  ];

  const totalOk = movieOk + seriesOk;
  const totalMissing = movieMissing + seriesMissing;
  const summary = totalMissing > 0
    ? `Total: ${totalOk} con ES, ${totalMissing} faltan`
    : `Total: ${totalOk} con ES ✅`;

  if (missingDetails.length > 0) {
    sections.push({
      title: 'Series incompletas',
      lines: missingDetails.slice(0, 10).map(d => `- ${d}`),
    });
    if (missingDetails.length > 10) {
      sections.push({
        title: '',
        lines: [`... y ${missingDetails.length - 10} más`],
      });
    }
  }

  return formatPanel('Estado de subtítulos ES', sections, summary);
}

module.exports = { handleSubs };
