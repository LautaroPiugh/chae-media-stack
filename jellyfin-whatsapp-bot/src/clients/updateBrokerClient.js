const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const config = require('../config');

function readSecret() {
  const secret = fs.readFileSync(config.systemUpdate.secretFile, 'utf8').trim();
  if (secret.length < 32 || secret.startsWith('CHANGEME')) {
    throw new Error('el secreto del broker no está configurado');
  }
  return secret;
}

function signRequest(secret, timestamp, nonce, method, path, body) {
  const payload = [timestamp, nonce, method, path, body].join('\n');
  return crypto.createHmac('sha256', secret).update(payload).digest('hex');
}

function requestBroker(method, path, payload = null) {
  const body = payload === null ? '' : JSON.stringify(payload);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const nonce = crypto.randomBytes(16).toString('hex');
  const signature = signRequest(readSecret(), timestamp, nonce, method, path, body);

  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath: config.systemUpdate.socketPath,
      path,
      method,
      timeout: config.systemUpdate.timeoutMs,
      headers: {
        accept: 'application/json',
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
        'x-update-timestamp': timestamp,
        'x-update-nonce': nonce,
        'x-update-signature': signature,
      },
    }, (response) => {
      let responseBody = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        if (responseBody.length < 65536) {
          responseBody += chunk;
        }
      });
      response.on('end', () => {
        let parsed;
        try {
          parsed = JSON.parse(responseBody || '{}');
        } catch {
          reject(new Error('el broker devolvió una respuesta inválida'));
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          const error = new Error(parsed.message || parsed.error || `broker HTTP ${response.statusCode}`);
          error.code = parsed.error || 'broker_error';
          error.statusCode = response.statusCode;
          reject(error);
          return;
        }
        resolve(parsed);
      });
    });

    request.on('timeout', () => request.destroy(new Error('el broker no respondió a tiempo')));
    request.on('error', (error) => reject(new Error(`no se pudo contactar al broker: ${error.message}`)));
    request.end(body);
  });
}

function previewSystemUpdate() {
  return requestBroker('POST', '/v1/preview', {});
}

function startSystemUpdate(approvedCommit, approvedTreeHash) {
  return requestBroker('POST', '/v1/start', { approvedCommit, approvedTreeHash });
}

function getSystemUpdateStatus() {
  return requestBroker('GET', '/v1/status');
}

module.exports = {
  getSystemUpdateStatus,
  previewSystemUpdate,
  requestBroker,
  signRequest,
  startSystemUpdate,
};
