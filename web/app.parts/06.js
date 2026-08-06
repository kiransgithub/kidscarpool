import {
  acceptedCoverForTrip,
  coverAcceptedLabel,
  orderTripsByProximity,
  tripMoment,
  tripStartGate,
  upcomingActionableTrips
} from './logic.js'

// ---------------------------------------------------------------------------
// Calendar-optional group creation
// ---------------------------------------------------------------------------

const kcpCreateGroupForm = el('createGroupForm')
if (kcpCreateGroupForm) {
  kcpCreateGroupForm.addEventListener('submit', async event => {
    event.preventDefault()
    event.stopImmediatePropagation()

    const weekdays = qsa('input[name="newServiceWeekday"]:checked')
      .map(input => Number(input.value))
      .sort()
    const startDate = el('newScheduleStart').value
    const endDate = el('newScheduleEnd').value

    if (!weekdays.length) {
      toast('Choose at least one recurring weekday.', true)
      return
    }
    if (!startDate || !endDate || startDate > endDate) {
      toast('Enter a valid schedule start and end date.', true)
      return
    }

    await runAction(async () => {
      const destination = el('newSchoolName').value.trim()
      const term = el('newAcademicYear').value.trim() || 'Custom schedule'
      const autoMinutes = Number(el('newAutoCompleteMinutes').value)
      const { data, error } = await supabase.rpc('kcp_create_group_v2', {
        p_name: el('newGroupName').value.trim(),
        p_group_kind: el('newGroupType').value,
        p_destination_name: destination,
        p_destination_key: slug(destination),
        p_term_label: term,
        p_schedule_start_date: startDate,
        p_schedule_end_date: endDate,
        p_service_weekdays: weekdays,
        p_drop_time: el('newDropTime').value,
        p_pickup_time: el('newPickupTime').value,
        p_auto_complete_after_minutes: autoMinutes,
        p_child_name: el('newChildName').value.trim(),
        p_grade: Number(el('newChildGrade').value),
        p_drop_weekdays: weekdays,
        p_pickup_weekdays: weekdays,
        p_notes: ''
      })
      if (error) throw error

      const created = data?.[0]
      if (created?.group_id) localStorage.setItem(ACTIVE_GROUP_KEY, created.group_id)
      el('createGroupDialog').close()
      kcpCreateGroupForm.reset()
      el('newGroupType').value = 'school'
      el('newSchoolName').value = 'BASIS Phoenix Primary'
      el('newAcademicYear').value = '2026-27'
      el('newDropTime').value = '07:00'
      el('newPickupTime').value = '15:35'
      el('newAutoCompleteMinutes').value = '60'
      qsa('input[name="newServiceWeekday"]').forEach(input => { input.checked = true })
      await refreshAll()
      navigate('groups')
    }, 'Private group created — calendar upload is optional')
  }, { capture: true })
}

// ---------------------------------------------------------------------------
// Current-state refresh and Realtime awareness
// ---------------------------------------------------------------------------

let kcpRealtimeChannel = null
let kcpSubscribedGroupId = null
let kcpRealtimeRefreshTimer = null

const kcpPreviousLoadWorkspace = loadWorkspace
loadWorkspace = async function () {
  if (state.activeGroup?.id) {
    const { error } = await supabase.rpc('kcp_sync_group_lifecycle', {
      p_group_id: state.activeGroup.id
    })
    if (error && !/Could not find the function|schema cache/i.test(error.message || '')) {
      console.warn('KCP lifecycle refresh:', error.message || error)
    }
  }

  await kcpPreviousLoadWorkspace()
  await kcpSubscribeToActiveGroup()
}

async function kcpSubscribeToActiveGroup() {
  const groupId = state.activeGroup?.id || null
  if (groupId === kcpSubscribedGroupId) return

  if (kcpRealtimeChannel) {
    await supabase.removeChannel(kcpRealtimeChannel)
    kcpRealtimeChannel = null
  }
  kcpSubscribedGroupId = groupId
  if (!groupId) return

  const scheduleRefresh = () => {
    clearTimeout(kcpRealtimeRefreshTimer)
    kcpRealtimeRefreshTimer = setTimeout(async () => {
      try {
        await kcpPreviousLoadWorkspace()
        renderAll()
      } catch (error) {
        console.warn('Realtime refresh failed:', error.message || error)
      }
    }, 350)
  }

  const tables = [
    'kcp_trips',
    'kcp_cover_requests',
    'kcp_points_ledger',
    'kcp_constraint_requests',
    'kcp_memberships',
    'kcp_invitations'
  ]

  let channel = supabase.channel(`kcp-group-${groupId}`)
  for (const table of tables) {
    channel = channel.on(
      'postgres_changes',
      { event: '*', schema: 'public', table, filter: `group_id=eq.${groupId}` },
      scheduleRefresh
    )
  }
  kcpRealtimeChannel = channel.subscribe()
}

// ---------------------------------------------------------------------------
// Nearest-trip ordering and focused home cards
// ---------------------------------------------------------------------------

activeTrips = function () {
  return upcomingActionableTrips(state.trips, new Date())
}

renderSchedule = function () {
  const list = el('scheduleList')
  if (!state.activeGroup) {
    list.innerHTML = empty('Choose a group to see its schedule.')
    return
  }

  const trips = orderTripsByProximity(state.trips, new Date()).slice(0, 120)
  if (!trips.length) {
    list.innerHTML = empty('No schedule is published yet. An admin can generate recurring trips without a calendar, or optionally upload exception dates first.')
    return
  }

  list.innerHTML = '<p class="schedule-order-note">Nearest current or upcoming trip is shown first. Recent unresolved and completed trips follow.</p>' + trips.map(tripRow).join('')
}

renderFocusTrip = function (container, trip, label, symbol) {
  if (!trip) {
    container.className = `${container.id.includes('Drop') ? 'trip-focus-card morning' : 'trip-focus-card pickup'} empty`
    container.innerHTML = `<div class="trip-symbol">${symbol}</div><div class="trip-label">${label}</div><h2>No upcoming trip</h2><p class="meta">An admin can publish a recurring schedule with or without a calendar.</p>`
    return
  }

  container.className = container.id.includes('Drop') ? 'trip-focus-card morning' : 'trip-focus-card pickup'
  const accepted = acceptedCoverForTrip(state.coverRequests, trip.id)
  const acceptedText = coverAcceptedLabel(accepted, state.memberships)
  container.innerHTML = `
    <div class="trip-symbol">${symbol}</div>
    <div class="trip-label">${label}</div>
    <div class="driver">${escapeHTML(driverName(trip))}</div>
    <div class="trip-time">${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</div>
    <div class="countdown">${countdownText(trip)}</div>
    ${statusPill(trip.status)}
    ${acceptedText ? `<div class="cover-acceptance">✓ ${escapeHTML(acceptedText)}</div>` : ''}
    <div style="height:12px"></div>
    <button class="primary-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View trip</button>`
}

// ---------------------------------------------------------------------------
// Cover details and trip actions
// ---------------------------------------------------------------------------

renderVolunteers = function () {
  const list = el('volunteerList')
  if (!state.activeGroup) {
    list.innerHTML = empty('Choose a group first.')
    return
  }

  const open = state.coverRequests.filter(request => request.status === 'open')
  const accepted = state.coverRequests
    .filter(request => request.status === 'accepted')
    .sort((a, b) => new Date(b.accepted_at || b.created_at) - new Date(a.accepted_at || a.created_at))
    .slice(0, 20)

  const sections = []
  if (open.length) {
    sections.push('<div class="card"><h2>Open requests</h2><p class="meta">The first eligible parent who accepts becomes the volunteer driver.</p></div>')
    sections.push(open.map(request => {
      const trip = state.trips.find(item => item.id === request.trip_id)
      if (!trip) return ''
      const requestedBy = memberName(request.requested_by)
      const canVolunteer = trip.scheduled_driver_id !== state.session.user.id
      return `<article class="trip-row"><div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div><div><h3>${kindLabel(trip.kind)}</h3><p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p><p>Requested by ${escapeHTML(requestedBy)} — ${escapeHTML(request.note || 'No note')}</p></div><div class="button-row">${canVolunteer ? `<button class="action-button green" data-action="accept-cover" data-request-id="${request.id}" type="button">Volunteer · 20 pts</button>` : '<span class="badge">Your request</span>'}</div></article>`
    }).join(''))
  }

  if (accepted.length) {
    sections.push('<div class="card"><h2>Accepted coverage</h2><p class="meta">The requested driver and all group members can see who accepted.</p></div>')
    sections.push(accepted.map(request => {
      const trip = state.trips.find(item => item.id === request.trip_id)
      if (!trip) return ''
      return `<article class="trip-row"><div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div><div><h3>${kindLabel(trip.kind)} · ${escapeHTML(driverName(trip))}</h3><p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p><div class="cover-acceptance">✓ ${escapeHTML(coverAcceptedLabel(request, state.memberships))}</div></div><div class="button-row"><button class="action-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View trip</button></div></article>`
    }).join(''))
  }

  list.innerHTML = sections.join('') || empty('No open or recently accepted volunteer requests.')
}

tripRow = function (trip) {
  const currentUser = state.session.user.id
  const driverId = trip.actual_driver_id || trip.scheduled_driver_id
  const isDriver = driverId === currentUser
  const openRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'open')
  const acceptedRequest = acceptedCoverForTrip(state.coverRequests, trip.id)
  const acceptedText = coverAcceptedLabel(acceptedRequest, state.memberships)
  const gate = tripStartGate(trip, new Date())
  const buttons = [`<button class="action-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View</button>`]

  if (trip.status === 'scheduled' && trip.scheduled_driver_id === currentUser) {
    buttons.push(`<button class="action-button orange" data-action="request-cover" data-trip-id="${trip.id}" type="button">Need cover</button>`)
  }
  if (openRequest && trip.scheduled_driver_id !== currentUser) {
    buttons.push(`<button class="action-button green" data-action="accept-cover" data-request-id="${openRequest.id}" type="button">Volunteer</button>`)
  }
  if (isDriver && ['scheduled', 'cover_accepted'].includes(trip.status)) {
    buttons.push(`<button class="action-button green" data-action="start-trip" data-trip-id="${trip.id}" type="button" ${gate.allowed ? '' : 'disabled'}>Start</button>`)
    if (!gate.allowed) buttons.push(`<p class="trip-gate-note">${escapeHTML(gate.reason)}</p>`)
  }
  if (isDriver && trip.status === 'in_progress') {
    buttons.push(`<button class="action-button green" data-action="complete-trip" data-trip-id="${trip.id}" type="button">Complete</button>`)
  }

  return `<article class="trip-row"><div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div><div><h3>${kindLabel(trip.kind)} · ${escapeHTML(driverName(trip))}</h3><p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p><p>${statusPill(trip.status)} ${trip.volunteer_assignment ? '<span class="badge">Volunteer · 20 pts</span>' : ''}</p>${acceptedText ? `<div class="cover-acceptance">✓ ${escapeHTML(acceptedText)}</div>` : ''}${trip.notes ? `<p>${escapeHTML(trip.notes)}</p>` : ''}</div><div class="button-row">${buttons.join('')}</div></article>`
}

showTrip = function (tripId) {
  const trip = state.trips.find(item => item.id === tripId)
  if (!trip) return

  const driverId = trip.actual_driver_id || trip.scheduled_driver_id
  const isDriver = driverId === state.session.user.id
  const openRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'open')
  const acceptedRequest = acceptedCoverForTrip(state.coverRequests, trip.id)
  const acceptedText = coverAcceptedLabel(acceptedRequest, state.memberships)
  const gate = tripStartGate(trip, new Date())
  const actions = []

  if (trip.status === 'scheduled' && trip.scheduled_driver_id === state.session.user.id) {
    actions.push(`<button class="action-button orange" data-action="request-cover" data-trip-id="${trip.id}" type="button">Request cover</button>`)
  }
  if (openRequest && trip.scheduled_driver_id !== state.session.user.id) {
    actions.push(`<button class="action-button green" data-action="accept-cover" data-request-id="${openRequest.id}" type="button">Volunteer · 20 points</button>`)
  }
  if (isDriver && ['scheduled', 'cover_accepted'].includes(trip.status)) {
    actions.push(`<button class="primary-button" data-action="start-trip" data-trip-id="${trip.id}" type="button" ${gate.allowed ? '' : 'disabled'}>Start trip</button>`)
    if (!gate.allowed) actions.push(`<p class="trip-gate-note">${escapeHTML(gate.reason)}</p>`)
  }
  if (isDriver && trip.status === 'in_progress') {
    actions.push(`<button class="primary-button" data-action="complete-trip" data-trip-id="${trip.id}" type="button">Complete trip</button>`)
  }

  const childRows = (trip.child_names || []).map(child => {
    const slot = state.rosterSlots?.find(item => item.child_name === child)
    return `<div class="trip-child-row"><strong>${escapeHTML(child)}</strong>${slot ? `<span class="badge">Tag ${escapeHTML(slot.pickup_tag)}</span>` : ''}</div>`
  }).join('') || '<p class="meta">No children listed.</p>'

  const scheduledDriver = trip.scheduled_driver_name || memberName(trip.scheduled_driver_id)
  const autoMinutes = state.activeGroup?.auto_complete_after_minutes || 60
  el('tripDialogContent').innerHTML = `
    <div class="trip-modal-shell">
      <div class="trip-modal-header">
        <div><span class="eyebrow">TRIP DETAILS</span><h2>${kindLabel(trip.kind)}</h2><p class="meta">${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p></div>
        <button class="close-button" onclick="document.getElementById('tripDialog').close()" aria-label="Close">×</button>
      </div>
      <div class="trip-modal-driver"><small>CURRENT DRIVER</small><strong>${escapeHTML(driverName(trip))}</strong></div>
      <div class="trip-detail-grid">
        <div class="trip-detail-item"><small>Status</small>${statusPill(trip.status)}</div>
        <div class="trip-detail-item"><small>Originally assigned</small><strong>${escapeHTML(scheduledDriver)}</strong></div>
        <div class="trip-detail-item"><small>Schedule version</small><strong>${trip.schedule_version}</strong></div>
        <div class="trip-detail-item"><small>Countdown</small><strong>${escapeHTML(countdownText(trip))}</strong></div>
      </div>
      ${acceptedText ? `<div class="trip-modal-section"><h3>Coverage</h3><div class="cover-acceptance">✓ ${escapeHTML(acceptedText)}</div>${acceptedRequest?.note ? `<p class="meta">${escapeHTML(acceptedRequest.note)}</p>` : ''}</div>` : ''}
      <div class="trip-modal-section"><h3>Children</h3><div class="trip-child-list">${childRows}</div></div>
      ${trip.notes ? `<div class="trip-modal-section"><h3>Notes</h3><p class="meta">${escapeHTML(trip.notes)}</p></div>` : ''}
      <p class="trip-auto-note">Manual start opens 10 minutes before the scheduled time. If no action is taken, KCP automatically starts the trip at the scheduled time and completes it after ${autoMinutes} minutes, awarding the appropriate points.</p>
      <div class="trip-action-stack">${actions.join('') || '<span class="meta">No action is available for your role and the current trip status.</span>'}</div>
    </div>`
  el('tripDialog').showModal()
}

// ---------------------------------------------------------------------------
// Calendar is optional; recurring group dates remain usable without it.
// ---------------------------------------------------------------------------

const kcpPreviousRenderCalendar = renderCalendar
renderCalendar = function () {
  if (!state.activeGroup || state.calendar) {
    kcpPreviousRenderCalendar()
    return
  }

  el('calendarAnalytics').innerHTML = ''
  const start = state.activeGroup.schedule_start_date ? formatDate(state.activeGroup.schedule_start_date) : 'Not set'
  const end = state.activeGroup.schedule_end_date ? formatDate(state.activeGroup.schedule_end_date) : 'Not set'
  el('calendarActions').innerHTML = `
    <h2>Optional calendar</h2>
    <p class="meta">This ${escapeHTML(capitalize(state.activeGroup.group_kind || 'carpool'))} group can publish recurring trips from ${escapeHTML(start)} through ${escapeHTML(end)} without uploading a calendar.</p>
    <p class="optional-calendar-note">Upload a calendar only when you want holidays, closures, tournaments, recital days or other exceptions removed or highlighted automatically.</p>
    <div class="button-row">
      ${isAdmin() ? '<button class="primary-small" data-action="generate-schedule" type="button">Generate recurring schedule</button>' : ''}
      ${isAdmin() ? '<label class="secondary-button" style="display:inline-flex;align-items:center">Choose optional PDF<input id="calendarFile" type="file" accept="application/pdf" style="display:none"></label><button class="secondary-button" data-action="upload-calendar" type="button">Upload selected calendar</button>' : ''}
    </div>`
  el('calendarTimeline').innerHTML = ''
}

const kcpPreviousRenderGroupAdminPanel = renderGroupAdminPanel
renderGroupAdminPanel = function () {
  kcpPreviousRenderGroupAdminPanel()
  if (!state.activeGroup) return

  const kind = capitalize(state.activeGroup.group_kind || 'school')
  const dates = state.activeGroup.schedule_start_date && state.activeGroup.schedule_end_date
    ? `${formatDate(state.activeGroup.schedule_start_date)} – ${formatDate(state.activeGroup.schedule_end_date)}`
    : 'Recurring dates not configured'
  const card = `<div class="card"><h2>Carpool configuration</h2><div class="trip-detail-grid"><div class="trip-detail-item"><small>Type</small><strong>${escapeHTML(kind)}</strong></div><div class="trip-detail-item"><small>Date range</small><strong>${escapeHTML(dates)}</strong></div><div class="trip-detail-item"><small>Drop / outbound</small><strong>${escapeHTML(String(state.activeGroup.drop_time || '—').slice(0,5))}</strong></div><div class="trip-detail-item"><small>Pickup / return</small><strong>${escapeHTML(String(state.activeGroup.pickup_time || '—').slice(0,5))}</strong></div></div><p class="meta" style="margin-bottom:0">Calendar: <strong>${state.calendar ? 'Uploaded' : 'Optional — not uploaded'}</strong> · Auto-complete: ${state.activeGroup.auto_complete_after_minutes || 60} minutes</p></div>`
  el('groupAdminPanel').insertAdjacentHTML('afterbegin', card)
}

setInterval(() => {
  if (!state.activeGroup || !state.profile) return
  renderHome()
  if (state.currentView === 'schedule') renderSchedule()
}, 30000)
