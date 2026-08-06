    <button class="primary-button" data-action="submit-constraints" type="button" style="margin-top:12px">Submit update request</button>`
}

function weekButtons(kind, selected) {
  return `<div class="week-grid">${DAY_NAMES.map((name, index) => `<button class="week-toggle ${selected.includes(index + 1) ? 'selected' : ''}" data-action="toggle-weekday" data-kind="${kind}" data-day="${index + 1}" type="button">${name}</button>`).join('')}</div>`
}

function renderAdminQueue() {
  const container = el('adminQueue')
  if (!state.activeGroup || !isAdmin()) { container.innerHTML = ''; return }
  const pending = state.constraintRequests.filter(request => request.status === 'pending')
  if (!pending.length) { container.innerHTML = '<div class="card"><h2>Admin approval queue</h2><p class="meta">No pending constraint requests.</p></div>'; return }
  container.innerHTML = `<div class="card"><h2>Admin approval queue</h2><p class="meta">Review each request before regenerating the schedule.</p></div>` + pending.map(request => {
    const member = state.memberships.find(item => item.user_id === request.user_id)
    return `<article class="group-card"><h2>${escapeHTML(member?.parent_name || 'Parent')}</h2><p class="meta">Drop: ${daysText(request.requested_drop_weekdays)}<br>Pickup: ${daysText(request.requested_pickup_weekdays)}<br>${escapeHTML(request.notes || '')}</p><div class="button-row"><button class="action-button green" data-action="review-constraint" data-request-id="${request.id}" data-decision="approved" type="button">Approve</button><button class="action-button red" data-action="review-constraint" data-request-id="${request.id}" data-decision="rejected" type="button">Reject</button></div></article>`
  }).join('')
}

function renderAudit() {
  const card = el('auditCard')
  if (!state.activeGroup) { card.innerHTML = '<h2>Audit history</h2><p class="meta">Choose a group first.</p>'; return }
  card.innerHTML = `<h2>Immutable audit history</h2><p class="meta">The database prevents audit events from being edited or deleted.</p><div class="audit-list">${state.auditEvents.map(item => `<div class="audit-item"><strong>${escapeHTML(humanize(item.action))}</strong>${formatDateTime(item.occurred_at)} · ${escapeHTML(memberName(item.actor_id))}</div>`).join('') || '<p class="meta">No events recorded yet.</p>'}</div>`
}

function tripRow(trip) {
  const currentUser = state.session.user.id
  const driverId = trip.actual_driver_id || trip.scheduled_driver_id
  const isDriver = driverId === currentUser
  const openRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'open')
  const buttons = [`<button class="action-button" data-action="view-trip" data-trip-id="${trip.id}" type="button">View</button>`]
  if (trip.status === 'scheduled' && trip.scheduled_driver_id === currentUser) buttons.push(`<button class="action-button orange" data-action="request-cover" data-trip-id="${trip.id}" type="button">Need cover</button>`)
  if (openRequest && trip.scheduled_driver_id !== currentUser) buttons.push(`<button class="action-button green" data-action="accept-cover" data-request-id="${openRequest.id}" type="button">Volunteer</button>`)
  if (isDriver && ['scheduled', 'cover_accepted'].includes(trip.status)) buttons.push(`<button class="action-button green" data-action="start-trip" data-trip-id="${trip.id}" type="button">Start</button>`)
  if (isDriver && trip.status === 'in_progress') buttons.push(`<button class="action-button green" data-action="complete-trip" data-trip-id="${trip.id}" type="button">Complete</button>`)
  return `<article class="trip-row"><div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div><div><h3>${kindLabel(trip.kind)} · ${escapeHTML(driverName(trip))}</h3><p>${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p><p>${statusPill(trip.status)} ${trip.volunteer_assignment ? '<span class="badge">Volunteer · 20 pts</span>' : ''}</p>${trip.notes ? `<p>${escapeHTML(trip.notes)}</p>` : ''}</div><div class="button-row">${buttons.join('')}</div></article>`
}

async function handleDelegatedClick(event) {
  const button = event.target.closest('[data-action], [data-nav]')
  if (!button) return
  if (button.dataset.nav) { navigate(button.dataset.nav); return }
  const action = button.dataset.action

  try {
    if (action === 'refresh') await runAction(refreshAll, 'Cloud data refreshed')
    if (action === 'switch-group') await switchGroup(button.dataset.groupId)
    if (action === 'open-invite') el('inviteDialog').showModal()
    if (action === 'share-invite') await shareInvitation(state.invitations.find(inv => inv.id === button.dataset.inviteId))
    if (action === 'generate-schedule') await generateSchedule()
    if (action === 'upload-calendar') await uploadCalendar()
    if (action === 'toggle-weekday') toggleWeekday(button.dataset.kind, Number(button.dataset.day))
    if (action === 'submit-constraints') await submitConstraints()
    if (action === 'review-constraint') await reviewConstraint(button.dataset.requestId, button.dataset.decision)
    if (action === 'request-cover') await requestCover(button.dataset.tripId)
    if (action === 'accept-cover') await acceptCover(button.dataset.requestId)
    if (action === 'start-trip') await tripAction('kcp_start_trip', button.dataset.tripId, 'Trip started')
    if (action === 'complete-trip') await tripAction('kcp_complete_trip', button.dataset.tripId, 'Trip completed and points awarded')
    if (action === 'view-trip') showTrip(button.dataset.tripId)
  } catch (error) {
    toast(error.message || String(error), true)
  }
}

document.addEventListener('change', async event => {
  const select = event.target.closest('[data-action="change-role"]')
  if (!select || !state.activeGroup) return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_set_member_role', {
      p_group_id: state.activeGroup.id,
      p_member_user_id: select.dataset.userId,
      p_role: select.value
    })
    if (error) throw error
    await loadWorkspace(); renderAll()
  }, 'Member role updated')
})

async function switchGroup(groupId) {
  localStorage.setItem(ACTIVE_GROUP_KEY, groupId)
  state.activeGroup = await fetchGroup(groupId)
  await loadWorkspace()
  renderAll()
  navigate('home')
  toast(`Switched to ${state.activeGroup.name}`)
}

async function generateSchedule() {
  if (!state.activeGroup) return
  await runAction(async () => {
    const { data, error } = await supabase.rpc('kcp_generate_schedule', {
      p_group_id: state.activeGroup.id,
      p_reason: 'Published from approved parent constraints'
    })
    if (error) throw error
    await refreshAll()
    navigate('home')
    return data
  }, 'Schedule generated and published')
}

async function uploadCalendar() {
  const file = el('calendarFile')?.files?.[0]
  if (!file) throw new Error('Choose the authoritative PDF first.')
  if (file.type !== 'application/pdf') throw new Error('The calendar must be a PDF.')
  if (!state.activeGroup || !isAdmin()) throw new Error('Owner or admin role required.')

  await runAction(async () => {
    const hash = await sha256(file)
    if (state.activeGroup.school_key === 'basis-phoenix-primary' && state.activeGroup.academic_year === '2026-27' && hash !== BASIS_CALENDAR_SHA256) {
      throw new Error('This PDF does not match the authoritative BASIS Phoenix Primary 2026–27 calendar used for this pilot.')
    }
    const path = `${state.activeGroup.id}/${hash}.pdf`
    const { error: uploadError } = await supabase.storage.from('kcp-school-calendars').upload(path, file, { upsert: false, contentType: 'application/pdf' })
    if (uploadError && !/already exists|duplicate/i.test(uploadError.message)) throw uploadError

    const { error } = await supabase.rpc('kcp_register_calendar', {
      p_group_id: state.activeGroup.id,
      p_school_key: state.activeGroup.school_key,
      p_school_name: state.activeGroup.school_name,
      p_academic_year: state.activeGroup.academic_year,
      p_source_name: file.name,
      p_source_sha256: hash,
      p_source_file_size: file.size,
      p_storage_path: path,
      p_events: BASIS_EVENTS
    })
    if (error) throw error
    await loadWorkspace(); renderAll()
  }, 'Calendar uploaded and analyzed')
}

function toggleWeekday(kind, dayNumber) {
  const list = state.constraintDraft[kind]
  if (list.includes(dayNumber)) state.constraintDraft[kind] = list.filter(day => day !== dayNumber)
  else state.constraintDraft[kind] = [...list, dayNumber].sort()
  renderConstraints()
}

async function submitConstraints() {
  if (!state.activeGroup) return
  state.constraintDraft.notes = el('constraintNotes')?.value || ''
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_submit_constraint_request', {
      p_group_id: state.activeGroup.id,
      p_drop_weekdays: state.constraintDraft.drop,
      p_pickup_weekdays: state.constraintDraft.pickup,
      p_notes: state.constraintDraft.notes
    })
    if (error) throw error
    await loadWorkspace(); renderAll()
  }, 'Constraint update submitted for admin review')
}

async function reviewConstraint(requestId, decision) {
  const reviewNote = prompt(`${capitalize(decision)} note (optional):`, '') ?? ''
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_review_constraint_request', {
      p_request_id: requestId,
      p_decision: decision,
      p_review_note: reviewNote
