// Generic templates and impact-reviewed schedule publishing. Templates only
// prefill the normalized plan model; no community, person, activity, day time or
// destination is hard-coded into the scheduling engine.

state.scheduleTemplates = []
state.scheduleAcknowledgements = []
state.assignmentConflicts = []
let activeScheduleChangeSetId = null
let activeScheduleImpact = null
let scheduleImpactDirty = true

const kcpImpactPreviousLoadAllGroupFeeds = loadAllGroupFeeds
loadAllGroupFeeds = async function () {
  await kcpImpactPreviousLoadAllGroupFeeds()
  if (!state.session?.user?.id) {
    state.scheduleTemplates = []
    state.scheduleAcknowledgements = []
    state.assignmentConflicts = []
    return
  }

  const horizon = new Date()
  horizon.setDate(horizon.getDate() + 90)
  const [templateResult, acknowledgementResult, conflictResult] = await Promise.all([
    supabase.rpc('kcp_list_schedule_templates', {
      p_group_kind: state.activeGroup?.group_kind || null
    }),
    supabase.rpc('kcp_my_schedule_acknowledgements'),
    supabase.rpc('kcp_detect_user_conflicts', {
      p_user_id: state.session.user.id,
      p_from: new Date().toISOString(),
      p_to: horizon.toISOString()
    })
  ])

  for (const result of [templateResult, acknowledgementResult, conflictResult]) {
    if (result.error && !/Could not find the function|schema cache/i.test(result.error.message || '')) {
      throw result.error
    }
  }
  state.scheduleTemplates = templateResult.data || []
  state.scheduleAcknowledgements = acknowledgementResult.data || []
  state.assignmentConflicts = conflictResult.data || []
  renderScheduleTemplateOptions()
}

function ensureScheduleImpactControls() {
  const form = el('scheduleBuilderForm')
  if (!form) return

  const firstStep = form.querySelector('.schedule-step-card')
  if (firstStep && !el('scheduleTemplatePanel')) {
    firstStep.querySelector('.schedule-step-head')?.insertAdjacentHTML('afterend', `
      <section id="scheduleTemplatePanel" class="schedule-template-panel">
        <div><span class="eyebrow">STARTING POINT</span><h4>Choose a setup template</h4><p>Templates fill the generic weekly plan. You still enter the real days, times and drivers.</p></div>
        <div class="schedule-template-controls">
          <select id="scheduleTemplateSelect" aria-label="Schedule template"></select>
          <button class="secondary-button" data-action="apply-schedule-template" type="button">Apply template</button>
        </div>
        <div id="scheduleTemplateDescription" class="meta"></div>
      </section>`)
  }

  const sessionsStep = el('scheduleSessionsList')?.closest('.schedule-step-card')
  if (sessionsStep && !el('scheduleRideQuickActions')) {
    el('scheduleSessionsList').insertAdjacentHTML('beforebegin', `
      <div id="scheduleRideQuickActions" class="schedule-quick-actions">
        <button class="quick-action-chip" data-action="copy-first-ride-times" type="button">Copy first times to enabled days</button>
        <button class="quick-action-chip" data-action="make-pickup-only" type="button">Pickup only</button>
      </div>`)
  }

  const driversStep = el('scheduleParticipantsList')?.closest('.schedule-step-card')
  if (driversStep && !el('scheduleDriverQuickActions')) {
    el('scheduleParticipantsList').insertAdjacentHTML('beforebegin', `
      <div id="scheduleDriverQuickActions" class="schedule-quick-actions">
        <button class="quick-action-chip" data-action="select-all-schedule-drivers" type="button">Select all drivers</button>
        <button class="quick-action-chip" data-action="alternate-weekly" type="button">Alternate weekly</button>
      </div>`)
  }
}

ensureScheduleImpactControls()
renderScheduleTemplateOptions()

const kcpImpactPreviousOpenScheduleBuilder = openGenericScheduleBuilder
openGenericScheduleBuilder = async function (...args) {
  activeScheduleChangeSetId = null
  activeScheduleImpact = null
  scheduleImpactDirty = true
  await kcpImpactPreviousOpenScheduleBuilder(...args)
  ensureScheduleImpactControls()
  renderScheduleTemplateOptions()
}

function renderScheduleTemplateOptions() {
  const select = el('scheduleTemplateSelect')
  const description = el('scheduleTemplateDescription')
  if (!select) return
  const templates = state.scheduleTemplates || []
  select.innerHTML = templates.map(template => `
    <option value="${escapeHTML(template.template_key)}">${escapeHTML(template.name)}</option>`).join('')
  if (!templates.length) {
    select.innerHTML = '<option value="">Custom schedule</option>'
    select.disabled = true
  } else {
    select.disabled = false
  }
  updateScheduleTemplateDescription()
  if (description && !templates.length) description.textContent = 'Templates will appear after the schedule-template migration is applied.'
}

function updateScheduleTemplateDescription() {
  const key = el('scheduleTemplateSelect')?.value
  const template = state.scheduleTemplates.find(item => item.template_key === key)
  if (el('scheduleTemplateDescription')) {
    el('scheduleTemplateDescription').textContent = template?.description || ''
  }
}

el('scheduleTemplateSelect')?.addEventListener('change', updateScheduleTemplateDescription)

function invalidateScheduleImpact() {
  activeScheduleChangeSetId = null
  activeScheduleImpact = null
  scheduleImpactDirty = true
  el('scheduleImpactSummary')?.remove()
}

scheduleBuilderDialog?.addEventListener('input', event => {
  if (!event.target.closest('#schedulePreview')) invalidateScheduleImpact()
}, { capture: true })
scheduleBuilderDialog?.addEventListener('change', event => {
  if (!event.target.closest('#schedulePreview')) invalidateScheduleImpact()
}, { capture: true })

function applyScheduleTemplate() {
  const template = state.scheduleTemplates.find(item => item.template_key === el('scheduleTemplateSelect')?.value)
  if (!template) return
  const config = template.config || {}
  const weekdays = Array.isArray(config.weekdays) ? config.weekdays.map(Number) : []
  const existingByDay = new Map(
    scheduleDraftSessions.map(session => [Number(session.weekday), session])
  )
  const startsOn = el('scheduleStartsOn')?.value || ''

  scheduleDraftSessions = weekdays.map((weekday, index) => {
    const existing = existingByDay.get(weekday)
    return createSessionDraft({
      clientId: existing?.clientId,
      name: existing?.name || `${weekdayLabel(weekday, true)} ride`,
      weekday,
      intervalWeeks: existing?.intervalWeeks || 1,
      anchorDate: existing?.anchorDate || startsOn,
      outboundEnabled: Boolean(config.outboundEnabled),
      outboundTime: existing?.outboundTime || '',
      returnEnabled: Boolean(config.returnEnabled),
      returnTime: existing?.returnTime || '',
      returnDayOffset: existing?.returnDayOffset || 0,
      displayOrder: index + 1
    })
  })

  if (el('scheduleOutboundLabel')) el('scheduleOutboundLabel').value = config.outboundLabel || 'Outbound'
  if (el('scheduleReturnLabel')) el('scheduleReturnLabel').value = config.returnLabel || 'Return'
  if (el('scheduleStrategy')) el('scheduleStrategy').value = config.strategy || 'manual'

  const activeDrivers = (state.scheduleBuilder?.participants || [])
    .filter(participant => participant.status === 'active' && participant.can_drive)
    .map(participant => participant.id)
  if ((config.strategy || 'manual') !== 'manual') {
    scheduleParticipantOrder = [...activeDrivers]
    selectedScheduleParticipants = new Set(activeDrivers)
  }
  invalidateScheduleImpact()
  renderScheduleBuilder()
  renderScheduleTemplateOptions()
  toast(`${template.name} applied. Enter the actual days and times.`)
}

function copyFirstRideTimes() {
  const source = scheduleDraftSessions.find(session =>
    (session.outboundEnabled && session.outboundTime)
      || (session.returnEnabled && session.returnTime)
  )
  if (!source) {
    toast('Enter at least one day’s time first.', true)
    return
  }
  scheduleDraftSessions = scheduleDraftSessions.map(session => createSessionDraft({
    ...session,
    outboundEnabled: session.outboundEnabled,
    outboundTime: session.outboundEnabled ? source.outboundTime || '' : '',
    returnEnabled: session.returnEnabled,
    returnTime: session.returnEnabled ? source.returnTime || '' : ''
  }))
  invalidateScheduleImpact()
  renderScheduleBuilder()
}

function selectEveryScheduleDriver() {
  const ids = (state.scheduleBuilder?.participants || [])
    .filter(participant => participant.status === 'active' && participant.can_drive)
    .map(participant => participant.id)
  scheduleParticipantOrder = [...ids]
  selectedScheduleParticipants = new Set(ids)
  invalidateScheduleImpact()
  renderScheduleParticipantPicker()
}

function setAlternateWeekly() {
  if (el('scheduleStrategy')) el('scheduleStrategy').value = 'round_robin_week'
  selectEveryScheduleDriver()
  renderScheduleStrategyHelp()
  invalidateScheduleImpact()
}

function setPickupOnly() {
  if (!scheduleDraftSessions.length) {
    toast('Enable one or more days before choosing Pickup only.', true)
    return
  }
  scheduleDraftSessions = scheduleDraftSessions.map(session => createSessionDraft({
    ...session,
    outboundEnabled: false,
    outboundTime: '',
    returnEnabled: true
  }))
  if (el('scheduleOutboundLabel')) el('scheduleOutboundLabel').value = 'Outbound'
  if (el('scheduleReturnLabel') && !el('scheduleReturnLabel').value.trim()) el('scheduleReturnLabel').value = 'Pickup'
  invalidateScheduleImpact()
  renderScheduleBuilder()
}

document.addEventListener('click', event => {
  const button = event.target.closest('[data-action]')
  if (!button) return
  const action = button.dataset.action
  if (!['apply-schedule-template','copy-first-ride-times','select-all-schedule-drivers','alternate-weekly','make-pickup-only'].includes(action)) return
  event.preventDefault()
  event.stopImmediatePropagation()
  if (action === 'apply-schedule-template') applyScheduleTemplate()
  if (action === 'copy-first-ride-times') copyFirstRideTimes()
  if (action === 'select-all-schedule-drivers') selectEveryScheduleDriver()
  if (action === 'alternate-weekly') setAlternateWeekly()
  if (action === 'make-pickup-only') setPickupOnly()
}, { capture: true })

saveAndPreviewGenericSchedule = async function () {
  activeScheduleChangeSetId = null
  activeScheduleImpact = null
  scheduleImpactDirty = true

  await runAction(async () => {
    await saveGenericScheduleDraft()
    const from = el('scheduleStartsOn').value
    const previewEnd = minIsoDate(
      el('scheduleEndsOn').value,
      localIsoDate(addDays(parseIsoDate(from), 35))
    )
    const { data: occurrences, error: occurrenceError } = await supabase.rpc('kcp_plan_occurrences', {
      p_plan_id: activeSchedulePlanId,
      p_from: from,
      p_to: previewEnd,
      p_limit: 200
    })
    if (occurrenceError) throw occurrenceError
    renderSchedulePreview(occurrences || [])

    const { data: prepared, error: prepareError } = await supabase.rpc('kcp_prepare_schedule_change', {
      p_plan_id: activeSchedulePlanId,
      p_reason: 'Previewed from the recurring schedule builder'
    })
    if (prepareError) throw prepareError
    const row = prepared?.[0]
    if (!row?.change_set_id) throw new Error('Schedule impact preview did not return an identifier')

    activeScheduleChangeSetId = row.change_set_id
    const { data: details, error: detailError } = await supabase.rpc('kcp_schedule_change_details', {
      p_change_set_id: activeScheduleChangeSetId
    })
    if (detailError) throw detailError
    activeScheduleImpact = details || { summary: row.summary, impacts: [] }
    scheduleImpactDirty = false
    renderScheduleImpactSummary()
  }, 'Preview and impact review refreshed', { operation: 'preview_schedule_impact' })
}

const kcpImpactPreviousRenderCurrentPreviewWeek = typeof renderCurrentPreviewWeek === 'function'
  ? renderCurrentPreviewWeek
  : null
if (kcpImpactPreviousRenderCurrentPreviewWeek) {
  renderCurrentPreviewWeek = function () {
    kcpImpactPreviousRenderCurrentPreviewWeek()
    renderScheduleImpactSummary()
  }
}

function renderScheduleImpactSummary() {
  const preview = el('schedulePreview')
  if (!preview || !activeScheduleImpact || scheduleImpactDirty) return
  preview.querySelector('#scheduleImpactSummary')?.remove()
  const summary = activeScheduleImpact.summary || {}
  const impacts = activeScheduleImpact.impacts || []
  const conflicts = impacts.filter(impact => impact.impact_type === 'cross_group_conflict')
  const changed = Number(summary.added || 0)
    + Number(summary.removed || 0)
    + Number(summary.timeChanged || 0)
    + Number(summary.driverChanged || 0)

  preview.insertAdjacentHTML('beforeend', `
    <section id="scheduleImpactSummary" class="schedule-impact-summary ${conflicts.length ? 'has-conflicts' : ''}">
      <div class="group-card-head">
        <div><span class="eyebrow">PUBLISH IMPACT</span><h3>${changed || conflicts.length ? 'Review the affected rides' : 'No operational differences detected'}</h3></div>
        <span class="status-pill ${conflicts.length ? 'danger' : activeScheduleImpact.requires_acknowledgement ? 'warning' : 'complete'}">${conflicts.length ? `${conflicts.length} conflict${conflicts.length === 1 ? '' : 's'}` : activeScheduleImpact.requires_acknowledgement ? 'Acknowledgement needed' : 'Ready'}</span>
      </div>
      <div class="impact-metric-grid">
        ${impactMetric(summary.totalCandidateRides, 'Future rides')}
        ${impactMetric(summary.added, 'Added')}
        ${impactMetric(summary.removed, 'Removed')}
        ${impactMetric(summary.timeChanged, 'Time changes')}
        ${impactMetric(summary.driverChanged, 'Driver changes')}
        ${impactMetric(summary.affectedUsers, 'Affected people')}
      </div>
      ${activeScheduleImpact.requires_acknowledgement ? `<div class="impact-warning"><strong>Changes within 24 hours</strong><span>${Number(summary.urgentImpacts || 0)} urgent impact${Number(summary.urgentImpacts || 0) === 1 ? '' : 's'} will request acknowledgement from affected drivers.</span></div>` : ''}
      ${conflicts.length ? `<div class="impact-conflicts"><h4>Cross-group conflicts</h4>${conflicts.slice(0, 8).map(conflict => {
        const detail = conflict.details || {}
        return `<div><strong>${escapeHTML(detail.label || 'Candidate ride')}</strong><span>${conflict.new_time ? formatDateTime(conflict.new_time) : formatDate(conflict.trip_date)} overlaps ${escapeHTML(detail.conflictGroupName || 'another group')} · ${escapeHTML(detail.conflictLabel || 'ride')}</span></div>`
      }).join('')}</div>` : ''}
      <label class="impact-reason-label">Reason for publishing <span class="optional">recommended</span>
        <input id="schedulePublishReason" maxlength="240" placeholder="New term, parent availability change, corrected time…">
      </label>
    </section>`)
}

function impactMetric(value, label) {
  return `<div><strong>${Number(value || 0)}</strong><span>${escapeHTML(label)}</span></div>`
}

document.addEventListener('click', async event => {
  const publish = event.target.closest('#publishSchedulePlan')
  if (!publish) return
  event.preventDefault()
  event.stopImmediatePropagation()

  if (scheduleImpactDirty || !activeScheduleChangeSetId) {
    toast('Generate a fresh preview and impact review before publishing.', true)
    return
  }
  const summary = activeScheduleImpact?.summary || {}
  const conflicts = Number(summary.conflicts || 0)
  const message = conflicts
    ? `This schedule has ${conflicts} cross-group conflict${conflicts === 1 ? '' : 's'}. Publish anyway and notify affected members?`
    : 'Publish this schedule and notify affected members?'
  if (!confirm(message)) return

  const reason = el('schedulePublishReason')?.value.trim() || 'Published after impact review'
  await runAction(async () => {
    const { data, error } = await supabase.rpc('kcp_publish_schedule_plan_v2', {
      p_plan_id: activeSchedulePlanId,
      p_reason: reason,
      p_change_set_id: activeScheduleChangeSetId
    })
    if (error) throw error
    scheduleBuilderDialog.close()
    activeScheduleChangeSetId = null
    activeScheduleImpact = null
    scheduleImpactDirty = true
    await refreshAll()
    navigate('schedule')
    return data
  }, 'Schedule published and affected members notified', { operation: 'publish_schedule_impact' })
}, { capture: true })

const kcpImpactPreviousRenderAllGroupRequests = renderAllGroupRequests
renderAllGroupRequests = function () {
  kcpImpactPreviousRenderAllGroupRequests()
  renderScheduleAcknowledgements()
  renderAssignmentConflictNotice()
}

function renderScheduleAcknowledgements() {
  const list = el('allGroupRequestList')
  if (!list) return
  list.querySelectorAll('[data-schedule-ack]').forEach(node => node.remove())
  const acknowledgements = state.scheduleAcknowledgements || []
  if (!acknowledgements.length) return

  list.insertAdjacentHTML('afterbegin', `
    <section class="request-section" data-schedule-ack>
      <div class="request-section-heading"><span class="eyebrow">SCHEDULE CHANGES</span><h2>Acknowledgement requested</h2></div>
      ${acknowledgements.map(acknowledgement => {
        const summary = acknowledgement.summary || {}
        return `<article class="request-card schedule-ack-card ${acknowledgement.status === 'declined' ? 'needs-action' : ''}">
          <div class="group-card-head"><div><span class="group-context-badge">${escapeHTML(acknowledgement.group_name)}</span><h3>Review changed rides</h3></div>${statusPill(acknowledgement.status)}</div>
          <p class="meta">${Number(summary.timeChanged || 0)} time change${Number(summary.timeChanged || 0) === 1 ? '' : 's'} · ${Number(summary.driverChanged || 0)} driver change${Number(summary.driverChanged || 0) === 1 ? '' : 's'} · published ${formatDateTime(acknowledgement.published_at)}</p>
          ${acknowledgement.note ? `<p>${escapeHTML(acknowledgement.note)}</p>` : ''}
          <div class="button-row"><button class="action-button green" data-action="acknowledge-schedule-change" data-change-set-id="${acknowledgement.change_set_id}" type="button">Acknowledge</button><button class="action-button" data-action="flag-schedule-change" data-change-set-id="${acknowledgement.change_set_id}" type="button">Flag a problem</button></div>
        </article>`
      }).join('')}
    </section>`)
}

function renderAssignmentConflictNotice() {
  const list = el('allGroupRequestList')
  if (!list) return
  list.querySelector('[data-assignment-conflicts]')?.remove()
  const conflicts = state.assignmentConflicts || []
  if (!conflicts.length) return
  list.insertAdjacentHTML('afterbegin', `
    <section class="request-section" data-assignment-conflicts>
      <div class="request-section-heading"><span class="eyebrow">ASSIGNMENT CONFLICTS</span><h2>${conflicts.length} overlapping ride${conflicts.length === 1 ? '' : 's'}</h2></div>
      ${conflicts.slice(0, 12).map(conflict => `<article class="request-card conflict-card"><div class="group-card-head"><div><span class="group-context-badge">${escapeHTML(conflict.first_group_name)}</span><h3>${escapeHTML(conflict.first_label)}</h3></div><span class="status-pill danger">Overlap</span></div><p>${formatDateTime(conflict.first_start)} overlaps <strong>${escapeHTML(conflict.second_group_name)}</strong> · ${escapeHTML(conflict.second_label)}</p></article>`).join('')}
    </section>`)
}

document.addEventListener('click', async event => {
  const acknowledge = event.target.closest('[data-action="acknowledge-schedule-change"]')
  const flag = event.target.closest('[data-action="flag-schedule-change"]')
  if (!acknowledge && !flag) return
  event.preventDefault()
  const button = acknowledge || flag
  const status = acknowledge ? 'acknowledged' : 'declined'
  const note = flag ? prompt('Describe the conflict or problem for the group administrator') : null
  if (flag && note === null) return

  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_acknowledge_schedule_change', {
      p_change_set_id: button.dataset.changeSetId,
      p_status: status,
      p_note: note
    })
    if (error) throw error
    await loadAllGroupFeeds()
    renderAll()
  }, acknowledge ? 'Schedule change acknowledged' : 'Schedule problem flagged', { operation: 'acknowledge_schedule_change' })
}, { capture: true })
