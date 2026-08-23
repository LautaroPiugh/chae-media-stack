'use strict';

const DEFAULT_TIMEOUT_MS = Number(process.env.HTTP_TIMEOUT_MS || 10000);
const DEFAULT_RETRIES = Number(process.env.HTTP_RETRIES ?? 2);
const RETRYABLE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Igual contrato que fetch(): devuelve la Response sin consumir.
 * Agrega timeout por intento y reintentos ante errores de red o 5xx,
 * solo para métodos idempotentes (GET/HEAD/OPTIONS).
 */
async function fetchWithTimeout(url, init = {}, options = {}) {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const retries = options.retries ?? DEFAULT_RETRIES;
  const method = String(init.method || 'GET').toUpperCase();
  const canRetry = RETRYABLE_METHODS.has(method);

  let lastError;

  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const response = await fetch(url, {
        ...init,
        signal: AbortSignal.timeout(timeoutMs),
      });

      if (!canRetry || attempt === retries || response.status < 500) {
        return response;
      }

      lastError = new Error(`HTTP ${response.status} en ${url}`);
    } catch (error) {
      lastError = error;

      if (!canRetry || attempt === retries) {
        throw error;
      }
    }

    await sleep(500 * (attempt + 1));
  }

  throw lastError;
}

module.exports = { fetchWithTimeout };
