const crypto = require('crypto');
const {
  getSystemUpdateStatus,
  previewSystemUpdate,
  startSystemUpdate,
} = require('../clients/updateBrokerClient');
const { formatPanel } = require('../utils/panel');
const { normalizeUserJid } = require('../utils/jid');

const CONFIRMATION_TTL_MS = 10 * 60 * 1000;
const confirmations = new Map();

function shortCommit(value) {
  return String(value || '').slice(0, 8) || 'desconocido';
}

function createConfirmation(userJid, preview, now = Date.now()) {
  const normalized = normalizeUserJid(userJid);
  const code = String(crypto.randomInt(100000, 1000000));
  confirmations.set(normalized, {
    code,
    preview,
    expiresAt: now + CONFIRMATION_TTL_MS,
  });
  return code;
}

function consumeConfirmation(userJid, code, now = Date.now()) {
  const normalized = normalizeUserJid(userJid);
  const pending = confirmations.get(normalized);
  if (!pending) {
    return { ok: false, reason: 'missing' };
  }
  if (pending.expiresAt < now) {
    confirmations.delete(normalized);
    return { ok: false, reason: 'expired' };
  }
  const expected = Buffer.from(pending.code);
  const supplied = Buffer.from(String(code || ''));
  if (expected.length !== supplied.length || !crypto.timingSafeEqual(expected, supplied)) {
    return { ok: false, reason: 'invalid' };
  }
  confirmations.delete(normalized);
  return { ok: true, preview: pending.preview };
}

function cancelConfirmation(userJid) {
  return confirmations.delete(normalizeUserJid(userJid));
}

function formatStatus(job) {
  const statusNames = {
    idle: 'Sin ejecuciones registradas',
    running: 'En ejecución',
    completed: 'Completada',
    failed: 'Fallida',
  };
  const lines = [
    `- Estado: ${statusNames[job.status] || job.status || 'desconocido'}`,
    `- Fase: ${job.phase || 'ninguna'}`,
  ];
  if (job.id) lines.push(`- Trabajo: ${job.id}`);
  if (job.current) lines.push(`- Objetivo actual: ${job.current}`);
  if (job.completed?.length) lines.push(`- Completados: ${job.completed.join(', ')}`);
  if (job.message) lines.push(`- Detalle: ${job.message}`);
  return formatPanel('Actualización del sistema', [{ lines }]);
}

async function handleSystemUpdatePreview(userJid) {
  try {
    const preview = await previewSystemUpdate();
    const code = createConfirmation(userJid, preview);
    const gitChange = preview.git?.current === preview.git?.remote
      ? 'sin cambios remotos'
      : `${shortCommit(preview.git?.current)} -> ${shortCommit(preview.git?.remote)}`;
    return formatPanel('Confirmar actualización del sistema', [
      {
        title: 'Plan validado',
        lines: [
          `- Git: ${gitChange}`,
          ...(preview.git?.dirty ? ['- Git local: hay cambios; solo se permite continuar mientras origin/main no cambie'] : []),
          `- Huella del código: ${shortCommit(preview.git?.treeHash)}`,
          `- Docker: ${(preview.services || []).join(', ')}`,
          '- Bot: pruebas, reconstrucción y reinicio al final',
          '- Estrategia: secuencial; se detiene ante el primer fallo',
        ],
      },
      {
        title: 'Código de un solo uso',
        lines: [
          `- confirmar actualizacion ${code}`,
          '- Expira en 10 minutos',
        ],
      },
    ], 'Usá /cancelar actualizacion para invalidarlo.');
  } catch (error) {
    return formatPanel('Actualización no disponible', [{
      lines: [`- El preflight falló: ${error.message}`],
    }]);
  }
}

async function handleSystemUpdateConfirm(userJid, text) {
  const code = String(text || '').trim().split(/\s+/).at(-1);
  const confirmation = consumeConfirmation(userJid, code);
  if (!confirmation.ok) {
    const reason = confirmation.reason === 'expired'
      ? 'El código expiró; ejecutá /actualizarsistema otra vez'
      : 'El código es inválido o ya fue utilizado';
    return formatPanel('Confirmación rechazada', [{ lines: [`- ${reason}`] }]);
  }

  try {
    const result = await startSystemUpdate(
      confirmation.preview.git?.remote,
      confirmation.preview.git?.treeHash,
    );
    return formatPanel('Actualización iniciada', [{
      lines: [
        `- Trabajo: ${result.jobId}`,
        '- La cola seguirá aunque el bot se reinicie',
        '- Usá /actualizarsistema estado para ver el progreso',
      ],
    }]);
  } catch (error) {
    return formatPanel('No se pudo iniciar', [{ lines: [`- ${error.message}`] }]);
  }
}

async function handleSystemUpdateStatus() {
  try {
    const result = await getSystemUpdateStatus();
    return formatStatus(result.job || {});
  } catch (error) {
    return formatPanel('Estado no disponible', [{ lines: [`- ${error.message}`] }]);
  }
}

function handleSystemUpdateCancel(userJid) {
  const removed = cancelConfirmation(userJid);
  return formatPanel('Confirmación de actualización', [{
    lines: [removed ? '- Código invalidado' : '- No había un código pendiente'],
  }]);
}

module.exports = {
  CONFIRMATION_TTL_MS,
  cancelConfirmation,
  consumeConfirmation,
  createConfirmation,
  formatStatus,
  handleSystemUpdateCancel,
  handleSystemUpdateConfirm,
  handleSystemUpdatePreview,
  handleSystemUpdateStatus,
};
