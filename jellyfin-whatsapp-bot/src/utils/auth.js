const { existsSync, mkdirSync } = require('fs');
const { join } = require('path');

const authDir = join(__dirname, '../../auth');

function ensureAuthDir() {
  if (!existsSync(authDir)) {
    mkdirSync(authDir, { recursive: true });
  }
}

module.exports = {
  authDir,
  ensureAuthDir,
};