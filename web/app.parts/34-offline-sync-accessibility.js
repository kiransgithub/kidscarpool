import {
  createOfflineAction,
  enqueueOfflineAction,
  listOfflineActions,
  updateOfflineAction,
  removeOfflineAction,
  nextSyncBatch,
  cacheDriverSnapshot,
  loadDriverSnapshot,
  clearExpiredDriverSnapshots
} from './offline-queue.js'

state.offlineActions = []
let offlineSyncRunning = false

function ensureOfflineStatusUI() {
  if (!el('offlineStatusBar')) {
    el('connectionBanner')?.insertAdjacentHTML('afterend', `
      <section id="offlineStatusBar" class="offline-status hidden" role="status" aria-live="polite"></section>`)
  }
  if (!document.querySelector('.skip-link')) {
    document.body.insertAdjacentHTML('afterbegin', '<a class="skip-link" href="#mainContent">Skip to main content</a>')
  }
  el('mainContent')?.setAttribute('tabindex','-1')
  document.querySelectorAll('dialog').forEach(dialog => {
    dialog.setAttribute('aria-modal','true')
    if (!dialog.getAttribute('aria-label') && !dialog.getAttribute('aria-labelledby')) {
      const heading = dialog.querySelector('h1,h2')
      if (heading) {
        if (!heading.id) heading.id = `dialog-heading-${Math.random().toString(16).slice(2)}`
        dialog.setAttribute('aria-labelledby',heading.id)
      }
    }
  })
}

ensureOfflineStatusUI()

async function loadOfflineQueueState() {
  await clearExpiredDriverSnapshots()
  state.offlineActions = await listOfflineActions()
  renderOfflineStatus()
  renderOfflineQueuePanel()
}

function renderOfflineStatus() {
  ensureOfflineStatusUI()
  const bar = el('offlineStatusBar')
  if (!bar) return
  const pending = state.offlineActions.filter(action => ['pending','syncing'].includes(action.status)).length
  const failed = state.offlineActions.filter(action => action.status === 'failed').length
  const offline = !navigator.onLine

  bar.className = `offline-status ${offline ? 'offline' : failed ? 'failed' : pending ? 'pending' : 'hidden'}`
  if (offline) {
    bar.innerHTML = `<span aria-hidden="true">◌</span><strong>Offline</strong><span>${pending + failed ? `${pending + failed} ride change${pending + failed === 1 ? '' : 's'} waiting to sync` : 'Previously opened ride details are still available'}</span>`
  } else if (failed) {
    bar.innerHTML = `<span aria-hidden="true">!</span><strong>Some changes were not saved</strong><span>${failed} ride change${failed === 1 ? '' : 's'} could not sync</span><button data-action="retry-offline-sync" type="button">Review</button>`
  } else if (pending) {
    bar.innerHTML = `<span aria-hidden="true">↻</span><strong>Syncing</strong><span>${pending} saved action${pending === 1 ? '' : 's'} remaining</span>`
  }
}

const kcpOfflinePreviousRenderSettings = renderSettings
renderSettings = function () {
  kcpOfflinePreviousRenderSettings()
  renderOfflineQueuePanel()
}

function renderOfflineQueuePanel() {
  const settings = el('settingsView') || el('moreView')
  settings?.querySelector('[data-offline-queue-panel]')?.remove()
  const actions = state.offlineActions || []
  if (!actions.length) return

  settings?.insertAdjacentHTML('beforeend', `
    <section class="card offline-queue-panel" data-offline-queue-panel>
      <div class="group-card-head"><div><span class="eyebrow">WAITING TO SYNC</span><h2>Changes saved on this device</h2></div><span class="status-pill ${actions.some(action => action.status === 'failed') ? 'warning' : 'info'}">${actions.length}</span></div>
      <p class="meta">Changes are sent in order. If one cannot sync, later changes to the same ride will wait until you retry or remove it.</p>
      ${actions.map(action => `<article class="offline-action-row ${action.status}"><div><strong>${escapeHTML(humanize(action.action))}</strong><span>${formatDateTime(action.deviceTimestamp)} · ${escapeHTML(action.status)}</span>${action.lastError ? `<small>${escapeHTML(sanitizeUserMessage(action.lastError))}</small>` : ''}</div><div class="button-row">${action.status === 'failed' ? `<button class="action-button" data-action="retry-one-offline-action" data-offline-action-id="${action.id}" type="button">Retry</button>` : ''}<button class="action-button" data-action="discard-offline-action" data-offline-action-id="${action.id}" type="button">Remove change</button></div></article>`).join('')}
      <button class="primary-small" data-action="retry-offline-sync" type="button" ${navigator.onLine ? '' : 'disabled'}>Sync now</button>
    </section>`)
}

const kcpOfflinePreviousLoadDriverModeSnapshot = loadDriverModeSnapshot
loadDriverModeSnapshot = async function () {
  if (!navigator.onLine) {
    const cached = await loadDriverSnapshot(driverModeTripId)
    if (!cached) {
      el('driverModeContent').innerHTML = '<div class="driver-mode-empty"><h2>Ride details are not available offline</h2><p>Open this ride once while online before using the ride checklist offline.</p></div>'
      el('driverModeFooter').innerHTML = ''
      return
    }
    driverModeSnapshot = cached
    renderDriverMode()
    return
  }

  await kcpOfflinePreviousLoadDriverModeSnapshot()
  if (driverModeSnapshot?.trip?.id) {
    await cacheDriverSnapshot(driverModeSnapshot.trip.id,driverModeSnapshot)
  }
}

const kcpOfflinePreviousRenderDriverMode = renderDriverMode
renderDriverMode = function () {
  kcpOfflinePreviousRenderDriverMode()
  const content = el('driverModeContent')
  if (!content) return
  content.querySelector('[data-driver-offline-note]')?.remove()
  const queued = state.offlineActions.filter(action => action.tripId === driverModeTripId)
  if (!navigator.onLine || queued.length) {
    content.insertAdjacentHTML('afterbegin', `<div class="driver-offline-note" data-driver-offline-note><strong>${navigator.onLine ? 'Waiting to sync' : 'Offline mode'}</strong><span>${queued.length ? `${queued.length} action${queued.length === 1 ? '' : 's'} saved on this device.` : 'New actions will be saved on this device.'}</span></div>`)
  }
}

const kcpOfflinePreviousDriverFooterActions = driverFooterActions
driverFooterActions = function (trip, options) {
  if (trip.status === 'completed_pending_sync') {
    return '<div class="driver-complete-banner pending">Completion saved offline · waiting to sync</div>'
  }
  return kcpOfflinePreviousDriverFooterActions(trip,options)
}

// Window capture runs before the existing document-capture Driver mode handler.
window.addEventListener('click', async event => {
  if (navigator.onLine) return
  const childAction = event.target.closest('[data-driver-child-action]')
  const driverAction = event.target.closest('[data-driver-action]')
  if (!childAction && !driverAction) return

  event.preventDefault()
  event.stopImmediatePropagation()
  if (!driverModeTripId || !driverModeSnapshot) {
    toast('Open the ride online once before using offline actions.',true)
    return
  }

  let action
  let payload = {}
  if (childAction) {
    action = childAction.dataset.driverChildAction === 'picked_up' ? 'child_picked_up' : 'child_skipped'
    payload.childId = childAction.dataset.childId
    if (action === 'child_skipped') {
      const note = prompt('Why is this child not riding?')
      if (note === null) return
      payload.note = note
    }
  } else {
    action = ({
      confirm: 'confirm_trip',
      start: 'start_trip',
      arrive: 'arrive_destination',
      complete: 'confirm_completion',
      issue: 'report_issue'
    })[driverAction.dataset.driverAction]
    if (!action) return
    if (action === 'report_issue') {
      const category = prompt('Issue category: delay, child, vehicle, route, or other','other')
      if (category === null) return
      const note = prompt('Describe the issue')
      if (note === null) return
      payload = { category, note }
    }
  }

  const queued = createOfflineAction({
    tripId: driverModeTripId,
    groupId: driverModeSnapshot.group?.id || null,
    action,
    payload
  })
  await enqueueOfflineAction(queued)
  applyOfflineActionToSnapshot(queued)
  await cacheDriverSnapshot(driverModeTripId,driverModeSnapshot)
  await loadOfflineQueueState()
  renderDriverMode()
  toast('Change saved on this device and waiting to sync')
}, { capture: true })

function applyOfflineActionToSnapshot(action) {
  const trip = driverModeSnapshot.trip
  if (action.action === 'confirm_trip') trip.status = 'ready'
  if (action.action === 'start_trip') {
    trip.status = 'in_progress'
    trip.started_at = action.deviceTimestamp
  }
  if (action.action === 'child_picked_up' || action.action === 'child_skipped') {
    const child = driverModeSnapshot.roster.find(item => item.child_id === action.payload.childId)
    if (child) {
      child.latest_status = action.action
      child.latest_status_at = action.deviceTimestamp
      if (action.payload.note) child.absence_note = action.payload.note
    }
  }
  if (action.action === 'arrive_destination') trip.status = 'completion_due'
  if (action.action === 'confirm_completion') trip.status = 'completed_pending_sync'
  driverModeSnapshot.events = [
    ...(driverModeSnapshot.events || []),
    { eventType: action.action, actorName: 'Saved offline', serverTimestamp: action.deviceTimestamp, localOnly: true }
  ]
}

async function syncOfflineActions() {
  if (offlineSyncRunning || !navigator.onLine || !state.session?.user?.id) return
  offlineSyncRunning = true
  try {
    let actions = await listOfflineActions()
    const batch = nextSyncBatch(actions,100)
    const blockedTrips = new Set()
    let successful = 0

    for (const action of batch) {
      if (blockedTrips.has(action.tripId)) continue
      await updateOfflineAction(action.id,{ status:'syncing', attempts:Number(action.attempts || 0) + 1 })
      try {
        const { error } = await supabase.rpc('kcp_apply_offline_trip_action', {
          p_client_action_id: action.id,
          p_trip_id: action.tripId,
          p_action: action.action,
          p_payload: action.payload || {},
          p_device_timestamp: action.deviceTimestamp
        })
        if (error) throw error
        await removeOfflineAction(action.id)
        successful += 1
      } catch (error) {
        await updateOfflineAction(action.id,{ status:'failed', lastError:error.message || String(error) })
        blockedTrips.add(action.tripId)
      }
    }

    await loadOfflineQueueState()
    if (successful) {
      if (state.activeGroup) await loadWorkspace()
      await loadAllGroupFeeds()
      renderAll()
      if (el('driverModeDialog')?.open && driverModeTripId) await loadDriverModeSnapshot()
      toast(`${successful} offline action${successful === 1 ? '' : 's'} synced`)
    }
  } finally {
    offlineSyncRunning = false
    renderOfflineStatus()
  }
}

window.addEventListener('online', () => {
  loadOfflineQueueState().then(syncOfflineActions).catch(console.warn)
})
window.addEventListener('offline', () => loadOfflineQueueState().catch(console.warn))

document.addEventListener('click', async event => {
  const retryAll = event.target.closest('[data-action="retry-offline-sync"]')
  if (retryAll) {
    event.preventDefault()
    if (!navigator.onLine) return toast('Reconnect before syncing.',true)
    await syncOfflineActions()
    if (retryAll.closest('.offline-status')) navigate('more')
    return
  }
  const retryOne = event.target.closest('[data-action="retry-one-offline-action"]')
  if (retryOne) {
    event.preventDefault()
    await updateOfflineAction(retryOne.dataset.offlineActionId,{ status:'pending', lastError:null })
    await loadOfflineQueueState()
    await syncOfflineActions()
    return
  }
  const discard = event.target.closest('[data-action="discard-offline-action"]')
  if (!discard) return
  event.preventDefault()
  if (!confirm('Discard this locally saved ride action? It will not be applied to the group record.')) return
  await removeOfflineAction(discard.dataset.offlineActionId)
  await loadOfflineQueueState()
  toast('Offline action discarded')
}, { capture: true })

// Apply basic accessibility attributes to dynamically created icon controls.
function hardenDynamicAccessibility(root = document) {
  root.querySelectorAll('button').forEach(button => {
    if (!button.getAttribute('aria-label') && !button.textContent.trim()) {
      button.setAttribute('aria-label','Action')
    }
  })
  root.querySelectorAll('[role="status"]').forEach(node => node.setAttribute('aria-live',node.getAttribute('aria-live') || 'polite'))
}

const accessibilityObserver = new MutationObserver(records => {
  for (const record of records) {
    record.addedNodes.forEach(node => {
      if (node.nodeType === Node.ELEMENT_NODE) hardenDynamicAccessibility(node)
    })
  }
})
accessibilityObserver.observe(document.body,{ childList:true, subtree:true })
hardenDynamicAccessibility()

setTimeout(() => {
  loadOfflineQueueState()
    .then(() => navigator.onLine ? syncOfflineActions() : null)
    .catch(console.warn)
},0)
