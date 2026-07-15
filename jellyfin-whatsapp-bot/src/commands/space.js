const { formatPanel } = require('../utils/panel');
const { getDiskSummary } = require('../utils/diskSummary');

async function handleSpace() {
  const disk = await getDiskSummary();

  if (!disk) {
    return formatPanel('Espacio de discos', [
      {
        lines: ['- No pude leer el estado de los discos ahora mismo'],
      },
    ]);
  }

  return formatPanel('Espacio de discos', [
    {
      title: 'Pool',
      lines: [
        `- Usado: ${disk.pool.used} / ${disk.pool.total} (${disk.pool.usedPct}%)`,
        `- Libre: ${disk.pool.free}`,
      ],
    },
    {
      title: 'Disco 1',
      lines: [
        `- Usado: ${disk.media1.used} / ${disk.media1.total} (${disk.media1.usedPct}%)`,
        `- Libre: ${disk.media1.free}`,
      ],
    },
    {
      title: 'Disco 2',
      lines: [
        `- Usado: ${disk.media2.used} / ${disk.media2.total} (${disk.media2.usedPct}%)`,
        `- Libre: ${disk.media2.free}`,
      ],
    },
  ]);
}

module.exports = {
  handleSpace,
};
