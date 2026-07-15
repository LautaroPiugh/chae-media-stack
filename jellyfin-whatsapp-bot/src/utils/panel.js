function formatPanel(title, sections = [], footer = '') {
  let response = `[ ${title} ]\n\n`;

  sections.forEach((section, index) => {
    if (!section || !section.lines || section.lines.length === 0) {
      return;
    }

    if (section.title) {
      response += `${section.title}\n`;
    }

    response += `${section.lines.join('\n')}\n`;

    if (index < sections.length - 1) {
      response += '\n';
    }
  });

  if (footer) {
    response += `\n${footer}`;
  }

  return response.trim();
}

module.exports = {
  formatPanel,
};
