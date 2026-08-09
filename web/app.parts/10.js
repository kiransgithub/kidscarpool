import {
  ASSIGNMENT_STRATEGIES,
  WEEKDAYS,
  createSessionDraft,
  formatTimeLabel,
  normalizeSessionForRpc,
  validateScheduleDraft,
  weekdayLabel
} from './generic-schedule.js'

// ---------------------------------------------------------------------------
// Flexible group creation and schedule-builder state
// ---------------------------------------------------------------------------

state.scheduleBuilder = {
  plan: null,
  sessions: [],
  policies: [],
  policyMembers: [],
  participants: [],
  exceptions: []
}

let scheduleDraftSessions = []
let scheduleParticipantOrder = []
let selectedScheduleParticipants = new Set()
let activeSchedulePlanId = null

const kcpGenericPreviousLoadWorkspace = loadWorkspace
loadWorkspace = async function () {
  await kcpGenericPreviousLoadWorkspace()

  if (!state.activeGroup) {
    clearGenericScheduleState()
    return
  }

  try {
    const { data, error } = await supabase.rpc('kcp_schedule_builder_state', {
      p_group_id: state.activeGroup.id
    })
    if (error) throw error
    state.scheduleBuilder = data || emptyScheduleBuilderState()
  } catch (error) {
    if (!/Could not find the function|schema cache/i.test(error.message || '')) {
      console.warn('KCP generic schedule state:', error.message || error)
    }
    clearGenericScheduleState()
  }
}

const genericGroupDialog = el('genericGroupDialog')
const genericGroupForm = el('genericGroupForm')
const scheduleBuilderDialog = el('scheduleBuilderDialog')
const scheduleBuilderForm = el('scheduleBuilderForm')

function addGroupDriverInvite(values = {}) {
  const container = el('groupDriverInvites')
  if (!container) return
  const row = document.createElement('article')
  row.className = 'schedule-session-card group-driver-invite'
  row.innerHTML = `
    <div class="schedule-session-head"><strong>Invited driver</strong><button class="icon-delete" data-action="remove-group-driver" type="button" aria-label="Remove driver">×</button></div>
    <div class="schedule-session-grid">
      <label>Name<input data-driver-field="name" maxlength="80" value="${escapeHTML(values.name || '')}" placeholder="Parent or driver name"></label>
      <label>Email<input data-driver-field="email" type="email" autocomplete="email" value="${escapeHTML(values.email || '')}" placeholder="driver@example.com"></label>
      <label>Phone <span class="optional">optional</span><input data-driver-field="phone" autocomplete="tel" value="${escapeHTML(values.phone || '')}" placeholder="Phone number"></label>
      <label>Child or rider <span class="optional">if known</span><input data-driver-field="child" maxlength="80" value="${escapeHTML(values.child || '')}" placeholder="Child name"></label>
      <label class="full-width">Grade or level <span class="optional">if known</span><input data-driver-field="grade" maxlength="40" value="${escapeHTML(values.grade || '')}" placeholder="5, Beginner, Level 2"></label>
    </div>`
  container.appendChild(row)
}

function groupDriverInviteDrafts() {
  return [...document.querySelectorAll('.group-driver-invite')].map(row => ({
    name: row.querySelector('[data-driver-field="name"]').value.trim(),
    email: row.querySelector('[data-driver-field="email"]').value.trim().toLowerCase(),
    phone: row.querySelector('[data-driver-field="phone"]').value.trim(),
    child: row.querySelector('[data-driver-field="child"]').value.trim(),
    grade: row.querySelector('[data-driver-field="grade"]').value.trim()
  })).filter(item => item.name || item.email || item.phone || item.child || item.grade)
}

el('addGroupDriverInvite')?.addEventListener('click', () => addGroupDriverInvite())
document.addEventListener('click', event => {
  const remove = event.target.closest('[data-action="remove-group-driver"]')
  if (remove) remove.closest('.group-driver-invite')?.remove()
})

if (el('openCreateGroup') && genericGroupDialog) {
  el('openCreateGroup').addEventListener('click', event => {
    event.preventDefault()
    event.stopImmediatePropagation()
    genericGroupForm?.reset()
    if (el('genericGroupType')) el('genericGroupType').value = 'school'
    if (el('genericTimezone')) el('genericTimezone').value = state.activeGroup?.timezone || 'America/Phoenix'
    el('groupDriverInvites').innerHTML = ''
    addGroupDriverInvite()
    genericGroupDialog.showModal()
  }, { capture: true })
}

if (genericGroupForm) {
  genericGroupForm.addEventListener('submit', async event => {
    event.preventDefault()
    const invitedDrivers = groupDriverInviteDrafts()
    if (invitedDrivers.some(driver => !driver.name || !driver.email)) {
      toast('Each added driver needs a name and email so KCP can send the invitation.', true)
      return
    }

    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_create_group_v3', {
        p_name: el('genericGroupName').value.trim(),
        p_group_kind: el('genericGroupType').value,
        p_destination_name: el('genericDestination').value.trim(),
        p_term_label: el('genericTerm').value.trim() || null,
        p_timezone: el('genericTimezone').value,
        p_child_name: el('genericChildName').value.trim(),
        p_grade_or_level: el('genericGradeLevel').value.trim() || null
      })
      if (error) throw error

      const created = data?.[0]
      if (!created?.group_id || !created?.draft_plan_id) {
        throw new Error('The group was created but its owner or draft schedule was not returned.')
      }

      localStorage.setItem(ACTIVE_GROUP_KEY, created.group_id)
      await rememberGroup(created.group_id, 'Flexible KCP group')
      genericGroupDialog.close()
      genericGroupForm.reset()
      await refreshAll()
      for (const driver of invitedDrivers) {
        const { data: invitation, error: invitationError } = await supabase.rpc('kcp_create_driver_invitation', {
          p_group_id: created.group_id,
          p_member_name: driver.name,
          p_email: driver.email,
          p_phone: driver.phone || null,
          p_child_name: driver.child || null,
          p_grade_or_level: driver.grade || null,
          p_expires_in_days: 14
        }).single()
        if (invitationError) throw invitationError
        await shareInvitation(invitation)
      }
      await loadWorkspace()
      await openGenericScheduleBuilder(created.draft_plan_id)
    }, 'Private group created; you are the Owner')
  })
}

// ---------------------------------------------------------------------------
// Schedule-builder rendering and actions
// ---------------------------------------------------------------------------

async function openGenericScheduleBuilder(requestedPlanId = null) {
  if (!state.activeGroup || !isAdmin()) {
    toast('Only an Owner or Admin can configure the recurring schedule.', true)
    return
  }

  await runAction(async () => {
    let planId = requestedPlanId
    if (!planId) {
      const { data, error } = await supabase.rpc('kcp_get_or_create_draft_plan', {
        p_group_id: state.activeGroup.id
      })
      if (error) throw error
      planId = data
    }

    const { data, error } = await supabase.rpc('kcp_schedule_builder_state', {
      p_group_id: state.activeGroup.id
    })
    if (error) throw error

    state.scheduleBuilder = data || emptyScheduleBuilderState()
    activeSchedulePlanId = planId || state.scheduleBuilder.plan?.id
    initializeScheduleDraft()
    renderScheduleBuilder()
    scheduleBuilderDialog.showModal()
  }, '')
}

function initializeScheduleDraft() {
  const builder = state.scheduleBuilder || emptyScheduleBuilderState()
  const plan = builder.plan || {}
  const group = state.activeGroup || {}
  const firstServiceDay = Number(group.service_weekdays?.[0] || 1)

  scheduleDraftSessions = (builder.sessions || []).map((session, index) => createSessionDraft({
    ...session,
    displayOrder: session.display_order || index + 1
  }))

  if (!scheduleDraftSessions.length) {
    scheduleDraftSessions = [createSessionDraft({
      name: `${weekdayLabel(firstServiceDay, true)} ride`,
      weekday: firstServiceDay,
      outboundTime: String(group.drop_time || '07:00').slice(0, 5),
      returnTime: String(group.pickup_time || '15:35').slice(0, 5),
      anchorDate: plan.starts_on || localIsoDate(new Date())
    })]
  }

  const policy = (builder.policies || [])[0] || {}
  const orderedMemberIds = (builder.policyMembers || [])
    .sort((left, right) => left.rotation_position - right.rotation_position)
    .map(item => item.participant_id)
  const activeDriverIds = (builder.participants || [])
    .filter(item => item.status === 'active' && item.can_drive)
    .map(item => item.id)

  scheduleParticipantOrder = [
    ...orderedMemberIds,
    ...activeDriverIds.filter(id => !orderedMemberIds.includes(id))
  ]
  selectedScheduleParticipants = new Set(
    orderedMemberIds.length ? orderedMemberIds : activeDriverIds
  )

  el('schedulePlanName').value = plan.name || 'Recurring schedule'
  el('scheduleStartsOn').value = plan.starts_on || group.schedule_start_date || localIsoDate(new Date())
  el('scheduleEndsOn').value = plan.ends_on || group.schedule_end_date || localIsoDate(addDays(new Date(), 90))
  el('scheduleOutboundLabel').value = plan.outbound_label || defaultLegLabels(group.group_kind).outbound
  el('scheduleReturnLabel').value = plan.return_label || defaultLegLabels(group.group_kind).return
  el('scheduleAutoComplete').value = plan.auto_complete_after_minutes || group.auto_complete_after_minutes || 60
  el('scheduleStrategy').value = policy.strategy || 'fixed'
  el('scheduleCycleBehavior').value = policy.cycle_behavior || 'calendar'
  el('scheduleAnchorDate').value = policy.anchor_date || plan.starts_on || localIsoDate(new Date())

  activeSchedulePlanId = plan.id || activeSchedulePlanId
}

function renderScheduleBuilder() {
  renderScheduleSessionCards()
  renderScheduleParticipantPicker()
  renderScheduleStrategyHelp()
  el('schedulePreview').innerHTML = '<div class="empty-card compact"><p>Review the rules, then tap <strong>Preview schedule</strong>.</p></div>'
}

function renderScheduleSessionCards() {
  const container = el('scheduleSessionsList')
  container.innerHTML = scheduleDraftSessions.map((session, index) => `
    <article class="schedule-session-card" data-session-id="${escapeHTML(session.clientId)}">
      <div class="schedule-session-head">
        <div>
          <span class="eyebrow">RIDE ${index + 1}</span>
          <strong>${escapeHTML(session.name || weekdayLabel(session.weekday, true))}</strong>
        </div>
        <button class="icon-delete" data-action="remove-schedule-session" data-session-id="${escapeHTML(session.clientId)}" type="button" aria-label="Remove ride">×</button>
      </div>
      <div class="schedule-session-grid">
        <label class="full-width">Name
          <input data-session-field="name" value="${escapeHTML(session.name)}" placeholder="Thursday class">
        </label>
        <label>Day
          <select data-session-field="weekday">
            ${WEEKDAYS.map(day => `<option value="${day.value}" ${day.value === session.weekday ? 'selected' : ''}>${day.long}</option>`).join('')}
          </select>
        </label>
        <label>Repeats
          <select data-session-field="intervalWeeks">
            <option value="1" ${session.intervalWeeks === 1 ? 'selected' : ''}>Every week</option>
            <option value="2" ${session.intervalWeeks === 2 ? 'selected' : ''}>Every 2 weeks</option>
            <option value="3" ${session.intervalWeeks === 3 ? 'selected' : ''}>Every 3 weeks</option>
            <option value="4" ${session.intervalWeeks === 4 ? 'selected' : ''}>Every 4 weeks</option>
          </select>
        </label>
        <label class="ride-leg-toggle">
          <span><input data-session-field="outboundEnabled" type="checkbox" ${session.outboundEnabled ? 'checked' : ''}> Drop-off / outbound</span>
          <input data-session-field="outboundTime" type="time" value="${escapeHTML(session.outboundTime)}" ${session.outboundEnabled ? '' : 'disabled'}>
        </label>
        <label class="ride-leg-toggle">
          <span><input data-session-field="returnEnabled" type="checkbox" ${session.returnEnabled ? 'checked' : ''}> Pickup / return</span>
          <input data-session-field="returnTime" type="time" value="${escapeHTML(session.returnTime)}" ${session.returnEnabled ? '' : 'disabled'}>
        </label>
        <label>Return day
          <select data-session-field="returnDayOffset" ${session.returnEnabled ? '' : 'disabled'}>
            <option value="0" ${session.returnDayOffset === 0 ? 'selected' : ''}>Same day</option>
            <option value="1" ${session.returnDayOffset === 1 ? 'selected' : ''}>Next day</option>
            <option value="2" ${session.returnDayOffset === 2 ? 'selected' : ''}>Two days later</option>
          </select>
        </label>
        <label>Starts rotating from
          <input data-session-field="anchorDate" type="date" value="${escapeHTML(session.anchorDate || el('scheduleStartsOn').value)}">
        </label>
      </div>
    </article>`).join('')
}

function renderScheduleParticipantPicker() {
  const participantsById = new Map(
    (state.scheduleBuilder.participants || []).map(item => [item.id, item])
  )
  const ordered = scheduleParticipantOrder
    .map(id => participantsById.get(id))
    .filter(Boolean)
    .filter(item => item.status === 'active' && item.can_drive)

  const container = el('scheduleParticipantsList')
  if (!ordered.length) {
    container.innerHTML = '<div class="empty-card compact"><p>Invite at least one driving parent. The Owner remains available as a driver by default.</p></div>'
    el('scheduleFixedParticipant').innerHTML = '<option value="">No active driver</option>'
    return
  }

  container.innerHTML = ordered.map((participant, index) => `
    <div class="rotation-person" data-participant-id="${participant.id}">
      <label>
        <input class="rotation-person-check" type="checkbox" ${selectedScheduleParticipants.has(participant.id) ? 'checked' : ''}>
        <span><strong>${escapeHTML(participant.display_name)}</strong><small>${participant.user_id ? 'Joined' : 'Invitation pending'}</small></span>
      </label>
      <div class="rotation-controls">
        <button data-action="move-rotation-person" data-direction="up" data-participant-id="${participant.id}" type="button" ${index === 0 ? 'disabled' : ''}>↑</button>
        <button data-action="move-rotation-person" data-direction="down" data-participant-id="${participant.id}" type="button" ${index === ordered.length - 1 ? 'disabled' : ''}>↓</button>
      </div>
    </div>`).join('')

  const selected = ordered.filter(item => selectedScheduleParticipants.has(item.id))
  const currentFixed = el('scheduleFixedParticipant').value
  el('scheduleFixedParticipant').innerHTML = selected
    .map(item => `<option value="${item.id}">${escapeHTML(item.display_name)}</option>`)
    .join('') || '<option value="">Select a driver</option>'
  if (selected.some(item => item.id === currentFixed)) {
    el('scheduleFixedParticipant').value = currentFixed
  }

  el('scheduleFixedParticipantRow').classList.toggle(
    'hidden',
    el('scheduleStrategy').value !== 'fixed'
  )
}

function renderScheduleStrategyHelp() {
  const strategy = ASSIGNMENT_STRATEGIES.find(item => item.value === el('scheduleStrategy').value)
  el('scheduleStrategyHelp').innerHTML = strategy
    ? `<strong>${escapeHTML(strategy.title)}</strong><span>${escapeHTML(strategy.detail)}</span>`
    : ''

  const weekly = el('scheduleStrategy').value === 'round_robin_week'
  el('scheduleWeeklyHint').classList.toggle('hidden', !weekly)
}

function updateSessionFromControl(control) {
  const card = control.closest('[data-session-id]')
  if (!card) return
  const session = scheduleDraftSessions.find(item => item.clientId === card.dataset.sessionId)
  if (!session) return

  const field = control.dataset.sessionField
  if (!field) return
  if (control.type === 'checkbox') session[field] = control.checked
  else if (['weekday', 'intervalWeeks', 'returnDayOffset'].includes(field)) session[field] = Number(control.value)
  else session[field] = control.value

  if (field === 'outboundEnabled' || field === 'returnEnabled') {
    renderScheduleSessionCards()
  }
}

scheduleBuilderDialog?.addEventListener('input', event => {
  const control = event.target.closest('[data-session-field]')
  if (control) updateSessionFromControl(control)
})

scheduleBuilderDialog?.addEventListener('change', event => {
  const control = event.target.closest('[data-session-field]')
  if (control) updateSessionFromControl(control)

  if (event.target.matches('.rotation-person-check')) {
    const participantId = event.target.closest('[data-participant-id]')?.dataset.participantId
    if (participantId) {
      if (event.target.checked) selectedScheduleParticipants.add(participantId)
      else selectedScheduleParticipants.delete(participantId)
      renderScheduleParticipantPicker()
    }
  }

  if (event.target.id === 'scheduleStrategy') {
    renderScheduleParticipantPicker()
    renderScheduleStrategyHelp()
  }
})

scheduleBuilderDialog?.addEventListener('click', async event => {
  const button = event.target.closest('[data-action]')
  if (!button) return

  if (button.dataset.action === 'add-schedule-session') {
    event.preventDefault()
    const previous = scheduleDraftSessions.at(-1)
    const weekday = previous ? ((previous.weekday % 7) + 1) : 1
    scheduleDraftSessions.push(createSessionDraft({
      name: `${weekdayLabel(weekday, true)} ride`,
      weekday,
      outboundTime: previous?.outboundTime || '07:00',
      returnTime: previous?.returnTime || '15:35',
      anchorDate: el('scheduleStartsOn').value
    }))
    renderScheduleSessionCards()
    return
  }

  if (button.dataset.action === 'remove-schedule-session') {
    event.preventDefault()
    if (scheduleDraftSessions.length === 1) {
      toast('A schedule needs at least one recurring ride.', true)
      return
    }
    scheduleDraftSessions = scheduleDraftSessions.filter(item => item.clientId !== button.dataset.sessionId)
    renderScheduleSessionCards()
    return
  }

  if (button.dataset.action === 'move-rotation-person') {
    event.preventDefault()
    const currentIndex = scheduleParticipantOrder.indexOf(button.dataset.participantId)
    const targetIndex = button.dataset.direction === 'up' ? currentIndex - 1 : currentIndex + 1
    if (currentIndex >= 0 && targetIndex >= 0 && targetIndex < scheduleParticipantOrder.length) {
      const [participant] = scheduleParticipantOrder.splice(currentIndex, 1)
      scheduleParticipantOrder.splice(targetIndex, 0, participant)
      renderScheduleParticipantPicker()
    }
  }
})

if (scheduleBuilderForm) {
  scheduleBuilderForm.addEventListener('submit', async event => {
    event.preventDefault()
    await saveAndPreviewGenericSchedule()
  })
}

el('publishSchedulePlan')?.addEventListener('click', async event => {
  event.preventDefault()
  await runAction(async () => {
    await saveGenericScheduleDraft()
    const { data, error } = await supabase.rpc('kcp_publish_schedule_plan', {
      p_plan_id: activeSchedulePlanId,
      p_reason: 'Published from the flexible schedule builder'
    })
    if (error) throw error

    scheduleBuilderDialog.close()
    await refreshAll()
    navigate('schedule')
    return data
  }, 'Recurring schedule published')
})

async function saveAndPreviewGenericSchedule() {
  await runAction(async () => {
    await saveGenericScheduleDraft()
    const from = el('scheduleStartsOn').value
    const previewEnd = minIsoDate(
      el('scheduleEndsOn').value,
      localIsoDate(addDays(parseIsoDate(from), 35))
    )
    const { data, error } = await supabase.rpc('kcp_plan_occurrences', {
      p_plan_id: activeSchedulePlanId,
      p_from: from,
      p_to: previewEnd,
      p_limit: 80
    })
    if (error) throw error
    renderSchedulePreview(data || [])
  }, 'Draft saved and preview refreshed')
}

async function saveGenericScheduleDraft() {
  const participantIds = scheduleParticipantOrder.filter(id => selectedScheduleParticipants.has(id))
  const strategy = el('scheduleStrategy').value
  const fixedParticipantId = el('scheduleFixedParticipant').value || null
  const draft = {
    startsOn: el('scheduleStartsOn').value,
    endsOn: el('scheduleEndsOn').value,
    sessions: scheduleDraftSessions,
    strategy,
    participantIds,
    fixedParticipantId
  }
  const errors = validateScheduleDraft(draft)
  if (errors.length) throw new Error(errors[0])

  const { data, error } = await supabase.rpc('kcp_save_schedule_plan', {
    p_plan_id: activeSchedulePlanId,
    p_name: el('schedulePlanName').value.trim() || 'Recurring schedule',
    p_starts_on: draft.startsOn,
    p_ends_on: draft.endsOn,
    p_outbound_label: el('scheduleOutboundLabel').value.trim() || 'Drop-off',
    p_return_label: el('scheduleReturnLabel').value.trim() || 'Pickup',
    p_auto_complete_after_minutes: Number(el('scheduleAutoComplete').value),
    p_sessions: scheduleDraftSessions.map(normalizeSessionForRpc),
    p_strategy: strategy,
    p_cycle_behavior: el('scheduleCycleBehavior').value,
    p_anchor_date: el('scheduleAnchorDate').value || draft.startsOn,
    p_participant_ids: participantIds,
    p_fixed_participant_id: fixedParticipantId
  })
  if (error) throw error
  activeSchedulePlanId = data || activeSchedulePlanId
  return activeSchedulePlanId
}

function renderSchedulePreview(rows) {
  const container = el('schedulePreview')
  if (!rows.length) {
    container.innerHTML = '<div class="empty-card compact"><p>No trips were generated. Check the dates and recurring days.</p></div>'
    return
  }

  const grouped = new Map()
  for (const row of rows) {
    const weekKey = startOfWeekIso(row.service_date)
    if (!grouped.has(weekKey)) grouped.set(weekKey, [])
    grouped.get(weekKey).push(row)
  }

  container.innerHTML = [...grouped.entries()].map(([weekKey, weekRows]) => {
    const driverCount = new Set(weekRows.map(item => item.participant_name || 'Coverage needed')).size
    return `
      <section class="schedule-preview-week">
        <div class="schedule-preview-week-head">
          <strong>Week of ${escapeHTML(formatDate(weekKey))}</strong>
          <span class="badge">${driverCount} driver${driverCount === 1 ? '' : 's'}</span>
        </div>
        ${weekRows.map(row => `
          <div class="schedule-preview-row">
            <div>
              <strong>${escapeHTML(row.display_label)}</strong>
              <span>${escapeHTML(row.session_name)} · ${escapeHTML(formatDate(row.service_date))} · ${escapeHTML(formatTimeLabel(String(row.local_time).slice(0, 5)))}</span>
            </div>
            <span class="role-pill">${escapeHTML(row.participant_name || 'Coverage needed')}</span>
          </div>`).join('')}
      </section>`
  }).join('')
}

// ---------------------------------------------------------------------------
// Integrate the generic plan without changing the established KCP visuals.
// ---------------------------------------------------------------------------

const kcpGenericRenderGroupAdminPanel = renderGroupAdminPanel
renderGroupAdminPanel = function () {
  kcpGenericRenderGroupAdminPanel()
  if (!state.activeGroup) return

  const panel = el('groupAdminPanel')
  const legacyGenerateButton = panel.querySelector('[data-action="generate-schedule"]')
  if (legacyGenerateButton && isAdmin()) {
    legacyGenerateButton.dataset.action = 'open-generic-schedule-builder'
    legacyGenerateButton.textContent = 'Schedule setup'
  }

  const plan = state.scheduleBuilder?.plan
  const policy = state.scheduleBuilder?.policies?.[0]
  const planCard = document.createElement('div')
  planCard.className = 'card'
  planCard.id = 'genericScheduleSummaryCard'
  planCard.innerHTML = `
    <div class="group-card-head">
      <div>
        <span class="eyebrow">FLEXIBLE SCHEDULE</span>
        <h2>${escapeHTML(plan?.name || 'Not configured')}</h2>
        <p class="meta">${plan ? `${formatDate(plan.starts_on)} – ${formatDate(plan.ends_on)} · ${state.scheduleBuilder.sessions.length} recurring ride${state.scheduleBuilder.sessions.length === 1 ? '' : 's'}` : 'Create weekday-specific rides and choose how driving rotates.'}</p>
      </div>
      <span class="status-pill ${plan?.status === 'published' ? '' : 'info'}">${escapeHTML(capitalize(plan?.status || 'draft'))}</span>
    </div>
    <p class="meta">Assignment: <strong>${escapeHTML(strategyTitle(policy?.strategy || 'manual'))}</strong>. Calendar exceptions remain optional.</p>
    ${isAdmin() ? '<button class="primary-small" data-action="open-generic-schedule-builder" type="button">Configure & preview</button>' : ''}`
  panel.insertAdjacentElement('afterbegin', planCard)
}

const kcpGenericRenderHome = renderHome
renderHome = function () {
  kcpGenericRenderHome()
  if (!state.activeGroup) return

  const upcoming = activeTrips().filter(trip => [
    'scheduled', 'coverage_needed', 'cover_requested', 'cover_accepted', 'in_progress'
  ].includes(trip.status))
  const nextOutbound = upcoming.find(trip => (trip.leg_type || legacyLegType(trip.kind)) === 'outbound')
  const nextReturn = upcoming.find(trip => (trip.leg_type || legacyLegType(trip.kind)) === 'return')

  renderFocusTrip(
    el('nextDropCard'),
    nextOutbound,
    `NEXT ${(nextOutbound?.display_label || state.scheduleBuilder?.plan?.outbound_label || 'DROP-OFF').toUpperCase()}`,
    '↗'
  )
  renderFocusTrip(
    el('nextPickupCard'),
    nextReturn,
    `NEXT ${(nextReturn?.display_label || state.scheduleBuilder?.plan?.return_label || 'PICKUP').toUpperCase()}`,
    '↙'
  )
}

const kcpGenericTripRow = tripRow
tripRow = function (trip) {
  const html = kcpGenericTripRow(trip)
  if (!trip.display_label) return html

  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const row = template.content.firstElementChild
  const title = row?.querySelector('h3')
  if (title) title.textContent = `${trip.display_label} · ${driverName(trip)}`
  return row?.outerHTML || html
}

const kcpGenericShowTrip = showTrip
showTrip = function (tripId) {
  kcpGenericShowTrip(tripId)
  const trip = state.trips.find(item => item.id === tripId)
  if (!trip?.display_label) return

  const title = el('tripDialogContent')?.querySelector('.trip-modal-header h2')
  if (title) title.textContent = trip.display_label
}

const kcpGenericRenderConstraints = renderConstraints
renderConstraints = function () {
  kcpGenericRenderConstraints()
  if (!state.activeGroup) return

  const headings = [...el('constraintsCard').querySelectorAll('h3')]
  if (headings[0]) headings[0].textContent = state.scheduleBuilder?.plan?.outbound_label || 'Drop-off / outbound availability'
  if (headings[1]) headings[1].textContent = state.scheduleBuilder?.plan?.return_label || 'Pickup / return availability'
}

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-action="open-generic-schedule-builder"]')
  if (!button) return
  event.preventDefault()
  event.stopImmediatePropagation()
  await openGenericScheduleBuilder()
}, { capture: true })

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function clearGenericScheduleState() {
  state.scheduleBuilder = emptyScheduleBuilderState()
  activeSchedulePlanId = null
  scheduleDraftSessions = []
  scheduleParticipantOrder = []
  selectedScheduleParticipants = new Set()
}

function emptyScheduleBuilderState() {
  return {
    plan: null,
    sessions: [],
    policies: [],
    policyMembers: [],
    participants: [],
    exceptions: []
  }
}

function defaultLegLabels(groupKind) {
  switch (groupKind) {
    case 'school': return { outbound: 'School drop-off', return: 'School pickup' }
    case 'music': return { outbound: 'Class drop-off', return: 'Class pickup' }
    case 'tennis': return { outbound: 'Practice drop-off', return: 'Practice pickup' }
    case 'training': return { outbound: 'Training drop-off', return: 'Training pickup' }
    case 'gymnastics': return { outbound: 'Class drop-off', return: 'Class pickup' }
    case 'club': return { outbound: 'Club drop-off', return: 'Club pickup' }
    default: return { outbound: 'Outbound', return: 'Return' }
  }
}

function strategyTitle(value) {
  return ASSIGNMENT_STRATEGIES.find(item => item.value === value)?.title || 'Assign later'
}

function legacyLegType(kind) {
  return kind === 'morning_drop' ? 'outbound' : 'return'
}

function localIsoDate(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000)
  return local.toISOString().slice(0, 10)
}

function parseIsoDate(value) {
  const [year, month, day] = String(value).split('-').map(Number)
  return new Date(year, month - 1, day, 12, 0, 0, 0)
}

function addDays(date, days) {
  const result = new Date(date)
  result.setDate(result.getDate() + days)
  return result
}

function minIsoDate(left, right) {
  return left < right ? left : right
}

function startOfWeekIso(value) {
  const date = parseIsoDate(value)
  const weekday = date.getDay() === 0 ? 7 : date.getDay()
  return localIsoDate(addDays(date, 1 - weekday))
}
