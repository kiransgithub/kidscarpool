// Database-driven production presentation.
//
// The PWA must not know any real parent, child, group, destination, calendar,
// or schedule. Those values come from Supabase. This final layer also adapts
// controls to the current membership role and participant driving permission.

const kcpDatabasePreviousRenderAll = renderAll
const kcpDatabasePreviousRenderConstraints = renderConstraints
const kcpDatabasePreviousRenderVolunteers = renderVolunteers
const kcpDatabasePreviousShowTrip = showTrip
const kcpDatabasePreviousInitializeScheduleDraft = initializeScheduleDraft

function kcpCurrentMembership() {
  return state.memberships.find(member =>
    member.user_id === state.session?.user?.id && member.status === 'active'
  ) || null
}

function kcpCurrentParticipant() {
  const userId = state.session?.user?.id
  return (state.scheduleBuilder?.participants || []).find(participant =>
    participant.user_id === userId && participant.status === 'active'
  ) || null
}

function kcpAccess() {
  const membership = kcpCurrentMembership()
  const participant = kcpCurrentParticipant()
  const role = membership?.role || participant?.role || 'viewer'
  return {
    role,
    isOwner: role === 'owner',
    isAdmin: role === 'owner' || role === 'admin',
    isViewer: role === 'viewer',
    canDrive: role !== 'viewer' && (participant?.can_drive ?? true)
  }
}

function kcpTripLeg(trip) {
  if (trip?.leg_type === 'outbound' || trip?.leg_type === 'return') return trip.leg_type
  return trip?.kind === 'afternoon_pickup' ? 'return' : 'outbound'
}

function kcpPlanLabels() {
  const plan = state.scheduleBuilder?.plan || {}
  return {
    outbound: plan.outbound_label || 'Outbound',
    return: plan.return_label || 'Return'
  }
}

function kcpTripLabel(trip) {
  if (trip?.display_label) return trip.display_label
  return kcpPlanLabels()[kcpTripLeg(trip)]
}

function kcpGroupDestination(group = state.activeGroup) {
  return group?.destination_name || group?.school_name || ''
}

function kcpGroupTerm(group = state.activeGroup) {
  return group?.term_label || group?.academic_year || ''
}

renderAll = function () {
  kcpDatabasePreviousRenderAll()
  kcpApplyRoleAwareNavigation()
  kcpNormalizeGenericLabels()
}

renderHome = function () {
  if (!state.activeGroup) {
    el('homeAlerts').innerHTML = '<h2>Account ready</h2><p class="meta">Create a group or accept an invitation to begin.</p>'
    return
  }

  const upcoming = activeTrips().filter(trip =>
    ['scheduled', 'coverage_needed', 'cover_requested', 'cover_accepted', 'in_progress'].includes(trip.status)
  )
  const nextOutbound = upcoming.find(trip => kcpTripLeg(trip) === 'outbound')
  const nextReturn = upcoming.find(trip => kcpTripLeg(trip) === 'return')
  const labels = kcpPlanLabels()

  renderFocusTrip(el('nextDropCard'), nextOutbound, `NEXT ${labels.outbound.toUpperCase()}`, '↗')
  renderFocusTrip(el('nextPickupCard'), nextReturn, `NEXT ${labels.return.toUpperCase()}`, '↙')

  const pending = state.constraintRequests.filter(request => request.status === 'pending').length
  const openCovers = state.coverRequests.filter(request => request.status === 'open').length
  const access = kcpAccess()
  el('homeAlerts').innerHTML = `
    <h2>Group overview</h2>
    <div class="metric-row">
      <div class="metric"><strong>${state.memberships.filter(member => member.status === 'active').length}</strong><small>Members</small></div>
      <div class="metric"><strong>${openCovers}</strong><small>Open covers</small></div>
      <div class="metric"><strong>${pending}</strong><small>Pending changes</small></div>
    </div>
    <p class="meta" style="margin-bottom:0">Signed in as <strong>${escapeHTML(capitalize(access.role))}</strong>. Published schedule version ${state.activeGroup.current_schedule_version || 0}.</p>`
}

renderFocusTrip = function (container, trip, label, symbol) {
  const leg = container.id.includes('Drop') ? 'outbound' : 'return'
  container.className = `trip-focus-card ${leg === 'outbound' ? 'morning' : 'pickup'}`

  if (!trip) {
    container.classList.add('empty')
    container.innerHTML = `<div class="trip-symbol">${symbol}</div><div class="trip-label">${escapeHTML(label)}</div><h2>No upcoming ride</h2><p class="meta">An Owner or Admin can publish a recurring schedule.</p>`
    return
  }

  const accepted = acceptedCoverForTrip(state.coverRequests, trip.id)
  const acceptedText = coverAcceptedLabel(accepted, state.memberships)
  container.innerHTML = `
    <div class="trip-symbol">${symbol}</div>
    <div class="trip-label">${escapeHTML(kcpTripLabel(trip).toUpperCase())}</div>
    <div class="driver">${escapeHTML(driverName(trip))}</div>
    <div class="trip-time">${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label || formatDateTime(trip.scheduled_time))}</div>
    <div class="countdown">${countdownText(trip)}</div>
    ${statusPill(trip.status)}
    ${acceptedText ? `<div class="cover-acceptance">✓ ${escapeHTML(acceptedText)}</div>` : ''}
    <div style="height:12px"></div>
    <button class="primary-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View ride</button>`
}

tripRow = function (trip) {
  const access = kcpAccess()
  const currentUser = state.session?.user?.id
  const driverId = trip.actual_driver_id || trip.scheduled_driver_id
  const isDriver = driverId === currentUser
  const openRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'open')
  const acceptedRequest = acceptedCoverForTrip(state.coverRequests, trip.id)
  const acceptedText = coverAcceptedLabel(acceptedRequest, state.memberships)
  const gate = tripStartGate(trip, new Date())
  const buttons = [`<button class="action-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View</button>`]

  if (!access.isViewer && trip.status === 'scheduled' && trip.scheduled_driver_id === currentUser) {
    buttons.push(`<button class="action-button orange" data-action="request-cover" data-trip-id="${trip.id}" type="button">Need cover</button>`)
  }
  if (access.canDrive && openRequest && trip.scheduled_driver_id !== currentUser) {
    buttons.push(`<button class="action-button green" data-action="accept-cover" data-request-id="${openRequest.id}" type="button">Volunteer</button>`)
  }
  if (access.canDrive && isDriver && ['scheduled', 'cover_accepted'].includes(trip.status)) {
    buttons.push(`<button class="action-button green" data-action="start-trip" data-trip-id="${trip.id}" type="button" ${gate.allowed ? '' : 'disabled'}>Start</button>`)
    if (!gate.allowed) buttons.push(`<p class="trip-gate-note">${escapeHTML(gate.reason)}</p>`)
  }
  if (access.canDrive && isDriver && trip.status === 'in_progress') {
    buttons.push(`<button class="action-button green" data-action="complete-trip" data-trip-id="${trip.id}" type="button">Complete</button>`)
  }

  return `<article class="trip-row">
    <div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div>
    <div>
      <h3>${escapeHTML(kcpTripLabel(trip))} · ${escapeHTML(driverName(trip))}</h3>
      <p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label || formatDateTime(trip.scheduled_time))}</p>
      <p>${statusPill(trip.status)} ${trip.volunteer_assignment ? '<span class="badge">Volunteer · 20 pts</span>' : ''}</p>
      ${acceptedText ? `<div class="cover-acceptance">✓ ${escapeHTML(acceptedText)}</div>` : ''}
      ${trip.notes ? `<p>${escapeHTML(trip.notes)}</p>` : ''}
    </div>
    <div class="button-row">${buttons.join('')}</div>
  </article>`
}

showTrip = function (tripId) {
  kcpDatabasePreviousShowTrip(tripId)
  const trip = state.trips.find(item => item.id === tripId)
  if (!trip) return
  const title = el('tripDialogContent')?.querySelector('.trip-modal-header h2')
  if (title) title.textContent = kcpTripLabel(trip)
}

renderVolunteers = function () {
  if (!kcpAccess().canDrive) {
    el('volunteerList').innerHTML = empty('This membership is read-only and cannot accept driving assignments.')
    return
  }
  kcpDatabasePreviousRenderVolunteers()
}

renderConstraints = function () {
  const card = el('constraintsCard')
  const access = kcpAccess()
  if (!state.activeGroup) {
    kcpDatabasePreviousRenderConstraints()
    return
  }
  if (!access.canDrive) {
    card.innerHTML = '<h2>Ride availability</h2><p class="meta">This membership is read-only. Owners and Admins can change the role or driving permission.</p>'
    return
  }
  kcpDatabasePreviousRenderConstraints()
}

renderCalendar = function () {
  const analytics = el('calendarAnalytics')
  const actions = el('calendarActions')
  const timeline = el('calendarTimeline')
  if (!state.activeGroup) {
    analytics.innerHTML = ''
    actions.innerHTML = '<p class="meta">Choose a group first.</p>'
    timeline.innerHTML = ''
    return
  }

  const access = kcpAccess()
  const destination = kcpGroupDestination() || state.activeGroup.name
  const term = kcpGroupTerm()

  if (!state.calendar) {
    analytics.innerHTML = ''
    actions.innerHTML = `
      <h2>Calendar and exception dates</h2>
      <p class="meta">A calendar is optional. The published recurring schedule remains active without one.</p>
      ${access.isAdmin ? `
        <label>Optional calendar PDF<input id="calendarFile" type="file" accept="application/pdf"></label>
        <button class="primary-button" data-action="upload-calendar" type="button">Store calendar file</button>
        <p class="meta">Uploading stores the source file and metadata. Add closures or changed times as schedule exceptions; KCP does not invent dates from an unparsed PDF.</p>` : '<p class="meta">No calendar file has been registered.</p>'}`
    timeline.innerHTML = ''
    return
  }

  const a = state.analytics || {}
  const metric = (value, label) => `<div class="analytics-card"><strong>${value ?? 0}</strong><span>${label}</span></div>`
  analytics.innerHTML = [
    metric(a.instructional_days, 'Active weekdays'),
    metric(a.holiday_periods, 'Closure periods'),
    metric(a.long_weekends, 'Extended breaks'),
    metric(a.early_pickups, 'Changed-time days'),
    metric(a.no_late_bird_days, 'Special coverage days'),
    metric(a.upcoming_event_count, 'Upcoming events')
  ].join('')
  actions.innerHTML = `<h2>${escapeHTML(destination)}</h2><p class="meta">${escapeHTML(term)}${term ? ' · ' : ''}registered ${formatDateTime(state.calendar.uploaded_at)}</p><p><strong>Next:</strong> ${escapeHTML(a.next_event_title || 'No upcoming event')} ${a.next_event_date ? `on ${formatDate(a.next_event_date)}` : ''}</p>`
  timeline.innerHTML = state.calendarEvents.map(item => `<article class="timeline-row"><div><strong>${escapeHTML(item.title)}</strong><span class="meta">${escapeHTML(typeLabel(item.event_type))}${item.notes ? ` · ${escapeHTML(item.notes)}` : ''}</span></div><div class="date">${formatRange(item.start_date, item.end_date)}</div></article>`).join('') || '<p class="meta">The source file is stored. No structured exception dates have been added.</p>'
}

uploadCalendar = async function () {
  const file = el('calendarFile')?.files?.[0]
  if (!file) throw new Error('Choose a PDF first.')
  if (file.type !== 'application/pdf') throw new Error('The calendar source must be a PDF.')
  if (!state.activeGroup || !kcpAccess().isAdmin) throw new Error('Owner or Admin role required.')

  await runAction(async () => {
    const hash = await sha256(file)
    const path = `${state.activeGroup.id}/${hash}.pdf`
    const { error: uploadError } = await supabase.storage
      .from('kcp-school-calendars')
      .upload(path, file, { upsert: false, contentType: 'application/pdf' })
    if (uploadError && !/already exists|duplicate/i.test(uploadError.message || '')) throw uploadError

    const destination = kcpGroupDestination() || state.activeGroup.name
    const term = kcpGroupTerm() || 'Current term'
    const key = state.activeGroup.school_key || slug(destination)
    const { error } = await supabase.rpc('kcp_register_calendar', {
      p_group_id: state.activeGroup.id,
      p_school_key: key,
      p_school_name: destination,
      p_academic_year: term,
      p_source_name: file.name,
      p_source_sha256: hash,
      p_source_file_size: file.size,
      p_storage_path: path,
      p_events: []
    })
    if (error) throw error
    await loadWorkspace()
    renderAll()
  }, 'Calendar source stored')
}

initializeScheduleDraft = function () {
  kcpDatabasePreviousInitializeScheduleDraft()
  const builder = state.scheduleBuilder || emptyScheduleBuilderState()
  const plan = builder.plan || {}
  const group = state.activeGroup || {}

  // A brand-new group has no inferred day or clock time. The administrator
  // explicitly enables days and enters times in the weekly matrix.
  if (!(builder.sessions || []).length) scheduleDraftSessions = []

  el('schedulePlanName').value = plan.name || `${group.name || 'Group'} schedule`
  el('scheduleStartsOn').value = plan.starts_on || ''
  el('scheduleEndsOn').value = plan.ends_on || ''
  el('scheduleOutboundLabel').value = plan.outbound_label || 'Outbound'
  el('scheduleReturnLabel').value = plan.return_label || 'Return'
  el('scheduleAutoComplete').value = plan.auto_complete_after_minutes || 60
}

// New days do not inherit school-oriented clock times. Empty values force the
// administrator to enter the actual schedule before previewing.
defaultWeeklyTime = function () {
  return ''
}

function kcpApplyRoleAwareNavigation() {
  const access = kcpAccess()
  const volunteerButton = document.querySelector('[data-nav="volunteers"]')
  if (volunteerButton) volunteerButton.classList.toggle('hidden', !access.canDrive)

  document.querySelectorAll('[data-action="open-invite"], [data-action="open-generic-schedule"], [data-action="generate-schedule"], [data-action="upload-calendar"]')
    .forEach(control => control.classList.toggle('hidden', !access.isAdmin))

  document.body.dataset.kcpRole = access.role
  document.body.dataset.kcpCanDrive = String(access.canDrive)
}

function kcpNormalizeGenericLabels() {
  document.querySelectorAll('[data-nav="calendar"] small').forEach(node => { node.textContent = 'Calendar' })
  document.querySelectorAll('[data-nav="volunteers"] small').forEach(node => { node.textContent = 'Volunteer' })

  const adminPanel = el('groupAdminPanel')
  if (adminPanel) {
    adminPanel.querySelectorAll('[data-nav="calendar"]').forEach(button => { button.textContent = 'Calendar & exceptions' })
    adminPanel.querySelectorAll('[data-action="generate-schedule"]').forEach(button => { button.textContent = 'Configure schedule' })
  }
}

// Use the device timezone for a brand-new group instead of a location-specific
// default. Existing groups always retain the timezone stored in Supabase.
const kcpGenericDialogObserver = genericGroupDialog ? new MutationObserver(() => {
  if (!genericGroupDialog.open) return
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  const select = el('genericTimezone')
  if (!select) return
  if (![...select.options].some(option => option.value === timezone)) {
    select.add(new Option(timezone, timezone))
  }
  if (!state.activeGroup) select.value = timezone
}) : null
kcpGenericDialogObserver?.observe(genericGroupDialog, { attributes: true, attributeFilter: ['open'] })
