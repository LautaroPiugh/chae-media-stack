const { execSync } = require('child_process');
const { formatPanel } = require('../utils/panel');

function handleAdguardWhitelist(text) {
  const domain = text.replace(/^\/agu-whitelist\s*/i, '').trim();
  if (!domain) {
    return formatPanel('AdGuard Whitelist', [
      { lines: ['Falta el dominio', '', 'Uso: /agu-whitelist <dominio>', 'Ej: /agu-whitelist ejemplo.com'] },
    ]);
  }
  if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(domain)) {
    return formatPanel('AdGuard Whitelist', [{ lines: ['Dominio invalido'] }]);
  }

  const rule = `@@||${domain}^`;

  try {
    try {
      execSync(
        `docker exec chae-adguard sh -c "grep -qF '${rule}' /opt/adguardhome/conf/AdGuardHome.yaml"`,
        { timeout: 5000, stdio: 'pipe' }
      );
      return formatPanel('AdGuard Whitelist', [{ lines: [`${domain} ya esta en la whitelist`] }]);
    } catch (_) {}

    let isEmpty = false;
    try {
      execSync(
        `docker exec chae-adguard sh -c "grep -q 'user_rules: \\[\\]' /opt/adguardhome/conf/AdGuardHome.yaml"`,
        { timeout: 5000, stdio: 'pipe' }
      );
      isEmpty = true;
    } catch (_) {}

    if (isEmpty) {
      execSync(
        `docker exec chae-adguard sh -c "sed -i 's/user_rules: \\[\\]/user_rules:\\n  - ${rule}/' /opt/adguardhome/conf/AdGuardHome.yaml"`,
        { timeout: 10000, stdio: 'pipe' }
      );
    } else {
      execSync(
        `docker exec chae-adguard sh -c "sed -i '/^user_rules:/a\\\\  - ${rule}' /opt/adguardhome/conf/AdGuardHome.yaml"`,
        { timeout: 10000, stdio: 'pipe' }
      );
    }

    execSync('docker restart chae-adguard', { timeout: 15000, stdio: 'pipe' });

    return formatPanel('AdGuard Whitelist', [{ lines: [`${domain} agregado a la whitelist`] }]);
  } catch (e) {
    return formatPanel('AdGuard Whitelist', [{ lines: [`Error: ${e.message}`] }]);
  }
}

function handleAdguardOff() {
  try {
    execSync('docker stop chae-adguard', { timeout: 10000, stdio: 'pipe' });
    return formatPanel('AdGuard', [{ lines: ['AdGuard apagado'] }]);
  } catch (e) {
    return formatPanel('AdGuard', [{ lines: [`Error: ${e.message}`] }]);
  }
}

function handleAdguardOn() {
  try {
    execSync('docker start chae-adguard', { timeout: 10000, stdio: 'pipe' });
    return formatPanel('AdGuard', [{ lines: ['AdGuard encendido'] }]);
  } catch (e) {
    return formatPanel('AdGuard', [{ lines: [`Error: ${e.message}`] }]);
  }
}

function handleAdguardStatus() {
  try {
    const result = execSync(
      "docker ps --format '{{.Names}}' -f name=chae-adguard",
      { timeout: 5000, stdio: 'pipe' }
    ).toString().trim();
    const status = result.includes('chae-adguard') ? 'ENCENDIDO' : 'APAGADO';
    return formatPanel('AdGuard', [{ lines: [`AdGuard: ${status}`] }]);
  } catch (e) {
    return formatPanel('AdGuard', [{ lines: ['AdGuard: APAGADO'] }]);
  }
}

module.exports = { handleAdguardWhitelist, handleAdguardOff, handleAdguardOn, handleAdguardStatus };
