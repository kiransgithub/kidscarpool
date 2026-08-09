// Safe ride state machine. Time passage can request confirmation, but it never
// claims that child transport occurred and never awards points automatically.

const KCP_SAFE_ACTIVE_STATUSES = new Set([
  'scheduled','coverage_needed','cover_requested','cover_accepted',
  'confirmation_due','ready','in_progress','completion_due','unconfirmed'
])

activeTrips = function () {
  const today = new Date().toISOString().slice(0, 10)
  return orderTripsByProximity(state.trips.filter(trip =>
    trip.trip_date >= today || KCP_SAFE_ACTIVE_STATUSES.has(trip.status)
  ))
}

statusPill = function (status) {
  const labels = {
    scheduled: 'Scheduled',
    coverage_needed: 'Coverage needed',
    cover_requested: 'Cover requested',
    cover_accepted: 'Volunteer assigned',
    confirmation_due: 'Driver confirmation due',
    ready: 'Driver ready',
    in_progress: 'In progress',
    completion_due: 'Completion confirmation due',
    completed: 'Completed',
    unconfirmed: 'Unconfirmed',
    cancelled: 'Cancelled'
  }
  const css = ({
    coverage_needed: 'warning',
    cover_requested: 'warning',
    confirmation_due: 'warning',
    completion_due: 'warning',
    unconfirmed: 'danger',
    cover_accepted: 'info',
    ready: 'info',
    in_progress: 'info',
    completed: 'complete'
  })[status] || ''
  return `<span class="status-pill ${css}">${escapeHTML(labels[status] || capitalize(status))}</span>`
}

function safeTripActions(trip, { compact = false } = {}) {
  const access = kcpAccess()
  const currentUser = state.session?.user?.id
  const driverId = trip.actual_driver_id || trip.scheduled_driver_id
  const isDriver = access.canDrive && driverId === currentUser
  const openRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'open')
  const acceptedRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'accepted')
  const buttons = []
  const label = value => compact ? value.replace(' ride', '') : value

  if (isDriver && ['scheduled','cover_accepted','confirmation_due','unconfirmed'].includes(trip.status) && !trip.started_at) {
    buttons.push(`<button class="action-button green" data-action="confirm-trip" data-trip-id="${trip.id}" type="button">${label('Confirm ride')}</button>`)
  }

  if (isDriver && trip.status === 'ready') {
    const gate = tripStartGate(trip, new Date())
    buttons.push(`<button class="action-button green" data-action="safe-start-trip" data-trip-id="${trip.id}" type="button" ${gate.allowed ? '' : 'disabled'}>${label('Start ride')}</button>`)
    if (!gate.allowed && !compact) buttons.push(`<p class="trip-gate-note">${escapeHTML(gate.reason)}</p>`)
  }

  if (isDriver && trip.status === 'in_progress') {
    buttons.push(`<button class="action-button green" data-action="report-arrival" data-trip-id="${trip.id}" type="button">${label('Report arrival')}</button>`)
  }

  if (isDriver && ['completion_due','unconfirmed'].includes(trip.status) && trip.started_at) {
    buttons.push(`<button class="action-button green" data-action="confirm-completion" data-trip-id="${trip.id}" type="button">${label('Confirm completed')}</button>`)
  }

  if (!access.isViewer && trip.started_at == null && ['scheduled','ready','confirmation_due','unconfirmed'].includes(trip.status) && trip.scheduled_driver_id === currentUser) {
    buttons.push(`<button class="action-button orange" data-action="request-cover" data-trip-id="${trip.id}" type="button">${label('Need cover')}</button>`)
  }

  if (access.canDrive && openRequest && trip.scheduled_driver_id !== currentUser) {
    buttons.push(`<button class="action-button green" data-action="accept-cover" data-request-id="${openRequest.id}" type="button">${label('Volunteer')}</button>`)
  }

  const ownOpen = openRequest?.requested_by === currentUser
  if (ownOpen) buttons.push(withdrawButtonHTML(openRequest, compact))

  if (acceptedRequest?.accepted_by === currentUser && trip.started_at == null && trip.status === 'cover_accepted') {
    buttons.push(`<button class="action-button orange" data-action="release-accepted-cover" data-request-id="${acceptedRequest.id}" type="button">${label('Release accepted ride')}</button>`)
  }

  if (access.isAdmin && ['in_progress','completion_due','unconfirmed'].includes(trip.status)) {
    buttons.push(`<button class="action-button" data-action="admin-confirm-completion" data-trip-id="${trip.id}" type="button">Admin confirm</button>`)
  }

  return buttons
}

tripRow = function (trip) {
  const acceptedRequest = acceptedCoverForTrip(state.coverRequests, trip.id)
  const acceptedText = coverAcceptedLabel(acceptedRequest, state.memberships)
  const buttons = [
    `<button class="action-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View</button>`,
    ...safeTripActions(trip, { compact: true })
  ]

  return `<article class="trip-row safe-trip-row" data-trip-status="${escapeHTML(trip.status)}">
    <div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div>
    <div>
      <h3>${escapeHTML(kcpTripLabel(trip))} · ${escapeHTML(driverName(trip))}</h3>
      <p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label || formatDateTime(trip.scheduled_time))}</p>
      <p>${statusPill(trip.status)} ${trip.volunteer_assignment ? '<span class="badge">Volunteer</span>' : ''}</p>
      ${acceptedText ? `<div class="cover-acceptance">✓ ${escapeHTML(acceptedText)}</div>` : ''}
      ${trip.status === 'confirmation_due' ? '<p class="safe-state-note">The scheduled time arrived without a driver confirmation.</p>' : ''}
      ${trip.status === 'completion_due' ? '<p class="safe-state-note">Arrival was reported or expected duration elapsed. Completion still requires confirmation.</p>' : ''}
      ${trip.status === 'unconfirmed' ? '<p class="safe-state-note danger">This ride is not recorded as completed. A driver or group administrator must resolve it.</p>' : ''}
    </div>
    <div class="button-row safe-trip-actions">${buttons.join('')}</div>
  </article>`
}

const kcpSafePreviousShowTrip = showTrip
showTrip = function (tripId) {
  kcpSafePreviousShowTrip(tripId)
  const trip = state.trips.find(item => item.id === tripId)
  const content = el('tripDialogContent')
  if (!trip || !content) return

  content.querySelectorAll([
    '[data-action="start-trip"]',
    '[data-action="complete-trip"]',
    '[data-action="request-cover"]',
    '[data-action="accept-cover"]',
    '[data-action="withdraw-cover"]'
  ].join(',')).forEach(control => control.remove())

  const existingActionStack = content.querySelector('.trip-action-stack, .button-row:last-child')
  const actionStack = existingActionStack || document.createElement('div')
  if (!existingActionStack) {
    actionStack.className = 'trip-action-stack'
    content.append(actionStack)
  }
  actionStack.classList.add('safe-trip-actions')
  actionStack.innerHTML = safeTripActions(trip).join('') || '<span class="meta">No action is available for your role and the current ride status.</span>'

  content.querySelector('[data-safe-state-card]')?.remove()
  content.insertAdjacentHTML('beforeend', `
    <section class="card safe-state-card" data-safe-state-card>
      <div class="group-card-head"><div><span class="eyebrow">VERIFICATION STATUS</span><h3>${escapeHTML(safeStateHeading(trip.status))}</h3></div>${statusPill(trip.status)}</div>
      <p>${escapeHTML(safeStateDescription(trip))}</p>
      <div id="tripEventTimeline" class="trip-event-timeline"><span class="meta">Loading ride history…</span></div>
    </section>`)

  loadTripEventTimeline(trip.id)
}

async function loadTripEventTimeline(tripId) {
  const target = el('tripEventTimeline')
  if (!target) return
  const { data, error } = await supabase.rpc('kcp_trip_event_timeline', { p_trip_id: tripId })
  if (error) {
    target.innerHTML = '<span class="meta">Ride history is unavailable.</span>'
    return
  }
  target.innerHTML = (data || []).map(event => `
    <div class="trip-event-row">
      <span class="trip-event-dot"></span>
      <div><strong>${escapeHTML(humanize(event.event_type))}</strong><small>${formatDateTime(event.server_timestamp)}${event.actor_name ? ` · ${escapeHTML(event.actor_name)}` : ' · System'}</small></div>
    </div>`).join('') || '<span class="meta">No ride events have been recorded yet.</span>'
}

function safeStateHeading(status) {
  return ({
    scheduled: 'Driver confirmation has not opened or is pending',
    cover_accepted: 'Volunteer must confirm the ride',
    confirmation_due: 'Driver confirmation is overdue',
    ready: 'Driver confirmed and is ready to start',
    in_progress: 'Ride is underway',
    completion_due: 'Completion confirmation is required',
    completed: 'Completion was explicitly confirmed',
    unconfirmed: 'Ride outcome needs resolution',
    cover_requested: 'Waiting for a volunteer',
    coverage_needed: 'No driver is assigned',
    cancelled: 'Ride was cancelled'
  })[status] || 'Ride status'
}

function safeStateDescription(trip) {
  if (trip.status === 'completed') {
    return trip.verification_note || 'The active driver or a group administrator explicitly confirmed completion.'
  }
  if (trip.status === 'unconfirmed') {
    return 'Time passage did not mark this ride completed. Confirm the actual outcome before points are awarded.'
  }
  if (trip.status === 'completion_due') {
    return 'Arrival was reported or the expected duration elapsed. The ride remains unverified until a driver or administrator confirms completion.'
  }
  if (trip.status === 'confirmation_due') {
    return 'The scheduled time was reached without a driver response. The ride is not assumed to be in progress.'
  }
  if (trip.status === 'ready') return 'The assigned driver confirmed this ride. Start becomes available 10 minutes before the scheduled time.'
  return 'KCP records explicit driver actions. It does not infer completed child transportation from time alone.'
}

async function safeTripRpc(rpcName, tripId, successMessage, extra = {}) {
  return runAction(async () => {
    const { data, error } = await supabase.rpc(rpcName, { p_trip_id: tripId, ...extra })
    if (error) throw error
    await loadAllGroupFeeds()
    if (state.activeGroup) await loadWorkspace()
    renderAll()
    if (el('tripDialog')?.open) showTrip(tripId)
    return data
  }, successMessage, { operation: rpcName })
}

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-action]')
  if (!button) return
  const action = button.dataset.action
  if (![
    'confirm-trip','safe-start-trip','report-arrival','confirm-completion',
    'admin-confirm-completion','release-accepted-cover','start-trip','complete-trip'
  ].includes(action)) return

  event.preventDefault()
  event.stopImmediatePropagation()

  if (action === 'confirm-trip') {
    await safeTripRpc('kcp_confirm_trip', button.dataset.tripId, 'Ride confirmed')
    return
  }
  if (action === 'safe-start-trip' || action === 'start-trip') {
    await safeTripRpc('kcp_start_trip', button.dataset.tripId, 'Ride started')
    return
  }
  if (action === 'report-arrival' || action === 'complete-trip') {
    await safeTripRpc('kcp_complete_trip', button.dataset.tripId, 'Arrival reported; confirm completion next')
    return
  }
  if (action === 'confirm-completion') {
    await safeTripRpc('kcp_confirm_trip_completion', button.dataset.tripId, 'Ride completion confirmed and points awarded')
    return
  }
  if (action === 'admin-confirm-completion') {
    const note = prompt('Why are you confirming this ride on behalf of the driver?')
    if (note === null) return
    await safeTripRpc('kcp_admin_confirm_trip_completion', button.dataset.tripId, 'Ride completion confirmed by group administrator', { p_note: note })
    return
  }
  if (action === 'release-accepted-cover') {
    const reason = prompt('Why can you no longer cover this ride?')
    if (reason === null) return
    await runAction(async () => {
      const { error } = await supabase.rpc('kcp_release_accepted_cover', {
        p_request_id: button.dataset.requestId,
        p_reason: reason
      })
      if (error) throw error
      await loadAllGroupFeeds()
      if (state.activeGroup) await loadWorkspace()
      renderAll()
      if (el('tripDialog')?.open) el('tripDialog').close()
    }, 'Accepted cover released; the ride needs coverage again', { operation: 'release_accepted_cover' })
  }
}, { capture: true })
