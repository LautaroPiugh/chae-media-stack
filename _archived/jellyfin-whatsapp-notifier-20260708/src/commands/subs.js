const BAZARR_URL = process.env.BAZARR_URL || 'http://localhost:6767';
const BAZARR_API_KEY = process.env.BAZARR_API_KEY || '';
const HEADERS = { 'X-API-KEY': BAZARR_API_KEY };

async function fetchJson(url) {
  try {
    const r = await fetch(url, { headers: HEADERS, signal: AbortSignal.timeout(15000) });
    if (!r.ok) return null;
    return r.json();
  } catch {
    return null;
  }
}

async function subsCommand() {
  const [moviesData, seriesData] = await Promise.all([
    fetchJson(`${BAZARR_URL}/api/movies?limit=500`),
    fetchJson(`${BAZARR_URL}/api/series?limit=100`),
  ]);

  const movies = moviesData?.data || [];
  const series = seriesData?.data || [];

  let movieOk = 0, movieMissing = 0;
  for (const m of movies) {
    const subs = m.subtitles || [];
    const es = subs.some(s => ['es', 'ea', 'sp'].includes(s.code2));
    if (es) movieOk++; else movieMissing++;
  }

  let seriesLine = '';
  for (const s of series) {
    const eps = await fetchJson(`${BAZARR_URL}/api/episodes`, { "seriesid[]": s.sonarrSeriesId });
  }

  let seriesOk = 0, seriesMissing = 0;
  const missingDetails = [];

  for (const s of series) {
    const epData = await fetchJson(`${BAZARR_URL}/api/episodes?seriesid%5B%5D=${s.sonarrSeriesId}`);
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
      missingDetails.push(`• ${s.title}: ${sMiss} ep. sin ES`);
    }
  }

  let msg = `📺 *Estado de Subtítulos ES*\n\n`;
  msg += `🎬 Películas: ${movieOk} con ES`;
  if (movieMissing > 0) msg += `, ${movieMissing} sin ES`;
  msg += `\n📺 Series: ${seriesOk} ep. con ES`;
  if (seriesMissing > 0) msg += `, ${seriesMissing} sin ES`;
  msg += `\n\n*Resumen:* ${movieOk + seriesOk} con ES`;

  if (movieMissing > 0 || seriesMissing > 0) {
    const total = movieMissing + seriesMissing;
    msg += `, ${total} faltan`;
  }

  if (missingDetails.length > 0) {
    msg += `\n\n*Series incompletas:*\n${missingDetails.slice(0, 10).join('\n')}`;
    if (missingDetails.length > 10) {
      msg += `\n... y ${missingDetails.length - 10} más`;
    }
  }

  return msg;
}

module.exports = { subsCommand };
