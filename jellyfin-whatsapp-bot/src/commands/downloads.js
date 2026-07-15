const { handleQueue } = require('./queue');

async function handleDownloads() {
  return handleQueue();
}

module.exports = {
  handleDownloads,
};
