const REFRESH_DEBOUNCE_MS = 180
const CHANGE_MARK_MS = 9000
const STREAM_RETRY_MS = 2500

const state = {
  config: null,
  workflow: null,
  workerLog: null,
  workerLogError: null,
  tickHistory: null,
  tickHistoryError: null,
  selectedWorkerId: null,
  selectedRunId: null,
  error: null,
  refreshing: false,
  streamStatus: 'connecting',
  lastEventAt: null,
  eventSource: null,
  refreshTimer: null,
  reconnectTimer: null,
  changeMarks: {
    runs: new Map(),
    workers: new Map(),
    requests: new Map(),
    events: new Map(),
  },
}

const el = {
  banner: document.getElementById('banner'),
  generatedAt: document.getElementById('generated-at'),
  sourceUrl: document.getElementById('source-url'),
  routeLabel: document.getElementById('route-label'),
  streamStatus: document.getElementById('stream-status'),
  streamLastEvent: document.getElementById('stream-last-event'),
  statsGrid: document.getElementById('stats-grid'),
  navLinks: document.getElementById('nav-links'),
  sidebarSummary: document.getElementById('sidebar-summary'),
  viewShell: document.getElementById('view-shell'),
  refreshButton: document.getElementById('refresh-button'),
}

const NAV_ITEMS = [
  { key: 'overview', label: 'Overview', hash: '#/' },
  { key: 'workers', label: 'Workers', hash: '#/workers' },
  { key: 'runs', label: 'Runs', hash: '#/runs' },
  { key: 'events', label: 'Events', hash: '#/events' },
]

const RUN_PHASE_LABELS = {
  starting: 'Opening a new orchestrator phase',
  planning: 'Planner or orchestrator is shaping the next handoff',
  waiting_on_workers: 'Specialist workers are currently expected to make progress',
  stalled: 'A worker or run needs intervention before the loop can continue',
  completed: 'The orchestrator marked the run complete',
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => {
    switch (char) {
      case '&':
        return '&amp;'
      case '<':
        return '&lt;'
      case '>':
        return '&gt;'
      case '"':
        return '&quot;'
      default:
        return '&#39;'
    }
  })
}

function formatTimestamp(value) {
  return value ? new Date(value).toLocaleString() : 'Unknown'
}

function formatRelativeTime(value) {
  if (!value) return 'No events yet'
  const deltaMs = Date.now() - new Date(value).getTime()
  if (!Number.isFinite(deltaMs) || deltaMs < 0) return formatTimestamp(value)
  if (deltaMs < 1000) return 'just now'
  if (deltaMs < 60_000) return `${Math.round(deltaMs / 1000)}s ago`
  if (deltaMs < 3_600_000) return `${Math.round(deltaMs / 60_000)}m ago`
  return formatTimestamp(value)
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return 'Unknown'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function setBanner(message, kind = 'warning') {
  if (!message) {
    el.banner.className = 'banner hidden'
    el.banner.textContent = ''
    return
  }

  el.banner.className = `banner ${kind}`
  el.banner.textContent = message
}

function itemCard(inner, selectedOrOptions = false) {
  const options =
    typeof selectedOrOptions === 'object'
      ? selectedOrOptions
      : {
          selected: Boolean(selectedOrOptions),
        }
  const classes = ['item-card']
  if (options.selected) classes.push('selected')
  if (options.changed) classes.push('changed')
  return `<div class="${classes.join(' ')}">${inner}</div>`
}

function chips(items) {
  return `<div class="chip-row">${items.filter(Boolean).join('')}</div>`
}

function chip(text, kind = '') {
  return `<span class="chip${kind ? ` ${kind}` : ''}">${escapeHtml(text)}</span>`
}

function empty(text) {
  return `<p class="empty">${escapeHtml(text)}</p>`
}

function panel(title, subtitle, body, extraClass = '') {
  return `
    <article class="panel ${extraClass}">
      <div class="panel-header">
        <div>
          <p class="panel-kicker">${escapeHtml(title)}</p>
          <h2>${escapeHtml(subtitle)}</h2>
        </div>
      </div>
      ${body}
    </article>
  `
}

function summarizeEvent(event) {
  const payload = event.payload ?? {}
  switch (event.type) {
    case 'worker.spawned':
      return `${payload.nickname ?? payload.role ?? 'worker'} spawned for ${payload.runId ?? 'unknown run'}`
    case 'worker.stopped':
      return `${payload.nickname ?? payload.role ?? 'worker'} stopped`
    case 'spawn_request.created':
      return `${payload.requestedRole ?? 'worker'} requested for ${payload.scope ?? 'unknown scope'}`
    case 'spawn_request.fulfilled':
      return `Spawn request fulfilled by ${payload.fulfilledBy ?? 'unknown owner'}`
    case 'run.status':
      return `${payload.phase ?? 'phase'} for ${payload.runId ?? 'unknown run'}`
    default:
      return 'Workflow event'
  }
}

function runPhaseDescription(phase) {
  return RUN_PHASE_LABELS[phase] ?? 'Workflow phase'
}

async function fetchJson(url) {
  const response = await fetch(url, { headers: { Accept: 'application/json' } })
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`)
  }
  return response.json()
}

function apiUrl(path) {
  return `${state.config.workflowHttpUrl}${path.startsWith('/') ? path : `/${path}`}`
}

function currentRoute() {
  const hash = window.location.hash.replace(/^#/, '') || '/'
  const parts = hash.split('/').filter(Boolean)
  if (parts.length === 0) return { name: 'overview' }
  if (parts[0] === 'workers' && parts[1]) return { name: 'worker-detail', workerId: decodeURIComponent(parts[1]) }
  if (parts[0] === 'workers') return { name: 'workers' }
  if (parts[0] === 'runs' && parts[1] && parts[2] === 'orchestrator') return { name: 'run-detail', runId: decodeURIComponent(parts[1]) }
  if (parts[0] === 'runs') return { name: 'runs' }
  if (parts[0] === 'events') return { name: 'events' }
  return { name: 'overview' }
}

function navigate(hash) {
  window.location.hash = hash
}

function normalizeWorkflow(workflow) {
  return {
    generatedAt: workflow.generatedAt ?? new Date().toISOString(),
    runStatuses: Array.isArray(workflow.runStatuses) ? workflow.runStatuses : [],
    workers: Array.isArray(workflow.workers) ? workflow.workers : [],
    openSpawnRequests: Array.isArray(workflow.openSpawnRequests)
      ? workflow.openSpawnRequests.map((request) => ({
          ...request,
          tags: Array.isArray(request.tags) ? request.tags : [],
        }))
      : [],
    recentEvents: Array.isArray(workflow.recentEvents) ? workflow.recentEvents : [],
  }
}

function stableSignature(value) {
  return JSON.stringify(value ?? null)
}

function markCollectionChange(kind, previousItems, nextItems, keyField) {
  const previousMap = new Map(previousItems.map((item) => [item[keyField], stableSignature(item)]))
  const nextMap = new Map(nextItems.map((item) => [item[keyField], stableSignature(item)]))
  const marks = new Map(state.changeMarks[kind])
  const now = Date.now()

  for (const [id, signature] of nextMap.entries()) {
    if (previousMap.get(id) !== signature) {
      marks.set(id, now + CHANGE_MARK_MS)
    }
  }

  for (const id of marks.keys()) {
    const expiresAt = marks.get(id)
    if (!nextMap.has(id) || !expiresAt || expiresAt <= now) {
      marks.delete(id)
    }
  }

  state.changeMarks[kind] = marks
}

function applyWorkflowSnapshot(nextWorkflow) {
  const previous = state.workflow
  const normalized = normalizeWorkflow(nextWorkflow)
  if (previous) {
    markCollectionChange('runs', previous.runStatuses, normalized.runStatuses, 'runId')
    markCollectionChange('workers', previous.workers, normalized.workers, 'workerId')
    markCollectionChange('requests', previous.openSpawnRequests, normalized.openSpawnRequests, 'requestId')
    markCollectionChange('events', previous.recentEvents, normalized.recentEvents, 'eventId')
  }
  state.workflow = normalized

  if (!state.selectedWorkerId && normalized.workers[0]) {
    state.selectedWorkerId = normalized.workers[0].workerId
  }
  if (!state.selectedRunId && normalized.runStatuses[0]) {
    state.selectedRunId = normalized.runStatuses[0].runId
  }
}

function isChanged(kind, id) {
  if (!id) return false
  const expiresAt = state.changeMarks[kind].get(id)
  if (!expiresAt) return false
  if (expiresAt <= Date.now()) {
    state.changeMarks[kind].delete(id)
    return false
  }
  return true
}

function updateStreamBadge() {
  if (!el.streamStatus || !el.streamLastEvent) return
  const label =
    state.streamStatus === 'live'
      ? 'Live'
      : state.streamStatus === 'reconnecting'
        ? 'Reconnecting'
        : state.streamStatus === 'error'
          ? 'Stream error'
          : 'Connecting'
  el.streamStatus.textContent = label
  el.streamStatus.className = `meta-status ${state.streamStatus}`
  el.streamLastEvent.textContent = state.lastEventAt ? `Last event ${formatRelativeTime(state.lastEventAt)}` : 'No events yet'
}

function mergeRecentEvent(event) {
  if (!state.workflow || !event?.eventId) return
  const nextEvents = [event, ...state.workflow.recentEvents.filter((entry) => entry.eventId !== event.eventId)].slice(0, 25)
  applyWorkflowSnapshot({
    ...state.workflow,
    recentEvents: nextEvents,
    generatedAt: new Date().toISOString(),
  })
}

function scheduleRefresh(reason = 'poll') {
  if (state.refreshTimer) return
  state.refreshTimer = window.setTimeout(() => {
    state.refreshTimer = null
    refreshAll({ reason }).catch((error) => {
      state.error = error instanceof Error ? error.message : String(error)
      render()
    })
  }, reason === 'stream' ? REFRESH_DEBOUNCE_MS : 0)
}

function closeEventStream() {
  if (state.eventSource) {
    state.eventSource.close()
    state.eventSource = null
  }
}

function scheduleStreamReconnect() {
  if (state.reconnectTimer) return
  state.reconnectTimer = window.setTimeout(() => {
    state.reconnectTimer = null
    connectEventStream()
  }, STREAM_RETRY_MS)
}

function handleStreamEvent(event) {
  try {
    const parsed = JSON.parse(event.data)
    state.lastEventAt = parsed.at ?? new Date().toISOString()
    state.streamStatus = 'live'
    mergeRecentEvent(parsed)
    render()
    scheduleRefresh('stream')
  } catch (error) {
    state.streamStatus = 'error'
    state.error = error instanceof Error ? error.message : String(error)
    render()
  }
}

function connectEventStream() {
  if (!state.config?.workflowHttpUrl) return
  closeEventStream()
  state.streamStatus = 'connecting'
  updateStreamBadge()

  const source = new EventSource(apiUrl('/events'))
  source.onopen = () => {
    state.streamStatus = 'live'
    updateStreamBadge()
    render()
  }
  source.onmessage = handleStreamEvent
  source.onerror = () => {
    state.streamStatus = state.workflow ? 'reconnecting' : 'error'
    updateStreamBadge()
    closeEventStream()
    scheduleStreamReconnect()
    render()
  }

  state.eventSource = source
}

async function loadConfig() {
  state.config = await fetchJson('/config.json')
  el.sourceUrl.textContent = state.config.workflowHttpUrl
}

async function loadWorkflowState() {
  const workflow = await fetchJson(apiUrl('/state'))
  applyWorkflowSnapshot(workflow)
}

async function loadWorkerLog() {
  if (!state.selectedWorkerId) {
    state.workerLog = null
    state.workerLogError = null
    return
  }

  try {
    state.workerLog = await fetchJson(apiUrl(`/workers/${encodeURIComponent(state.selectedWorkerId)}/log?full=1`))
    state.workerLogError = null
  } catch (error) {
    state.workerLogError = error instanceof Error ? error.message : String(error)
    state.workerLog = null
  }
}

async function loadTickHistory() {
  if (!state.selectedRunId) {
    state.tickHistory = null
    state.tickHistoryError = null
    return
  }

  try {
    state.tickHistory = await fetchJson(apiUrl(`/runs/${encodeURIComponent(state.selectedRunId)}/orchestrator-ticks`))
    state.tickHistoryError = null
  } catch (error) {
    state.tickHistoryError = error instanceof Error ? error.message : String(error)
    state.tickHistory = null
  }
}

function syncSelectionsToRoute() {
  const route = currentRoute()
  if (route.name === 'worker-detail' && route.workerId) state.selectedWorkerId = route.workerId
  if (route.name === 'run-detail' && route.runId) state.selectedRunId = route.runId
}

function renderStats() {
  const workflow = state.workflow
  if (!workflow) {
    el.statsGrid.innerHTML = ''
    return
  }

  const runningWorkers = workflow.workers.filter((worker) => worker.status === 'running').length
  const blockingRequests = workflow.openSpawnRequests.filter((request) => request.priority === 'blocking').length
  const statCards = [
    ['Runs', workflow.runStatuses.length, 'Tracked run status records'],
    ['Workers', workflow.workers.length, `${runningWorkers} currently running`],
    ['Spawn Requests', workflow.openSpawnRequests.length, `${blockingRequests} blocking`],
    ['Stream', state.streamStatus === 'live' ? 'Live' : 'Degraded', state.lastEventAt ? `Last event ${formatRelativeTime(state.lastEventAt)}` : 'Waiting for /events'],
  ]

  el.statsGrid.innerHTML = statCards
    .map(
      ([label, value, caption]) => `
        <div class="stat-card">
          <p class="panel-kicker">${label}</p>
          <div class="stat-value">${escapeHtml(value)}</div>
          <p class="body-copy">${escapeHtml(caption)}</p>
        </div>
      `
    )
    .join('')
}

function renderNav() {
  const route = currentRoute()
  const counts = {
    overview: state.workflow ? state.workflow.runStatuses.length + state.workflow.workers.length : 0,
    workers: state.workflow?.workers.length ?? 0,
    runs: state.workflow?.runStatuses.length ?? 0,
    events: state.workflow?.recentEvents.length ?? 0,
  }

  el.navLinks.innerHTML = NAV_ITEMS.map((item) => {
    const active =
      route.name === item.key ||
      (item.key === 'workers' && route.name === 'worker-detail') ||
      (item.key === 'runs' && route.name === 'run-detail')
    return `
      <a class="nav-link${active ? ' active' : ''}" href="${item.hash}">
        <span>${item.label}</span>
        <span class="nav-count">${counts[item.key] ?? 0}</span>
      </a>
    `
  }).join('')

  const workflow = state.workflow
  if (!workflow) {
    el.sidebarSummary.innerHTML = empty('Waiting for the first workflow payload.')
    return
  }

  const activeRun = workflow.runStatuses[0]
  const activeWorker = workflow.workers.find((worker) => worker.workerId === state.selectedWorkerId) ?? workflow.workers[0]
  const leadRequest = workflow.openSpawnRequests[0]
  const streamChipKind = state.streamStatus === 'live' ? 'success' : state.streamStatus === 'reconnecting' ? 'warn' : 'danger'
  el.sidebarSummary.innerHTML = [
    activeRun
      ? itemCard(
          `
          <div class="item-title">
            <span>Lead run</span>
            ${chip(activeRun.phase, 'accent')}
          </div>
          <p class="item-description mono">${escapeHtml(activeRun.runId)}</p>
          <p class="body-copy">${escapeHtml(activeRun.summary)}</p>
        `,
          { changed: isChanged('runs', activeRun.runId) }
        )
      : '',
    activeWorker
      ? itemCard(
          `
          <div class="item-title">
            <span>Selected worker</span>
            ${chip(activeWorker.role, 'success')}
          </div>
          <p class="item-description">${escapeHtml(activeWorker.nickname)}</p>
          <p class="body-copy">${escapeHtml(activeWorker.reason)}</p>
        `,
          { changed: isChanged('workers', activeWorker.workerId) }
        )
      : itemCard(`<p class="body-copy">No worker selected yet.</p>`),
    leadRequest
      ? itemCard(
          `
          <div class="item-title">
            <span>Next spawn</span>
            ${chip(leadRequest.requestedRole, 'accent')}
          </div>
          <p class="item-description">${escapeHtml(leadRequest.text)}</p>
          <div class="item-meta">
            <span>${escapeHtml(leadRequest.askedBy)}</span>
            <span>${escapeHtml(formatTimestamp(leadRequest.askedAt))}</span>
          </div>
        `,
          { changed: isChanged('requests', leadRequest.requestId) }
        )
      : itemCard(`<p class="body-copy">No open spawn requests.</p>`),
    itemCard(`
      <div class="item-title">
        <span>Live stream</span>
        ${chip(state.streamStatus, streamChipKind)}
      </div>
      <div class="item-meta stacked">
        <span><span class="mono">/events</span> pushes the recent workflow bus feed</span>
        <span>${escapeHtml(state.lastEventAt ? `Last event ${formatRelativeTime(state.lastEventAt)}` : 'No event received yet')}</span>
        <span>${escapeHtml(state.refreshing ? 'Background refresh in flight' : 'Snapshot refresh idle')}</span>
      </div>
    `),
  ].join('')
}

function renderSpawnRequestsPanel(requests, subtitle) {
  return panel(
    'Spawn Requests',
    subtitle,
    requests.length
      ? `<div class="stack">${requests
          .map((request) =>
            itemCard(
              `
              <div class="item-title">
                <span>${escapeHtml(request.requestedRole)}</span>
                ${chips([
                  chip(request.priority, request.priority === 'blocking' ? 'warn' : ''),
                  chip(request.scope),
                ])}
              </div>
              <p class="item-description">${escapeHtml(request.text)}</p>
              ${request.context ? `<p class="body-copy">${escapeHtml(request.context)}</p>` : ''}
              <div class="item-meta">
                <span>${escapeHtml(request.askedBy)}</span>
                <span>${escapeHtml(formatTimestamp(request.askedAt))}</span>
              </div>
            `,
              { changed: isChanged('requests', request.requestId) }
            )
          )
          .join('')}</div>`
      : empty('No open spawn requests.')
  )
}

function renderOverviewView(workflow) {
  const runs = workflow.runStatuses.slice(0, 4)
  const workers = workflow.workers.slice(0, 6)
  const requests = workflow.openSpawnRequests.slice(0, 4)
  const events = workflow.recentEvents.slice(0, 6)

  const runsBody = runs.length
    ? runs
        .map((run) =>
          itemCard(
            `
            <button type="button" class="plain-button" data-run-link="${escapeHtml(run.runId)}">
              <div class="item-title">
                <span class="mono">${escapeHtml(run.runId)}</span>
                ${chip(run.phase, 'accent')}
              </div>
              <p class="item-description">${escapeHtml(run.summary)}</p>
              <div class="item-meta">
                <span>${escapeHtml(run.owner)}</span>
                <span>${escapeHtml(formatTimestamp(run.at))}</span>
              </div>
            </button>
          `,
            { changed: isChanged('runs', run.runId) }
          )
        )
        .join('')
    : empty('No runs recorded.')

  const workersBody = workers.length
    ? workers
        .map((worker) =>
          itemCard(
            `
            <button type="button" class="plain-button" data-worker-link="${escapeHtml(worker.workerId)}">
              <div class="item-title">
                <span>${escapeHtml(worker.nickname)}</span>
                ${chips([chip(worker.role, 'success'), chip(worker.status)])}
              </div>
              <p class="item-description">${escapeHtml(worker.reason)}</p>
              <div class="item-meta">
                <span class="mono">${escapeHtml(worker.scope)}</span>
                <span>pid ${escapeHtml(worker.pid)}</span>
              </div>
            </button>
          `,
            { changed: isChanged('workers', worker.workerId) }
          )
        )
        .join('')
    : empty('No workers active or recorded.')

  const eventsBody = events.length
    ? events
        .map((event) =>
          itemCard(
            `
            <div class="item-title">
              <span class="mono">${escapeHtml(event.type)}</span>
              ${chip(formatRelativeTime(event.at), 'accent')}
            </div>
            <p class="body-copy">${escapeHtml(summarizeEvent(event))}</p>
            <pre class="code-block compact">${escapeHtml(JSON.stringify(event.payload, null, 2))}</pre>
          `,
            { changed: isChanged('events', event.eventId) }
          )
        )
        .join('')
    : empty('No recent events.')

  const leadRun = workflow.runStatuses[0] ?? null
  const runPulseBody = leadRun
    ? `
      <div class="stack">
        ${itemCard(
          `
          <div class="item-title">
            <span class="mono">${escapeHtml(leadRun.runId)}</span>
            ${chip(leadRun.phase, 'accent')}
          </div>
          <p class="item-description">${escapeHtml(leadRun.summary)}</p>
          <p class="body-copy">${escapeHtml(runPhaseDescription(leadRun.phase))}</p>
          <div class="item-meta">
            <span>${escapeHtml(leadRun.owner)}</span>
            <span>${escapeHtml(formatTimestamp(leadRun.at))}</span>
          </div>
        `,
          { changed: isChanged('runs', leadRun.runId) }
        )}
      </div>
    `
    : empty('No lead run yet.')

  return `
    <section class="route-header panel">
      <p class="panel-kicker">Overview</p>
      <h2>Operations snapshot</h2>
      <p class="body-copy">Questions are gone. The coordination surface is now an explicit spawn-request queue plus live worker and run state.</p>
    </section>
    <section class="two-column">
      ${panel('Runs', 'Lead run ledger', `<div class="stack">${runsBody}</div>`)}
      ${panel('Workers', 'Hot worker surface', `<div class="stack">${workersBody}</div>`)}
    </section>
    <section class="three-column">
      ${panel('Run Pulse', 'Current orchestration posture', runPulseBody)}
      ${renderSpawnRequestsPanel(requests, 'Open worker queue')}
      ${panel('Events', 'Recent stream', `<div class="stack">${eventsBody}</div>`)}
    </section>
  `
}

function renderWorkersView(workflow) {
  const workers = workflow.workers
  const selectedWorker = workers.find((worker) => worker.workerId === state.selectedWorkerId) ?? null
  const listBody = workers.length
    ? workers
        .map((worker) =>
          itemCard(
            `
            <button type="button" class="plain-button" data-worker-link="${escapeHtml(worker.workerId)}">
              <div class="item-title">
                <span>${escapeHtml(worker.nickname)}</span>
                ${chips([chip(worker.role, 'success'), chip(worker.status)])}
              </div>
              <p class="item-description">${escapeHtml(worker.reason)}</p>
              <div class="item-meta">
                <span class="mono">${escapeHtml(worker.scope)}</span>
                <span>${escapeHtml(formatTimestamp(worker.startedAt))}</span>
              </div>
            </button>
          `,
            { selected: state.selectedWorkerId === worker.workerId, changed: isChanged('workers', worker.workerId) }
          )
        )
        .join('')
    : empty('No workers active or recorded.')

  const detailBody = selectedWorker ? renderWorkerDetailBody(selectedWorker) : empty('Select a worker to inspect its detail.')
  const relatedRequests = selectedWorker
    ? workflow.openSpawnRequests.filter((request) => request.requestedRole === selectedWorker.role).slice(0, 4)
    : []

  return `
    <section class="route-header panel">
      <p class="panel-kicker">Workers</p>
      <h2>Worker ledger</h2>
      <p class="body-copy">Inspect active processes and keep a selected worker detail page open while the spawn queue and event stream refresh in place.</p>
    </section>
    <section class="two-column">
      ${panel('Workers', 'Managed process ledger', `<div class="stack">${listBody}</div>`)}
      ${panel('Worker Detail', selectedWorker ? selectedWorker.nickname : 'Select a worker', detailBody, 'panel-wide')}
    </section>
    ${renderSpawnRequestsPanel(relatedRequests, selectedWorker ? `Queue entries for ${selectedWorker.role}` : 'Select a worker')}
  `
}

function renderWorkerDetailBody(worker) {
  if (state.workerLogError) return `<div class="banner error">${escapeHtml(state.workerLogError)}</div>`
  if (!state.workerLog) return '<p class="body-copy">Loading worker log…</p>'

  return `
    <div class="section-split">
      ${chips([
        chip(worker.role, 'success'),
        chip(worker.status),
        chip(`pid ${worker.pid}`),
        state.workerLog.logTruncated ? chip(`truncated ${formatBytes(state.workerLog.logTotalBytes)}`, 'warn') : '',
      ])}
      <div class="divider"></div>
      <div class="detail-grid">
        <div><p class="panel-kicker">Reason</p><p class="body-copy">${escapeHtml(worker.reason)}</p></div>
        <div><p class="panel-kicker">Scope</p><p class="body-copy mono">${escapeHtml(worker.scope)}</p></div>
        <div><p class="panel-kicker">Command</p><p class="body-copy mono">${escapeHtml([worker.command, ...(Array.isArray(worker.args) ? worker.args : [])].join(' '))}</p></div>
        <div><p class="panel-kicker">Started</p><p class="body-copy">${escapeHtml(formatTimestamp(worker.startedAt))}</p></div>
        <div><p class="panel-kicker">Prompt path</p><p class="body-copy mono">${escapeHtml(worker.promptPath)}</p></div>
        <div><p class="panel-kicker">Last message path</p><p class="body-copy mono">${escapeHtml(worker.lastMessagePath)}</p></div>
      </div>
      ${state.workerLog.lastMessage ? `<div><p class="panel-kicker">Latest message</p><pre class="code-block">${escapeHtml(state.workerLog.lastMessage.trimEnd())}</pre></div>` : ''}
      <div><p class="panel-kicker">Full log</p><pre class="code-block tall">${escapeHtml(state.workerLog.logContent ?? state.workerLog.tail ?? 'No log content available.')}</pre></div>
    </div>
  `
}

function renderRunsView(workflow) {
  const runs = workflow.runStatuses
  const selectedRun = runs.find((run) => run.runId === state.selectedRunId) ?? null
  const listBody = runs.length
    ? runs
        .map((run) =>
          itemCard(
            `
            <button type="button" class="plain-button" data-run-link="${escapeHtml(run.runId)}">
              <div class="item-title">
                <span class="mono">${escapeHtml(run.runId)}</span>
                ${chip(run.phase, 'accent')}
              </div>
              <p class="item-description">${escapeHtml(run.summary)}</p>
              <div class="item-meta">
                <span>${escapeHtml(run.owner)}</span>
                <span>${escapeHtml(formatTimestamp(run.at))}</span>
              </div>
            </button>
          `,
            { selected: state.selectedRunId === run.runId, changed: isChanged('runs', run.runId) }
          )
        )
        .join('')
    : empty('No runs recorded.')

  const detailBody = selectedRun ? renderRunDetailBody(selectedRun) : empty('Select a run to inspect its orchestrator ticks.')
  const runWorkers = selectedRun ? workflow.workers.filter((worker) => worker.runId === selectedRun.runId) : []
  const runRequests = selectedRun ? workflow.openSpawnRequests.filter((request) => request.runId === selectedRun.runId) : []

  return `
    <section class="route-header panel">
      <p class="panel-kicker">Runs</p>
      <h2>Run ledger</h2>
      <p class="body-copy">Track current phases, then drill into the orchestrator tick history, linked workers, and open spawn queue for the same run.</p>
    </section>
    <section class="two-column">
      ${panel('Runs', 'Known runs', `<div class="stack">${listBody}</div>`)}
      ${panel('Orchestrator', selectedRun ? `${selectedRun.runId} ticks` : 'Select a run', detailBody, 'panel-wide')}
    </section>
    <section class="two-column">
      ${panel(
        'Run Workers',
        selectedRun ? `${selectedRun.runId} worker set` : 'Select a run',
        runWorkers.length
          ? `<div class="stack">${runWorkers
              .map((worker) =>
                itemCard(
                  `
                  <div class="item-title">
                    <span>${escapeHtml(worker.nickname)}</span>
                    ${chips([chip(worker.role, 'success'), chip(worker.status)])}
                  </div>
                  <p class="item-description">${escapeHtml(worker.reason)}</p>
                  <div class="item-meta">
                    <span class="mono">${escapeHtml(worker.scope)}</span>
                    <span>pid ${escapeHtml(worker.pid)}</span>
                  </div>
                `,
                  { changed: isChanged('workers', worker.workerId) }
                )
              )
              .join('')}</div>`
          : empty('No workers currently recorded for this run.')
      )}
      ${renderSpawnRequestsPanel(runRequests, selectedRun ? `${selectedRun.runId} open queue` : 'Select a run')}
    </section>
  `
}

function renderRunDetailBody(run) {
  if (state.tickHistoryError) return `<div class="banner error">${escapeHtml(state.tickHistoryError)}</div>`
  const entries = state.tickHistory?.entries ?? []
  if (entries.length === 0) return empty('No orchestrator ticks recorded for this run yet.')

  return `
    <div class="stack">
      <div class="detail-grid">
        <div><p class="panel-kicker">Owner</p><p class="body-copy">${escapeHtml(run.owner)}</p></div>
        <div><p class="panel-kicker">Phase</p><p class="body-copy">${escapeHtml(run.phase)}</p></div>
        <div><p class="panel-kicker">Updated</p><p class="body-copy">${escapeHtml(formatTimestamp(run.at))}</p></div>
      </div>
      ${entries
        .map((entry) =>
          itemCard(`
            <div class="item-title">
              <span>Tick ${escapeHtml(entry.tickCount)}</span>
              ${chip(entry.phase, 'accent')}
            </div>
            ${entry.lastPlanSummary ? `<p class="item-description">${escapeHtml(entry.lastPlanSummary)}</p>` : ''}
            ${entry.lastStallFinding ? `<div class="banner warning">${escapeHtml(entry.lastStallFinding)}</div>` : ''}
            <div class="item-meta">
              <span>${escapeHtml(formatTimestamp(entry.lastUpdatedAt))}</span>
              <span>${escapeHtml(entry.pendingSpawnKeys.length)} pending spawn keys</span>
            </div>
          `)
        )
        .join('')}
    </div>
  `
}

function renderEventsView(workflow) {
  const events = workflow.recentEvents
  const grouped = new Map()
  for (const event of events) {
    grouped.set(event.type, (grouped.get(event.type) ?? 0) + 1)
  }

  const summaryBody = [...grouped.entries()].length
    ? [...grouped.entries()]
        .map(([type, count]) =>
          itemCard(`
            <div class="item-title">
              <span class="mono">${escapeHtml(type)}</span>
              ${chip(`${count}x`, 'accent')}
            </div>
          `)
        )
        .join('')
    : empty('No recent events.')

  const eventsBody = events.length
    ? events
        .map((event) =>
          itemCard(
            `
            <div class="item-title">
              <span class="mono">${escapeHtml(event.type)}</span>
              ${chips([chip(formatRelativeTime(event.at), 'accent'), chip(event.eventId.slice(0, 8))])}
            </div>
            <p class="body-copy">${escapeHtml(summarizeEvent(event))}</p>
            <pre class="code-block compact">${escapeHtml(JSON.stringify(event.payload, null, 2))}</pre>
          `,
            { changed: isChanged('events', event.eventId) }
          )
        )
        .join('')
    : empty('No recent events.')

  return `
    <section class="route-header panel">
      <p class="panel-kicker">Events</p>
      <h2>Activity stream</h2>
      <p class="body-copy">The feed now reflects run, worker, and spawn-request lifecycle without the old question layer.</p>
    </section>
    <section class="two-column">
      ${panel('Summary', 'Recent event mix', `<div class="stack">${summaryBody}</div>`)}
      ${panel('Recent Events', 'Raw event payloads', `<div class="stack">${eventsBody}</div>`, 'panel-wide')}
    </section>
  `
}

function renderRoute() {
  const workflow = state.workflow
  if (!workflow) {
    el.viewShell.innerHTML = panel('Loading', 'Waiting for workflow state', `<p class="body-copy">The dashboard will populate after the first /state response.</p>`)
    el.routeLabel.textContent = 'Loading'
    return
  }

  const route = currentRoute()
  let html = ''
  switch (route.name) {
    case 'workers':
    case 'worker-detail':
      el.routeLabel.textContent = route.name === 'worker-detail' ? `Workers / ${state.selectedWorkerId ?? ''}` : 'Workers'
      html = renderWorkersView(workflow)
      break
    case 'runs':
    case 'run-detail':
      el.routeLabel.textContent = route.name === 'run-detail' ? `Runs / ${state.selectedRunId ?? ''}` : 'Runs'
      html = renderRunsView(workflow)
      break
    case 'events':
      el.routeLabel.textContent = 'Events'
      html = renderEventsView(workflow)
      break
    default:
      el.routeLabel.textContent = 'Overview'
      html = renderOverviewView(workflow)
      break
  }

  el.viewShell.innerHTML = html

  el.viewShell.querySelectorAll('[data-worker-link]').forEach((button) => {
    button.addEventListener('click', async () => {
      const workerId = button.getAttribute('data-worker-link')
      if (!workerId) return
      state.selectedWorkerId = workerId
      await loadWorkerLog()
      navigate(`#/workers/${encodeURIComponent(workerId)}`)
    })
  })

  el.viewShell.querySelectorAll('[data-run-link]').forEach((button) => {
    button.addEventListener('click', async () => {
      const runId = button.getAttribute('data-run-link')
      if (!runId) return
      state.selectedRunId = runId
      await loadTickHistory()
      navigate(`#/runs/${encodeURIComponent(runId)}/orchestrator`)
    })
  })
}

function render() {
  updateStreamBadge()

  if (!state.workflow) {
    setBanner(state.error ?? 'Loading workflow state…', state.error ? 'error' : 'warning')
    el.routeLabel.textContent = 'Loading'
    renderStats()
    renderNav()
    renderRoute()
    return
  }

  el.generatedAt.textContent = formatTimestamp(state.workflow.generatedAt)
  setBanner(state.error, 'error')
  renderStats()
  renderNav()
  renderRoute()
}

async function refreshAll(options = {}) {
  const { reason = 'poll' } = options
  state.refreshing = true
  syncSelectionsToRoute()
  try {
    await loadWorkflowState()
    await Promise.all([loadWorkerLog(), loadTickHistory()])
    if (reason !== 'stream') {
      state.error = null
    }
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error)
  }
  state.refreshing = false
  render()
}

async function bootstrap() {
  el.refreshButton.addEventListener('click', () => {
    refreshAll({ reason: 'manual' }).catch((error) => {
      state.error = error instanceof Error ? error.message : String(error)
      render()
    })
  })

  window.addEventListener('hashchange', () => {
    syncSelectionsToRoute()
    Promise.all([loadWorkerLog(), loadTickHistory()])
      .catch((error) => {
        state.error = error instanceof Error ? error.message : String(error)
      })
      .finally(() => render())
  })

  window.addEventListener('beforeunload', () => {
    closeEventStream()
  })

  try {
    await loadConfig()
    await refreshAll({ reason: 'bootstrap' })
    connectEventStream()
    window.setInterval(() => {
      scheduleRefresh('poll')
    }, state.config.refreshMs ?? 2500)
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error)
    render()
  }
}

bootstrap()
