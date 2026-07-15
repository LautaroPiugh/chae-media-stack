const { deletePending, getPending, updatePending } = require('../store/pendingSelections');
const { formatPendingView } = require('../utils/formatMessage');

function handleRepeat(userJid) {
  const pending = getPending(userJid);
  if (!pending) {
    return 'No tenés ninguna búsqueda pendiente.';
  }

  return formatPendingView(pending);
}

function handleMore(userJid) {
  const pending = getPending(userJid);
  if (!pending) {
    return 'No tenés ninguna búsqueda pendiente.';
  }

  const pageSize = pending.pageSize || 5;
  const totalPages = Math.ceil(pending.results.length / pageSize);
  const nextPage = (pending.page || 0) + 1;

  if (nextPage >= totalPages) {
    return 'No hay más resultados para mostrar. Usá /repetir para ver la página actual.';
  }

  const updated = updatePending(userJid, () => ({ page: nextPage }));
  return formatPendingView(updated);
}

function handleCancel(userJid) {
  const pending = getPending(userJid);
  if (!pending) {
    return 'No tenés ninguna búsqueda pendiente para cancelar.';
  }

  deletePending(userJid);
  return 'Búsqueda cancelada. Cuando quieras, arrancá de nuevo con /peli o /serie.';
}

module.exports = {
  handleRepeat,
  handleMore,
  handleCancel,
};
