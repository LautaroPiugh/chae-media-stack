const DATA_URL = 'api/stack-data.php';

function copyText(text) {
  navigator.clipboard.writeText(text).then(() => {
    const banner = document.getElementById('copyBanner');
    banner.textContent = `Copiado: ${text}`;
    banner.classList.add('show');
    window.setTimeout(() => banner.classList.remove('show'), 1800);
  });
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 100 || index === 0 ? 0 : 1)} ${units[index]}`;
}

function formatDate(value) {
  if (!value) return 'Sin datos';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString('es-AR');
}

function getStatusClass(service) {
  if (!service.up) return 'down';
  if (service.health && service.health !== 'none' && service.health !== 'healthy') return 'warn';
  return 'up';
}

function renderSummary(data) {
  const metrics = [
    {
      label: 'Servicios arriba',
      value: `${data.summary.servicesUp}/${data.summary.servicesTotal}`,
      badge: `${data.summary.runningContainers}/${data.summary.totalContainers} contenedores activos`,
    },
    {
      label: 'Espacio libre media',
      value: formatBytes(data.summary.mediaFreeBytes),
      badge: data.summary.mediaUsage,
    },
    {
      label: 'Tdarr',
      value: data.tdarr.ready ? 'Listo' : 'Pendiente',
      badge: `${data.tdarr.serverStatus} / ${data.tdarr.nodeStatus}`,
    },
    {
      label: 'Ultimo refresh',
      value: data.updateState.statusLabel,
      badge: formatDate(data.generatedAt),
    },
  ];

  document.getElementById('hostName').textContent = data.host.name;
  document.getElementById('generatedAt').textContent = `Actualizado: ${formatDate(data.generatedAt)}`;
  document.getElementById('heroSummary').textContent = `${data.host.ip} · ${data.summary.servicesUp} servicios publicados · ${formatBytes(data.summary.mediaFreeBytes)} libres en la libreria principal.`;
  document.getElementById('servicesCaption').textContent = `${data.summary.servicesUp} arriba / ${data.summary.servicesTotal} esperados`;
  document.getElementById('summaryGrid').innerHTML = metrics.map((metric) => `
    <article class="metric-card">
      <div class="metric-value">${metric.value}</div>
      <div class="metric-label">${metric.label}</div>
      <div class="metric-badge">${metric.badge}</div>
    </article>
  `).join('');
}

function renderServices(data) {
  const container = document.getElementById('servicesGrid');
  container.innerHTML = data.services.map((service) => `
    <a class="card" href="${service.url}" target="_blank" rel="noopener noreferrer">
      <div class="service-top">
        <div>
          <div class="service-title">${service.name}</div>
          <div class="service-desc">${service.description}</div>
        </div>
        <span class="status-pill ${getStatusClass(service)}">${service.statusLabel}</span>
      </div>
      <div class="service-bottom">
        <span class="service-meta">${service.container}</span>
        <span class="service-meta">${service.portLabel}</span>
      </div>
    </a>
  `).join('');
}

function renderStorage(data) {
  const container = document.getElementById('storageGrid');
  container.innerHTML = data.storage.map((item) => `
    <article class="storage-card">
      <div class="row">
        <div>
          <div class="storage-label">${item.label}</div>
          <div class="storage-value">${formatBytes(item.availableBytes)} libres</div>
        </div>
        <span class="path-chip">${item.usePercent}%</span>
      </div>
      <div class="progress-track"><div class="progress-bar" style="width:${item.usePercent}%"></div></div>
      <div class="storage-meta">${item.path}</div>
      <div class="storage-meta">Usado ${formatBytes(item.usedBytes)} de ${formatBytes(item.sizeBytes)}</div>
    </article>
  `).join('');
}

function renderUpdate(data) {
  document.getElementById('updateCard').innerHTML = `
    <div class="info-grid">
      <div class="info-tile">
        <div class="info-label">Estado</div>
        <div class="info-value">${data.updateState.statusLabel}</div>
      </div>
      <div class="info-tile">
        <div class="info-label">Modo</div>
        <div class="info-value">${data.updateState.mode || 'manual'}</div>
      </div>
      <div class="info-tile">
        <div class="info-label">Ultima ejecucion</div>
        <div class="info-value">${formatDate(data.updateState.lastRunAt)}</div>
      </div>
      <div class="info-tile">
        <div class="info-label">Origen</div>
        <div class="info-value">${data.host.timezone}</div>
      </div>
    </div>
    <div class="inline-note">Este panel lee un cache generado desde el host para mostrar estado real de Docker y espacio en disco sin depender de datos estaticos.</div>
  `;
}

function renderTdarr(data) {
  document.getElementById('tdarrStatus').innerHTML = `
    <div class="info-grid">
      <div class="info-tile">
        <div class="info-label">UI</div>
        <div class="info-value"><a href="${data.tdarr.url}" target="_blank" rel="noopener noreferrer">${data.tdarr.url}</a></div>
      </div>
      <div class="info-tile">
        <div class="info-label">Server / Node</div>
        <div class="info-value">${data.tdarr.serverStatus} / ${data.tdarr.nodeStatus}</div>
      </div>
      <div class="info-tile">
        <div class="info-label">Cache transcode</div>
        <div class="info-value">${data.tdarr.cachePath}</div>
      </div>
      <div class="info-tile">
        <div class="info-label">GPU</div>
        <div class="info-value">${data.tdarr.gpuMode}</div>
      </div>
    </div>
    <div class="notes-stack">
      ${data.tdarr.notes.map((note) => `<div class="info-chip">${note}</div>`).join('')}
    </div>
  `;

  document.getElementById('tdarrWorkflow').innerHTML = `
    <div class="workflow-stack">
      ${data.tdarr.workflow.map((step, index) => `
        <div class="list-row">
          <div>
            <div class="list-label">Paso ${index + 1}</div>
            <div class="list-value">${step.title}</div>
          </div>
          <div class="inline-note">${step.detail}</div>
        </div>
      `).join('')}
    </div>
  `;

  document.getElementById('libraryList').innerHTML = `
    <div class="path-stack">
      ${data.tdarr.libraries.map((library) => `
        <div class="path-row">
          <div>
            <div class="list-label">${library.name}</div>
            <div class="list-value">${library.path}</div>
          </div>
          <span class="copyable" data-copy="${library.path}">Copiar</span>
        </div>
      `).join('')}
    </div>
  `;
}

function renderCommands(data) {
  document.getElementById('commandsList').innerHTML = data.commands.map((item) => `
    <div class="command-row">
      <div class="command-main">
        <div class="command-label">${item.label}</div>
        <div class="command-text copyable" data-copy="${item.command}">${item.command}</div>
        <div class="command-desc">${item.description}</div>
      </div>
    </div>
  `).join('');
}

function bindCopyActions() {
  document.querySelectorAll('[data-copy]').forEach((element) => {
    element.addEventListener('click', () => copyText(element.getAttribute('data-copy')));
  });
}

async function loadDashboard() {
  const button = document.getElementById('refreshButton');
  button.disabled = true;
  button.textContent = 'Actualizando...';

  try {
    const response = await fetch(`${DATA_URL}?t=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const data = await response.json();
    renderSummary(data);
    renderServices(data);
    renderStorage(data);
    renderUpdate(data);
    renderTdarr(data);
    renderCommands(data);
    bindCopyActions();
  } catch (error) {
    document.getElementById('heroSummary').textContent = `No se pudo leer el dashboard: ${error.message}`;
    document.getElementById('servicesGrid').innerHTML = '<div class="empty-state">Sin datos. Ejecuta el generador del dashboard o revisa api/stack-data.php.</div>';
  } finally {
    button.disabled = false;
    button.textContent = 'Actualizar';
  }
}

document.getElementById('refreshButton').addEventListener('click', loadDashboard);
loadDashboard();
