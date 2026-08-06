
function renderHome() {
  if (!state.activeGroup) {
    el('homeAlerts').innerHTML = '<h2>Pilot status</h2><p class="meta">Create a private group or accept an invitation to begin.</p>'
    return
  }
  const upcoming = activeTrips().filter(trip => ['scheduled', 'coverage_needed', 'cover_requested', 'cover_accepted', 'in_progress'].includes(trip.status))
  const nextDrop = upcoming.find(trip => trip.kind === 'morning_drop')
  const nextPickup = upcoming.find(trip => trip.kind === 'afternoon_pickup')
  renderFocusTrip(el('nextDropCard'), nextDrop, 'NEXT MORNING DROP', '☀')
  renderFocusTrip(el('nextPickupCard'), nextPickup, 'NEXT AFTERNOON PICKUP', '☾')

  const pending = state.constraintRequests.filter(request => request.status === 'pending').length
  const openCovers = state.coverRequests.filter(request => request.status === 'open').length
  const role = currentMembership()?.role || 'parent'
  el('homeAlerts').innerHTML = `
    <h2>Group pulse</h2>
    <div class="metric-row">
      <div class="metric"><strong>${state.memberships.filter(m => m.status === 'active').length}</strong><small>Parents</small></div>
      <div class="metric"><strong>${openCovers}</strong><small>Open covers</small></div>
      <div class="metric"><strong>${pending}</strong><small>Constraint requests</small></div>
    </div>
    <p class="meta" style="margin-bottom:0">You are a <strong>${escapeHTML(capitalize(role))}</strong> in this group. Schedule version ${state.activeGroup.current_schedule_version || 0} is active.</p>`
}

function renderFocusTrip(container, trip, label, symbol) {
  if (!trip) {
    container.className = `${container.id.includes('Drop') ? 'trip-focus-card morning' : 'trip-focus-card pickup'} empty`
    container.innerHTML = `<div class="trip-symbol">${symbol}</div><div class="trip-label">${label}</div><h2>No published trip</h2><p class="meta">An admin can upload the calendar and generate the schedule.</p>`
    return
  }
  container.classList.remove('empty')
  const driver = driverName(trip)
  container.innerHTML = `
    <div class="trip-symbol">${symbol}</div>
    <div class="trip-label">${label}</div>
    <div class="driver">${escapeHTML(driver)}</div>
    <div class="trip-time">${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</div>
    <div class="countdown">${countdownText(trip)}</div>
    ${statusPill(trip.status)}
    <div style="height:12px"></div>
    <button class="primary-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View trip</button>`
}

function renderGroups() {
  const list = el('groupsList')
  if (!state.groups.length) {
    list.innerHTML = '<div class="empty-card"><h2>No groups yet</h2><p>Create the first private group, then invite other parents.</p></div>'
    el('groupAdminPanel').classList.add('hidden')
    return
  }

  list.innerHTML = state.groups.map(group => {
    const active = state.activeGroup?.id === group.group_id
    return `<article class="group-card ${active ? 'active' : ''}">
      <div class="group-card-head"><div><h2>${escapeHTML(group.group_name)}</h2><div class="meta">${escapeHTML(group.school_name)} · ${escapeHTML(group.academic_year)}</div></div>${active ? '<span class="status-pill">Active</span>' : `<button class="action-button" data-action="switch-group" data-group-id="${group.group_id}" type="button">Switch</button>`}</div>
      <div class="button-row"><span class="role-pill">${escapeHTML(capitalize(group.role))}</span><span class="badge">${escapeHTML(group.group_code)}</span></div>
      <div class="metric-row"><div class="metric"><strong>${group.active_member_count}</strong><small>Members</small></div><div class="metric"><strong>${group.pending_invitation_count}</strong><small>Invites</small></div><div class="metric"><strong>${group.current_schedule_version}</strong><small>Schedule v</small></div></div>
    </article>`
  }).join('')

  renderGroupAdminPanel()
}

function renderGroupAdminPanel() {
  const panel = el('groupAdminPanel')
  if (!state.activeGroup) { panel.classList.add('hidden'); return }
  panel.classList.remove('hidden')
  const admin = isAdmin()
  const pendingInvites = state.invitations.filter(inv => inv.status === 'pending')
  panel.innerHTML = `
    <div class="card">
      <h2>${escapeHTML(state.activeGroup.name)} administration</h2>
      <p class="meta">${escapeHTML(state.activeGroup.code)} · ${escapeHTML(capitalize(currentMembership()?.role || 'parent'))}</p>
      <div class="button-row">
        ${admin ? '<button class="primary-small" data-action="open-invite" type="button">Invite parent</button>' : ''}
        ${admin ? '<button class="secondary-button" data-action="generate-schedule" type="button">Generate schedule</button>' : ''}
        <button class="secondary-button" data-nav="calendar" type="button">School calendar</button>
      </div>
    </div>
    <div class="card"><h2>Members and admins</h2>${state.memberships.map(member => memberRow(member, admin)).join('')}</div>
    ${admin ? `<div class="card"><h2>Invitation history</h2>${pendingInvites.length ? pendingInvites.map(invitationRow).join('') : '<p class="meta">No pending invitations.</p>'}</div>` : ''}`
}

function memberRow(member, admin) {
  const canChange = admin && member.role !== 'owner' && member.user_id !== state.session.user.id
  return `<div class="timeline-row"><div><strong>${escapeHTML(member.parent_name)}</strong><span class="meta">${escapeHTML(member.child_name)} · Grade ${member.grade}</span></div><div>${canChange ? `<select data-action="change-role" data-user-id="${member.user_id}"><option value="parent" ${member.role === 'parent' ? 'selected' : ''}>Parent</option><option value="admin" ${member.role === 'admin' ? 'selected' : ''}>Admin</option><option value="viewer" ${member.role === 'viewer' ? 'selected' : ''}>Viewer</option></select>` : `<span class="role-pill">${escapeHTML(capitalize(member.role))}</span>`}</div></div>`
}

function invitationRow(invitation) {
  return `<div class="timeline-row"><div><strong>${escapeHTML(invitation.invited_parent_name)}</strong><span class="meta">${escapeHTML(invitation.child_name)} · expires ${formatDateTime(invitation.expires_at)}</span></div><button class="action-button" data-action="share-invite" data-invite-id="${invitation.id}" type="button">Share</button></div>`
}

function renderSchedule() {
  const list = el('scheduleList')
  if (!state.activeGroup) { list.innerHTML = empty('Choose a group to see its schedule.'); return }
  const trips = activeTrips().slice(0, 80)
  if (!trips.length) { list.innerHTML = empty('No schedule has been published. An admin must register the calendar and generate it.'); return }
  list.innerHTML = trips.map(tripRow).join('')
}

function renderVolunteers() {
  const list = el('volunteerList')
  if (!state.activeGroup) { list.innerHTML = empty('Choose a group first.'); return }
  const open = state.coverRequests.filter(request => request.status === 'open')
  if (!open.length) { list.innerHTML = empty('No open volunteer requests right now.'); return }
  list.innerHTML = open.map(request => {
    const trip = state.trips.find(item => item.id === request.trip_id)
    if (!trip) return ''
    const requestedBy = memberName(request.requested_by)
    const canVolunteer = trip.scheduled_driver_id !== state.session.user.id
    return `<article class="trip-row"><div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div><div><h3>${kindLabel(trip.kind)}</h3><p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p><p>Requested by ${escapeHTML(requestedBy)} — ${escapeHTML(request.note || 'No note')}</p></div><div class="button-row">${canVolunteer ? `<button class="action-button green" data-action="accept-cover" data-request-id="${request.id}" type="button">Volunteer · 20 pts</button>` : '<span class="badge">Your request</span>'}</div></article>`
  }).join('')
}

function renderLeaderboard() {
  const list = el('leaderboardList')
  if (!state.activeGroup) { list.innerHTML = empty('Choose a group first.'); return }
  const scores = new Map(state.memberships.filter(m => m.status === 'active').map(m => [m.user_id, { name: m.parent_name, points: 0, regular: 0, volunteer: 0 }]))
  for (const entry of state.points) {
    const row = scores.get(entry.user_id) || { name: memberName(entry.user_id), points: 0, regular: 0, volunteer: 0 }
    row.points += entry.points
    if (entry.reason === 'volunteer_trip') row.volunteer += 1
    else row.regular += 1
    scores.set(entry.user_id, row)
  }
  const ranked = [...scores.values()].sort((a, b) => b.points - a.points || a.name.localeCompare(b.name))
  list.innerHTML = ranked.map((row, index) => `<article class="leader-row"><div class="rank">${index + 1}</div><div><strong>${escapeHTML(row.name)}</strong><div class="meta">${row.regular} scheduled · ${row.volunteer} volunteer</div></div><div class="points">${row.points}</div></article>`).join('') || empty('Complete trips to start the leaderboard.')
}

function renderCalendar() {
  const analytics = el('calendarAnalytics')
  const actions = el('calendarActions')
  const timeline = el('calendarTimeline')
  if (!state.activeGroup) {
    analytics.innerHTML = ''
    actions.innerHTML = '<p class="meta">Choose a group first.</p>'
    timeline.innerHTML = ''
    return
  }

  if (!state.calendar) {
    analytics.innerHTML = ''
    actions.innerHTML = isAdmin() ? `
      <h2>Register authoritative calendar</h2>
      <p class="meta">Only one calendar is allowed for this group, school and academic year. Select the official BASIS Phoenix Primary 2026–27 PDF.</p>
      <label>School calendar PDF<input id="calendarFile" type="file" accept="application/pdf"></label>
      <button class="primary-button" data-action="upload-calendar" type="button">Upload and analyze</button>` : '<h2>School calendar</h2><p class="meta">An admin has not uploaded the authoritative calendar yet.</p>'
    timeline.innerHTML = ''
    return
  }

  const a = state.analytics || {}
  const metric = (value, label) => `<div class="analytics-card"><strong>${value ?? 0}</strong><span>${label}</span></div>`
  analytics.innerHTML = [
    metric(a.instructional_days, 'School days'), metric(a.holiday_periods, 'Holiday periods'),
    metric(a.long_weekends, 'Long weekends'), metric(a.upcoming_long_weekends, 'Upcoming long weekends'),
    metric(a.early_pickups, 'Early pickups'), metric(a.no_late_bird_days, 'No Late Bird days'),
    metric(a.project_week_days, 'Project Week days'), metric(a.longest_break_days, 'Longest break days')
  ].join('')
  actions.innerHTML = `<h2>${escapeHTML(state.calendar.school_name)}</h2><p class="meta">${escapeHTML(state.calendar.academic_year)} · uploaded ${formatDateTime(state.calendar.uploaded_at)}</p><p><strong>Next:</strong> ${escapeHTML(a.next_event_title || 'No upcoming event')} ${a.next_event_date ? `on ${formatDate(a.next_event_date)}` : ''}</p>${isAdmin() ? '<button class="secondary-button" data-action="generate-schedule" type="button">Regenerate from approved constraints</button>' : ''}`
  timeline.innerHTML = state.calendarEvents.map(item => `<article class="timeline-row"><div><strong>${escapeHTML(item.title)}</strong><span class="meta">${escapeHTML(typeLabel(item.event_type))}${item.notes ? ` · ${escapeHTML(item.notes)}` : ''}</span></div><div class="date">${formatRange(item.start_date, item.end_date)}</div></article>`).join('')
}

function renderSettings() {
  el('profileCard').innerHTML = `<h2>Parent profile</h2><p><strong>${escapeHTML(state.profile?.display_name || '')}</strong><br><span class="meta">${escapeHTML(state.profile?.phone || 'No phone stored')} · device-bound pilot account</span></p><button class="secondary-button" data-action="refresh" type="button">Refresh cloud data</button>`
  renderConstraints()
  renderAdminQueue()
  renderAudit()
}

function renderConstraints() {
  const card = el('constraintsCard')
  if (!state.activeGroup) { card.innerHTML = '<h2>Availability</h2><p class="meta">Choose a group first.</p>'; return }
  card.innerHTML = `
    <h2>My drop & pickup availability</h2>
    <p class="meta">Changes create a review request. An owner or admin must approve them before the published schedule changes.</p>
    <h3>Morning drop</h3>${weekButtons('drop', state.constraintDraft.drop)}
    <h3>Afternoon pickup</h3>${weekButtons('pickup', state.constraintDraft.pickup)}
    <label style="margin-top:12px">Notes<textarea id="constraintNotes" rows="3" placeholder="Thursday preferred">${escapeHTML(state.constraintDraft.notes)}</textarea></label>
