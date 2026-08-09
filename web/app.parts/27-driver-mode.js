// Driver-first execution screen optimized for one-handed use during a ride.

let driverModeTripId = null
let driverModeSnapshot = null

if (!el('driverModeDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="driverModeDialog" class="driver-mode-dialog">
      <div class="driver-mode-shell">
        <header class="driver-mode-header">
          <button id="driverModeClose" class="driver-mode-close" type="button" aria-label="Close driver mode">×</button>
          <div><span id="driverModeGroup" class="eyebrow">GROUP</span><h1 id="driverModeTitle">Ride</h1><p id="driverModeTime"></p></div>
          <span id="driverModeStatus"></span>
        </header>
        <main id="driverModeContent" class="driver-mode-content"></main>
        <footer id="driverModeFooter" class="driver-mode-footer"></footer>
      </div>
    </dialog>`)
}

function closeDriverMode() {
  const dialog = el('driverModeDialog')
  if (dialog?.open) dialog.close('cancel')
  driverModeTripId = null
  driverModeSnapshot = null
}

el('driverModeClose')?.addEventListener('click', closeDriverMode)
el('driverModeDialog')?.addEventListener('cancel', event => {
  event.preventDefault()
  closeDriverMode()
})

function canOpenDriverMode(trip) {
  const currentUser = state.session?.user?.id
  const driverId = trip?.actual_driver_id || trip?.scheduled_driver_id
  return Boolean(
    trip
      && kcpAccess().canDrive
      && (driverId === currentUser || kcpAccess().isAdmin)
      && !['cancelled'].includes(trip.status)
  )
}

const kcpDriverModePreviousTripRow = tripRow
tripRow = function (trip) {
  const html = kcpDriverModePreviousTripRow(trip)
  if (!canOpenDriverMode(trip)) return html
  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const row = template.content.firstElementChild
  const actions = row?.querySelector('.button-row')
  if (actions && !actions.querySelector('[data-action="open-driver-mode"]')) {
    actions.insertAdjacentHTML('afterbegin', `<button class="action-button driver-mode-button" data-action="open-driver-mode" data-trip-id="${trip.id}" type="button">Driver mode</button>`)
  }
  return row?.outerHTML || html
}

const kcpDriverModePreviousShowTrip = showTrip
showTrip = function (tripId) {
  kcpDriverModePreviousShowTrip(tripId)
  const trip = state.trips.find(item => item.id === tripId)
  if (!canOpenDriverMode(trip)) return
  const actions = el('tripDialogContent')?.querySelector('.trip-action-stack, .safe-trip-actions')
  if (actions && !actions.querySelector('[data-action="open-driver-mode"]')) {
    actions.insertAdjacentHTML('afterbegin', `<button class="primary-button driver-mode-button" data-action="open-driver-mode" data-trip-id="${trip.id}" type="button">Open driver mode</button>`)
  }
}

document.addEventListener('click', async event => {
  const open = event.target.closest('[data-action="open-driver-mode"]')
  if (open) {
    event.preventDefault()
    event.stopImmediatePropagation()
    await openDriverMode(open.dataset.tripId)
    return
  }

  const childAction = event.target.closest('[data-driver-child-action]')
  if (childAction) {
    event.preventDefault()
    const status = childAction.dataset.driverChildAction
    let note = null
    if (status === 'skipped') {
      note = prompt('Why is this child not riding?')
      if (note === null) return
    }
    await driverModeAction(async () => {
      const { error } = await supabase.rpc('kcp_mark_child_trip_status', {
        p_trip_id: driverModeTripId,
        p_child_id: childAction.dataset.childId,
        p_status: status,
        p_client_event_id: driverClientEventId(status),
        p_note: note,
        p_device_timestamp: new Date().toISOString()
      })
      if (error) throw error
    }, status === 'picked_up' ? 'Child marked picked up' : 'Child marked not riding')
    return
  }

  const action = event.target.closest('[data-driver-action]')
  if (!action) return
  event.preventDefault()
  const name = action.dataset.driverAction

  if (name === 'confirm') {
    await driverModeAction(() => driverModeRpc('kcp_confirm_trip'), 'Ride confirmed')
  } else if (name === 'start') {
    await driverModeAction(() => driverModeRpc('kcp_start_trip'), 'Ride started')
  } else if (name === 'arrive') {
    await driverModeAction(async () => {
      const { error } = await supabase.rpc('kcp_report_destination_arrival', {
        p_trip_id: driverModeTripId,
        p_client_event_id: driverClientEventId('arrived'),
        p_device_timestamp: new Date().toISOString()
      })
      if (error) throw error
    }, 'Destination arrival reported')
  } else if (name === 'complete') {
    await driverModeAction(() => driverModeRpc('kcp_confirm_trip_completion'), 'Ride completion confirmed')
  } else if (name === 'issue') {
    const category = prompt('Issue category: delay, child, vehicle, route, or other', 'other')
    if (category === null) return
    const note = prompt('Describe the issue')
    if (note === null) return
    await driverModeAction(async () => {
      const { error } = await supabase.rpc('kcp_report_trip_issue', {
        p_trip_id: driverModeTripId,
        p_category: category,
        p_note: note,
        p_client_event_id: driverClientEventId('issue'),
        p_device_timestamp: new Date().toISOString()
      })
      if (error) throw error
    }, 'Ride issue recorded')
  }
}, { capture: true })

async function openDriverMode(tripId) {
  driverModeTripId = tripId
  el('driverModeDialog').showModal()
  el('driverModeContent').innerHTML = '<div class="driver-mode-loading"><div class="spinner"></div><p>Loading ride details…</p></div>'
  el('driverModeFooter').innerHTML = ''
  await loadDriverModeSnapshot()
}

async function loadDriverModeSnapshot() {
  const { data, error } = await supabase.rpc('kcp_driver_trip_snapshot', {
    p_trip_id: driverModeTripId
  })
  if (error) {
    el('driverModeContent').innerHTML = `<div class="driver-mode-empty"><h2>Driver mode unavailable</h2><p>${escapeHTML(sanitizeUserMessage(error.message))}</p></div>`
    return
  }
  driverModeSnapshot = data
  renderDriverMode()
}

function renderDriverMode() {
  const snapshot = driverModeSnapshot || {}
  const trip = snapshot.trip || {}
  const group = snapshot.group || {}
  const roster = snapshot.roster || []
  const pickedUp = roster.filter(child => child.latest_status === 'child_picked_up').length
  const skipped = roster.filter(child => child.latest_status === 'child_skipped').length
  const accounted = pickedUp + skipped
  const allAccounted = accounted >= roster.length && roster.length > 0

  el('driverModeGroup').textContent = group.name || 'CARPOOL GROUP'
  el('driverModeTitle').textContent = trip.display_label || 'Ride'
  el('driverModeTime').textContent = trip.scheduled_time
    ? formatDateTime(trip.scheduled_time)
    : `${formatDate(trip.trip_date)} · ${trip.time_label || 'Time confirmation required'}`
  el('driverModeStatus').innerHTML = statusPill(trip.status)

  const destinationUrl = group.destination
    ? `https://maps.apple.com/?q=${encodeURIComponent(group.destination)}`
    : null
  el('driverModeContent').innerHTML = `
    <section class="driver-mode-summary">
      <div><strong>${roster.length}</strong><span>Children</span></div>
      <div><strong>${pickedUp}</strong><span>Picked up</span></div>
      <div><strong>${skipped}</strong><span>Not riding</span></div>
    </section>
    ${trip.status === 'in_progress' ? `<section class="driver-progress"><div style="width:${roster.length ? Math.round(accounted / roster.length * 100) : 0}%"></div></section>` : ''}
    <section class="driver-route-section">
      <div class="driver-section-title"><span class="eyebrow">ROUTE</span><h2>${trip.status === 'in_progress' ? 'Pickup checklist' : 'Ride roster'}</h2></div>
      <div class="driver-child-list">${roster.map(child => driverChildCard(child, trip.status)).join('') || '<div class="driver-mode-empty"><p>No child roster is available.</p></div>'}</div>
    </section>
    <section class="driver-destination-card">
      <div><span class="eyebrow">DESTINATION</span><h2>${escapeHTML(group.destination || 'Group destination')}</h2></div>
      ${destinationUrl ? `<a class="driver-secondary-action" href="${destinationUrl}" target="_blank" rel="noopener">Navigate</a>` : ''}
    </section>
    ${trip.status === 'in_progress' && group.safetyRequired && !allAccounted ? '<p class="driver-blocking-note">Account for every child before reporting destination arrival.</p>' : ''}
  `

  el('driverModeFooter').innerHTML = driverFooterActions(trip, { allAccounted, safetyRequired: group.safetyRequired })
}

function driverChildCard(child, tripStatus) {
  const status = child.latest_status
  const picked = status === 'child_picked_up'
  const skipped = status === 'child_skipped'
  const pickupUrl = child.pickup_address
    ? `https://maps.apple.com/?q=${encodeURIComponent(child.pickup_address)}`
    : null
  const tel = child.parent_phone || child.emergency_contact_phone

  return `<article class="driver-child-card ${picked ? 'picked' : skipped ? 'skipped' : ''}">
    <div class="driver-child-top">
      <div><strong>${escapeHTML(child.child_name)}</strong><span>${escapeHTML(child.pickup_address || 'Pickup address not provided')}</span></div>
      ${child.pickup_tag ? `<span class="driver-tag">${escapeHTML(child.pickup_tag)}</span>` : ''}
    </div>
    ${child.critical_alert ? `<div class="driver-critical-alert"><strong>Critical alert</strong><span>${escapeHTML(child.critical_alert)}</span></div>` : ''}
    ${child.pickup_instructions ? `<p class="driver-instructions">${escapeHTML(child.pickup_instructions)}</p>` : ''}
    <div class="driver-child-actions">
      ${pickupUrl ? `<a href="${pickupUrl}" target="_blank" rel="noopener">Navigate</a>` : ''}
      ${tel ? `<a href="tel:${escapeHTML(tel)}">Call ${escapeHTML(child.parent_name || 'contact')}</a>` : ''}
      ${tripStatus === 'in_progress' ? `
        <button data-driver-child-action="picked_up" data-child-id="${child.child_id}" type="button" ${picked ? 'disabled' : ''}>${picked ? '✓ Picked up' : 'Picked up'}</button>
        <button class="secondary" data-driver-child-action="skipped" data-child-id="${child.child_id}" type="button" ${skipped ? 'disabled' : ''}>${skipped ? '✓ Not riding' : 'Not riding'}</button>` : ''}
    </div>
  </article>`
}

function driverFooterActions(trip, options) {
  if (trip.status === 'completed') {
    return '<div class="driver-complete-banner">✓ Ride completion confirmed</div>'
  }
  if (['scheduled','cover_accepted','confirmation_due','unconfirmed'].includes(trip.status) && !trip.started_at) {
    return '<button class="driver-primary-action" data-driver-action="confirm" type="button">Confirm this ride</button>'
  }
  if (trip.status === 'ready') {
    const gate = tripStartGate(trip, new Date())
    return `<button class="driver-primary-action" data-driver-action="start" type="button" ${gate.allowed ? '' : 'disabled'}>Start ride</button><span class="driver-footer-note">${escapeHTML(gate.reason)}</span>`
  }
  if (trip.status === 'in_progress') {
    const blocked = options.safetyRequired && !options.allAccounted
    return `<button class="driver-primary-action" data-driver-action="arrive" type="button" ${blocked ? 'disabled' : ''}>Arrived at destination</button><button class="driver-issue-action" data-driver-action="issue" type="button">Report issue</button>`
  }
  if (['completion_due','unconfirmed'].includes(trip.status) && trip.started_at) {
    return '<button class="driver-primary-action" data-driver-action="complete" type="button">Confirm ride completed</button><button class="driver-issue-action" data-driver-action="issue" type="button">Report issue</button>'
  }
  return '<span class="driver-footer-note">No driver action is available for the current ride status.</span>'
}

async function driverModeRpc(name) {
  const { error } = await supabase.rpc(name, { p_trip_id: driverModeTripId })
  if (error) throw error
}

async function driverModeAction(action, successMessage) {
  await runAction(async () => {
    await action()
    if (state.activeGroup) await loadWorkspace()
    await loadAllGroupFeeds()
    renderAll()
    await loadDriverModeSnapshot()
  }, successMessage, { operation: 'driver_mode_action' })
}

function driverClientEventId(action) {
  const id = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`
  return `${driverModeTripId}:${action}:${id}`
}
