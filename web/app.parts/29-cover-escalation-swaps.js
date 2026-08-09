// Coverage deadlines, escalation stages and coordinated two-driver trip swaps.

state.coverSwapOperations = []
let swapOfferedTripId = null

const kcpOperationsPreviousLoadAllGroupFeeds = loadAllGroupFeeds
loadAllGroupFeeds = async function () {
  await kcpOperationsPreviousLoadAllGroupFeeds()
  if (!state.session?.user?.id) {
    state.coverSwapOperations = []
    return
  }
  const { data, error } = await supabase.rpc('kcp_my_cover_and_swap_operations', { p_limit: 400 })
  if (error && !/Could not find the function|schema cache/i.test(error.message || '')) throw error
  state.coverSwapOperations = data || []
}

if (!el('tripSwapDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="tripSwapDialog" class="modal trip-swap-dialog">
      <form id="tripSwapForm" class="dialog-form">
        <div class="dialog-title"><div><span class="eyebrow">SWAP RIDES</span><h2>Request a ride swap</h2></div><button id="tripSwapClose" class="close-button" type="button" aria-label="Close">×</button></div>
        <div id="tripSwapOffered" class="swap-summary"></div>
        <label>Ride you would take instead<select id="tripSwapRequested" required></select></label>
        <label>Note <span class="optional">optional</span><textarea id="tripSwapNote" rows="3" placeholder="Why this swap helps"></textarea></label>
        <p class="meta">The other assigned driver must accept. Both rides return to Scheduled and require fresh driver confirmation.</p>
        <button class="primary-button" type="submit">Send swap request</button>
      </form>
    </dialog>`)
}

function closeSwapDialog() {
  if (el('tripSwapDialog')?.open) el('tripSwapDialog').close('cancel')
  swapOfferedTripId = null
  el('tripSwapForm')?.reset()
}

el('tripSwapClose')?.addEventListener('click', closeSwapDialog)
el('tripSwapDialog')?.addEventListener('cancel', event => {
  event.preventDefault()
  closeSwapDialog()
})
el('tripSwapDialog')?.addEventListener('click', event => {
  if (event.target === el('tripSwapDialog')) closeSwapDialog()
})

function canRequestSwap(trip) {
  const userId = state.session?.user?.id
  return Boolean(
    trip
      && trip.scheduled_driver_id === userId
      && !trip.started_at
      && ['scheduled','ready','confirmation_due','unconfirmed'].includes(trip.status)
      && trip.scheduled_time
      && new Date(trip.scheduled_time).getTime() > Date.now() + 2 * 60 * 60 * 1000
  )
}

const kcpSwapPreviousTripRow = tripRow
tripRow = function (trip) {
  const html = kcpSwapPreviousTripRow(trip)
  if (!canRequestSwap(trip)) return html
  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const row = template.content.firstElementChild
  const actions = row?.querySelector('.button-row')
  if (actions && !actions.querySelector('[data-action="request-swap"]')) {
    actions.insertAdjacentHTML('beforeend', `<button class="action-button" data-action="request-swap" data-trip-id="${trip.id}" type="button">Swap</button>`)
  }
  return row?.outerHTML || html
}

function openSwapDialog(tripId) {
  const offered = state.trips.find(trip => trip.id === tripId)
  if (!offered || !canRequestSwap(offered)) {
    toast('This ride is no longer available for a swap.', true)
    return
  }
  const alternatives = state.trips.filter(trip =>
    trip.id !== offered.id
      && trip.group_id === offered.group_id
      && trip.scheduled_driver_id
      && trip.scheduled_driver_id !== state.session?.user?.id
      && !trip.started_at
      && ['scheduled','ready','confirmation_due','unconfirmed'].includes(trip.status)
      && trip.scheduled_time
      && new Date(trip.scheduled_time).getTime() > Date.now() + 2 * 60 * 60 * 1000
  )
  if (!alternatives.length) {
    toast('No future ride assigned to another driver is available to swap.', true)
    return
  }

  swapOfferedTripId = offered.id
  el('tripSwapOffered').innerHTML = `<strong>You are offering</strong><span>${escapeHTML(kcpTripLabel(offered))} · ${formatDateTime(offered.scheduled_time)}</span>`
  el('tripSwapRequested').innerHTML = alternatives.map(trip => `
    <option value="${trip.id}">${escapeHTML(kcpTripLabel(trip))} · ${formatDateTime(trip.scheduled_time)} · ${escapeHTML(driverName(trip))}</option>`).join('')
  el('tripSwapDialog').showModal()
}

el('tripSwapForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_create_trip_swap', {
      p_offered_trip_id: swapOfferedTripId,
      p_requested_trip_id: el('tripSwapRequested').value,
      p_note: el('tripSwapNote').value.trim() || null
    })
    if (error) throw error
    closeSwapDialog()
    await loadAllGroupFeeds()
    renderAll()
    navigate('requests')
  }, 'Swap request sent', { operation: 'create_trip_swap' })
})

document.addEventListener('click', async event => {
  const requestSwap = event.target.closest('[data-action="request-swap"]')
  if (requestSwap) {
    event.preventDefault()
    openSwapDialog(requestSwap.dataset.tripId)
    return
  }

  const respond = event.target.closest('[data-action="respond-swap"]')
  if (respond) {
    event.preventDefault()
    const accept = respond.dataset.decision === 'accepted'
    const note = accept ? null : prompt('Optional reason for declining the swap')
    if (!accept && note === null) return
    await runAction(async () => {
      const { error } = await supabase.rpc('kcp_respond_trip_swap', {
        p_swap_id: respond.dataset.swapId,
        p_accept: accept,
        p_note: note
      })
      if (error) throw error
      await loadAllGroupFeeds()
      if (state.activeGroup) await loadWorkspace()
      renderAll()
    }, accept ? 'Ride swap accepted' : 'Ride swap declined', { operation: 'respond_trip_swap' })
    return
  }

  const cancel = event.target.closest('[data-action="cancel-swap"]')
  if (cancel) {
    event.preventDefault()
    if (!confirm('Cancel this pending swap request?')) return
    await runAction(async () => {
      const { error } = await supabase.rpc('kcp_cancel_trip_swap', { p_swap_id: cancel.dataset.swapId })
      if (error) throw error
      await loadAllGroupFeeds()
      renderAll()
    }, 'Swap request cancelled', { operation: 'cancel_trip_swap' })
  }
}, { capture: true })

renderAllGroupRequests = function () {
  const list = el('allGroupRequestList')
  if (!list) return
  const availability = (state.allGroupRequests || []).filter(item => item.request_type === 'availability')
  const operations = state.coverSwapOperations || []

  list.innerHTML = `
    ${operations.length ? `<section class="request-section"><div class="request-section-heading"><span class="eyebrow">COVERAGE + SWAPS</span><h2>Ride responsibility</h2></div>${operations.map(coverSwapCard).join('')}</section>` : ''}
    ${availability.length ? `<section class="request-section"><div class="request-section-heading"><span class="eyebrow">AVAILABILITY</span><h2>Schedule availability changes</h2></div>${availability.map(availabilityRequestCard).join('')}</section>` : ''}
    ${!operations.length && !availability.length ? empty('No cover, swap or availability request needs attention.') : ''}`
  renderAbsenceRequests()
}

function coverSwapCard(operation) {
  if (operation.operation_type === 'swap') return swapOperationCard(operation)
  const escalation = coverEscalationPresentation(operation.escalation_stage)
  const currentUser = state.session?.user?.id
  const canVolunteer = operation.status === 'open' && operation.requires_my_action
  const ownOpen = operation.status === 'open' && operation.requested_by === currentUser
  const acceptedByMe = operation.status === 'accepted' && operation.accepted_by === currentUser

  return `<article class="request-card cover-operation ${escapeHTML(operation.escalation_stage || 'open')}" data-operation-id="${operation.operation_id}">
    <div class="group-card-head">
      <div><span class="group-context-badge">${escapeHTML(operation.group_name)}</span><h3>${escapeHTML(operation.primary_label || 'Driver needed')}</h3></div>
      <span class="status-pill ${escalation.css}">${escapeHTML(escalation.label)}</span>
    </div>
    <p class="meta">${operation.primary_time ? formatDateTime(operation.primary_time) : 'Time confirmation required'} · Requested by ${escapeHTML(operation.requested_by_name || 'Member')}</p>
    ${operation.note ? `<p>${escapeHTML(operation.note)}</p>` : ''}
    ${operation.accepted_by_name ? `<p class="cover-acceptance">✓ Accepted by ${escapeHTML(operation.accepted_by_name)}</p>` : ''}
    ${operation.respond_by && operation.status === 'open' ? `<p class="response-deadline">Respond by ${formatDateTime(operation.respond_by)}</p>` : ''}
    ${escalation.detail ? `<p class="meta escalation-detail">${escapeHTML(escalation.detail)}</p>` : ''}
    <div class="button-row">
      ${canVolunteer ? `<button class="action-button green" data-action="accept-cover" data-request-id="${operation.operation_id}" type="button">Volunteer</button>` : ''}
      ${ownOpen ? `<button class="action-button" data-action="withdraw-cover" data-request-id="${operation.operation_id}" type="button">Withdraw request</button>` : ''}
      ${acceptedByMe ? `<button class="action-button orange" data-action="release-accepted-cover" data-request-id="${operation.operation_id}" type="button">I cannot drive this ride</button>` : ''}
      <button class="action-button" data-action="open-agenda-trip" data-group-id="${operation.group_id}" data-trip-id="${operation.primary_trip_id}" type="button">View ride</button>
    </div>
  </article>`
}

function swapOperationCard(operation) {
  const currentUser = state.session?.user?.id
  const target = operation.requested_from === currentUser
  const requester = operation.requested_by === currentUser
  return `<article class="request-card swap-operation ${operation.requires_my_action ? 'needs-action' : ''}">
    <div class="group-card-head">
      <div><span class="group-context-badge">${escapeHTML(operation.group_name)}</span><h3>Ride swap request</h3></div>
      ${statusPill(operation.status)}
    </div>
    <div class="swap-pair">
      <div><small>Offered</small><strong>${escapeHTML(operation.primary_label)}</strong><span>${formatDateTime(operation.primary_time)}</span></div>
      <span class="swap-arrow">⇄</span>
      <div><small>Requested</small><strong>${escapeHTML(operation.secondary_label)}</strong><span>${formatDateTime(operation.secondary_time)}</span></div>
    </div>
    <p class="meta">${escapeHTML(operation.requested_by_name || 'Member')} asks ${escapeHTML(operation.requested_from_name || 'another driver')} to exchange these rides.</p>
    ${operation.note ? `<p>${escapeHTML(operation.note)}</p>` : ''}
    <p class="response-deadline">Respond by ${formatDateTime(operation.respond_by)}</p>
    <div class="button-row">
      ${target ? `<button class="action-button green" data-action="respond-swap" data-swap-id="${operation.operation_id}" data-decision="accepted" type="button">Accept swap</button><button class="action-button" data-action="respond-swap" data-swap-id="${operation.operation_id}" data-decision="rejected" type="button">Decline</button>` : ''}
      ${requester ? `<button class="action-button" data-action="cancel-swap" data-swap-id="${operation.operation_id}" type="button">Cancel request</button>` : ''}
    </div>
  </article>`
}

function availabilityRequestCard(request) {
  return `<article class="request-card ${request.requires_my_action ? 'needs-action' : ''}">
    <div class="group-card-head"><div><span class="group-context-badge">${escapeHTML(request.group_name)}</span><h3>Availability change</h3></div>${statusPill(request.status)}</div>
    <p class="meta">Submitted by ${escapeHTML(request.requested_by_name || 'Member')}</p>
    ${request.note ? `<p>${escapeHTML(request.note)}</p>` : ''}
    ${request.requires_my_action ? `<div class="button-row"><button class="action-button green" data-action="review-constraint" data-request-id="${request.request_id}" data-decision="approved" type="button">Approve</button><button class="action-button" data-action="review-constraint" data-request-id="${request.request_id}" data-decision="rejected" type="button">Reject</button></div>` : ''}
  </article>`
}

function coverEscalationPresentation(stage) {
  return ({
    open: { label: 'Open', css: 'info', detail: '' },
    eligible_drivers: { label: 'Drivers notified', css: 'warning', detail: 'The ride is within 60 minutes and needs an eligible volunteer.' },
    group_admin: { label: 'Group manager notified', css: 'warning', detail: 'The ride is within 30 minutes. A group manager needs to find a driver.' },
    unresolved: { label: 'No driver yet', css: 'danger', detail: 'The ride is within 15 minutes and still needs a driver.' },
    resolved: { label: 'Resolved', css: 'complete', detail: '' }
  })[stage] || { label: humanize(stage || 'open'), css: '', detail: '' }
}
