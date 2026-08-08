// Weekly-matrix schedule flow.
//
// This layer keeps the generic schedule model and every advanced control, but
// makes the common case visible as one compact Monday-Sunday grid. Advanced
// multi-session, multi-week and overnight rules remain in the existing editor.

if (!document.querySelector('link[href="./weekly-matrix-flow.css"]')) {
  const stylesheet = document.createElement('link')
  stylesheet.rel = 'stylesheet'
  stylesheet.href = './weekly-matrix-flow.css'
  document.head.appendChild(stylesheet)
}

const kcpWeeklyScheduleDialog = el('scheduleBuilderDialog')
const kcpWeeklyScheduleForm = el('scheduleBuilderForm')

let kcpPreviewWeekGroups = []
let kcpPreviewWeekIndex = 0

ensureDriverConfirmationDialog()
prepareWeeklyMatrixStructure()

const kcpWeeklyPreviousRenderScheduleSessionCards = renderScheduleSessionCards
renderScheduleSessionCards = function () {
  kcpWeeklyPreviousRenderScheduleSessionCards()
  prepareWeeklyMatrixStructure()
  renderWeeklyScheduleMatrix()
}

const kcpWeeklyPreviousRenderScheduleBuilder = renderScheduleBuilder
renderScheduleBuilder = function () {
  kcpWeeklyPreviousRenderScheduleBuilder()
  prepareWeeklyMatrixStructure()
  renderWeeklyScheduleMatrix()
}

// Replace the long per-session preview with one complete Monday-Sunday week at
// a time. The administrator can move between generated weeks without scrolling
// through every occurrence.
renderSchedulePreview = function (rows) {
  const normalized = (rows || []).map(row => ({
    ...row,
    actual_date: previewActualDate(row)
  }))

  const grouped = new Map()
  for (const row of normalized) {
    const weekKey = kcpWeekStartIso(row.actual_date)
    if (!grouped.has(weekKey)) grouped.set(weekKey, [])
    grouped.get(weekKey).push(row)
  }

  kcpPreviewWeekGroups = [...grouped.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([weekStart, weekRows]) => ({
      weekStart,
      rows: weekRows.sort((left, right) => {
        return left.actual_date.localeCompare(right.actual_date)
          || String(left.local_time || '').localeCompare(String(right.local_time || ''))
          || String(left.leg_type || '').localeCompare(String(right.leg_type || ''))
      })
    }))
  kcpPreviewWeekIndex = 0
  renderCurrentPreviewWeek()
}

// Before generating the preview, require an explicit confirmation that the
// intended drivers are selected. "Review drivers" closes the popup and makes
// no state or database change.
const kcpWeeklyPreviousAdvanceScheduleBuilder = advanceScheduleBuilder
advanceScheduleBuilder = async function () {
  if (kcpScheduleStep === 3) {
    openDriverConfirmationDialog()
    return
  }
  return kcpWeeklyPreviousAdvanceScheduleBuilder()
}

// The availability screen uses the official schedule times as read-only
// context. Parents choose whether they are available; only Owners/Admins change
// the official trip times in the schedule builder.
const kcpWeeklyPreviousRenderConstraints = renderConstraints
renderConstraints = function () {
  const card = el('constraintsCard')
  if (!card) return
  if (!state.activeGroup) {
    kcpWeeklyPreviousRenderConstraints()
    return
  }

  const outboundLabel = state.scheduleBuilder?.plan?.outbound_label || 'Drop-off / outbound'
  const returnLabel = state.scheduleBuilder?.plan?.return_label || 'Pickup / return'
  const scheduleByDay = sessionsByWeekday(state.scheduleBuilder?.sessions || [])

  card.innerHTML = `
    <h2>My ride availability</h2>
    <p class="meta">The times below come from the published recurring schedule. Select the rides you can drive; changing official times remains an Owner/Admin action.</p>
    <div class="availability-week-matrix" role="table" aria-label="Weekly driver availability">
      <div class="availability-week-head" role="row">
        <span role="columnheader">Day</span>
        <span role="columnheader">${escapeHTML(outboundLabel)}</span>
        <span role="columnheader">${escapeHTML(returnLabel)}</span>
      </div>
      ${WEEKDAYS.map(day => availabilityWeekRow(day, scheduleByDay.get(day.value) || [])).join('')}
    </div>
    <p class="availability-time-note">Times are informational here. Use Notes for a narrower availability window or an exception.</p>
    <label style="margin-top:12px">Notes
      <textarea id="constraintNotes" rows="3" placeholder="Example: Thursday preferred; unavailable after 7:30 PM">${escapeHTML(state.constraintDraft.notes)}</textarea>
    </label>
    <button class="primary-button" data-action="submit-constraints" type="button" style="margin-top:12px">Submit update request</button>`
}

// Existing admin summaries must understand Saturday and Sunday as well.
daysText = function (days = []) {
  const labels = (days || [])
    .map(value => WEEKDAYS.find(day => day.value === Number(value))?.short)
    .filter(Boolean)
  return labels.length ? labels.join(', ') : 'None'
}

if (kcpWeeklyScheduleDialog) {
  kcpWeeklyScheduleDialog.addEventListener('change', event => {
    const control = event.target.closest('[data-week-matrix-field]')
    if (!control) return
    updateWeeklyMatrixControl(control)
  })

  kcpWeeklyScheduleDialog.addEventListener('input', event => {
    const control = event.target.closest('[data-week-matrix-field="outboundTime"], [data-week-matrix-field="returnTime"]')
    if (!control) return
    updateWeeklyMatrixControl(control, { rerender: false })
  })

  // If an advanced card changes, refresh the compact weekly representation.
  kcpWeeklyScheduleDialog.addEventListener('change', event => {
    if (event.target.closest('[data-session-field]')) {
      queueMicrotask(renderWeeklyScheduleMatrix)
    }
  })

  kcpWeeklyScheduleDialog.addEventListener('click', event => {
    const action = event.target.closest('[data-action]')?.dataset.action
    if (action === 'preview-week-previous') {
      event.preventDefault()
      event.stopImmediatePropagation()
      kcpPreviewWeekIndex = Math.max(0, kcpPreviewWeekIndex - 1)
      renderCurrentPreviewWeek()
    }
    if (action === 'preview-week-next') {
      event.preventDefault()
      event.stopImmediatePropagation()
      kcpPreviewWeekIndex = Math.min(kcpPreviewWeekGroups.length - 1, kcpPreviewWeekIndex + 1)
      renderCurrentPreviewWeek()
    }
  }, { capture: true })
}

function prepareWeeklyMatrixStructure() {
  if (!kcpWeeklyScheduleForm) return
  const ridesPanel = kcpWeeklyScheduleForm.querySelector('[data-schedule-step-panel="2"]')
  const list = el('scheduleSessionsList')
  if (!ridesPanel || !list) return

  if (!el('scheduleWeekMatrix')) {
    const matrix = document.createElement('div')
    matrix.id = 'scheduleWeekMatrix'
    matrix.className = 'weekly-schedule-matrix'
    matrix.setAttribute('role', 'table')
    matrix.setAttribute('aria-label', 'Recurring rides for the full week')
    list.insertAdjacentElement('beforebegin', matrix)
  }

  if (!el('scheduleAdvancedRideRules')) {
    const details = document.createElement('details')
    details.id = 'scheduleAdvancedRideRules'
    details.className = 'schedule-advanced weekly-advanced-rides'
    details.innerHTML = `
      <summary>Advanced ride rules <span>Multiple rides, multi-week repeats and overnight returns</span></summary>
      <div class="weekly-advanced-content"></div>`
    const content = details.querySelector('.weekly-advanced-content')
    list.insertAdjacentElement('beforebegin', details)
    content.appendChild(list)

    const addButton = ridesPanel.querySelector('[data-action="add-schedule-session"]')
    if (addButton) content.appendChild(addButton)
  }
}

function renderWeeklyScheduleMatrix() {
  const container = el('scheduleWeekMatrix')
  if (!container) return

  const scheduleMap = sessionsByWeekday(scheduleDraftSessions)
  container.innerHTML = `
    <div class="weekly-matrix-intro">
      <strong>Weekly ride times</strong>
      <span>Enable a day, then set its drop-off and pickup. Saturday and Sunday are available like any other day.</span>
    </div>
    <div class="weekly-matrix-head" role="row">
      <span role="columnheader">Day</span>
      <span role="columnheader">Drop-off</span>
      <span role="columnheader">Pickup</span>
    </div>
    ${WEEKDAYS.map(day => weeklyScheduleRow(day, scheduleMap.get(day.value) || [])).join('')}`
}

function weeklyScheduleRow(day, sessions) {
  const primary = sessions[0] || null
  const enabled = Boolean(primary)
  const defaultOutbound = defaultWeeklyTime('outbound')
  const defaultReturn = defaultWeeklyTime('return')
  const advanced = sessions.length > 1 || Boolean(primary && (
    Number(primary.intervalWeeks || primary.recurrence_interval_weeks || 1) !== 1
    || Number(primary.returnDayOffset ?? primary.return_day_offset ?? 0) !== 0
    || primary.destinationOverride
    || primary.destination_override
  ))

  return `
    <div class="weekly-matrix-row ${enabled ? 'enabled' : ''}" data-weekday="${day.value}" role="row">
      <label class="weekly-day-toggle" role="cell">
        <input type="checkbox" data-week-matrix-field="dayEnabled" ${enabled ? 'checked' : ''}>
        <span><strong>${day.short}</strong><small>${day.long}</small></span>
      </label>
      <div class="weekly-time-cell" role="cell">
        <label><input type="checkbox" data-week-matrix-field="outboundEnabled" ${primary?.outboundEnabled ?? primary?.outbound_enabled ?? true ? 'checked' : ''} ${enabled ? '' : 'disabled'}><span>Drop</span></label>
        <input type="time" data-week-matrix-field="outboundTime" value="${escapeHTML(String(primary?.outboundTime || primary?.outbound_time || defaultOutbound).slice(0, 5))}" ${enabled && (primary?.outboundEnabled ?? primary?.outbound_enabled ?? true) ? '' : 'disabled'} aria-label="${day.long} drop-off time">
      </div>
      <div class="weekly-time-cell" role="cell">
        <label><input type="checkbox" data-week-matrix-field="returnEnabled" ${primary?.returnEnabled ?? primary?.return_enabled ?? true ? 'checked' : ''} ${enabled ? '' : 'disabled'}><span>Pickup</span></label>
        <input type="time" data-week-matrix-field="returnTime" value="${escapeHTML(String(primary?.returnTime || primary?.return_time || defaultReturn).slice(0, 5))}" ${enabled && (primary?.returnEnabled ?? primary?.return_enabled ?? true) ? '' : 'disabled'} aria-label="${day.long} pickup time">
      </div>
      ${advanced ? `<span class="weekly-advanced-badge" title="Additional rules are available below">${sessions.length > 1 ? `${sessions.length} rules` : 'Advanced'}</span>` : ''}
    </div>`
}

function updateWeeklyMatrixControl(control, { rerender = true } = {}) {
  const row = control.closest('[data-weekday]')
  const weekday = Number(row?.dataset.weekday)
  if (!weekday) return

  const sessions = scheduleDraftSessions.filter(session => Number(session.weekday) === weekday)
  let primary = sessions[0] || null
  const field = control.dataset.weekMatrixField

  if (field === 'dayEnabled') {
    if (control.checked && !primary) {
      primary = createSessionDraft({
        name: `${weekdayLabel(weekday, true)} ride`,
        weekday,
        intervalWeeks: 1,
        anchorDate: el('scheduleStartsOn')?.value || localIsoDate(new Date()),
        outboundEnabled: true,
        outboundTime: defaultWeeklyTime('outbound'),
        returnEnabled: true,
        returnTime: defaultWeeklyTime('return'),
        displayOrder: weekday
      })
      scheduleDraftSessions.push(primary)
      scheduleDraftSessions.sort((left, right) => Number(left.weekday) - Number(right.weekday) || Number(left.displayOrder || 0) - Number(right.displayOrder || 0))
    } else if (!control.checked && sessions.length) {
      if (sessions.length > 1 && !confirm(`${weekdayLabel(weekday, true)} has ${sessions.length} ride rules. Disable all of them?`)) {
        control.checked = true
        return
      }
      scheduleDraftSessions = scheduleDraftSessions.filter(session => Number(session.weekday) !== weekday)
    }
    markSchedulePreviewStale()
    renderScheduleSessionCards()
    return
  }

  if (!primary) return

  if (field === 'outboundEnabled' || field === 'returnEnabled') {
    const nextOutbound = field === 'outboundEnabled' ? control.checked : Boolean(primary.outboundEnabled)
    const nextReturn = field === 'returnEnabled' ? control.checked : Boolean(primary.returnEnabled)
    if (!nextOutbound && !nextReturn) {
      control.checked = true
      toast('Keep drop-off, pickup, or both enabled for this day.', true)
      return
    }
    primary[field] = control.checked
  } else if (field === 'outboundTime' || field === 'returnTime') {
    primary[field] = control.value
  }

  syncAdvancedSessionCard(primary)
  markSchedulePreviewStale()
  if (rerender) renderWeeklyScheduleMatrix()
}

function syncAdvancedSessionCard(session) {
  const card = kcpWeeklyScheduleDialog?.querySelector(`[data-session-id="${CSS.escape(session.clientId)}"]`)
  if (!card) return
  for (const field of ['outboundEnabled', 'outboundTime', 'returnEnabled', 'returnTime']) {
    const control = card.querySelector(`[data-session-field="${field}"]`)
    if (!control) continue
    if (control.type === 'checkbox') control.checked = Boolean(session[field])
    else control.value = session[field] || ''
    control.disabled = field === 'outboundTime'
      ? !session.outboundEnabled
      : field === 'returnTime'
        ? !session.returnEnabled
        : false
  }
}

function defaultWeeklyTime(leg) {
  const existing = scheduleDraftSessions.find(session => leg === 'outbound'
    ? (session.outboundEnabled ?? session.outbound_enabled)
    : (session.returnEnabled ?? session.return_enabled))
  if (existing) {
    const value = leg === 'outbound'
      ? (existing.outboundTime || existing.outbound_time)
      : (existing.returnTime || existing.return_time)
    if (value) return String(value).slice(0, 5)
  }
  const fallback = leg === 'outbound'
    ? (state.activeGroup?.drop_time || '07:00')
    : (state.activeGroup?.pickup_time || '15:35')
  return String(fallback).slice(0, 5)
}

function sessionsByWeekday(sessions) {
  const result = new Map(WEEKDAYS.map(day => [day.value, []]))
  for (const raw of sessions || []) {
    const weekday = Number(raw.weekday)
    if (!result.has(weekday)) result.set(weekday, [])
    result.get(weekday).push(raw)
  }
  for (const rows of result.values()) {
    rows.sort((left, right) => Number(left.displayOrder || left.display_order || 0) - Number(right.displayOrder || right.display_order || 0))
  }
  return result
}

function ensureDriverConfirmationDialog() {
  if (el('scheduleDriversConfirmDialog')) return
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="scheduleDriversConfirmDialog" class="modal driver-confirm-dialog">
      <div class="dialog-form">
        <div class="dialog-title">
          <div><span class="eyebrow">CONFIRM DRIVERS</span><h2>Are all intended drivers included?</h2></div>
          <button id="scheduleDriversConfirmClose" class="close-button" type="button" aria-label="Close">×</button>
        </div>
        <p id="scheduleDriversConfirmMessage" class="meta"></p>
        <div id="scheduleDriversConfirmList" class="driver-confirm-list"></div>
        <div class="driver-confirm-actions">
          <button id="scheduleDriversReview" class="secondary-button" type="button">No, review drivers</button>
          <button id="scheduleDriversProceed" class="primary-button" type="button">Yes, generate preview</button>
        </div>
      </div>
    </dialog>`)

  const dialog = el('scheduleDriversConfirmDialog')
  const close = () => dialog.close('cancel')
  el('scheduleDriversConfirmClose').addEventListener('click', close)
  el('scheduleDriversReview').addEventListener('click', close)
  dialog.addEventListener('cancel', close)
  dialog.addEventListener('click', event => {
    if (event.target === dialog) close()
  })
  el('scheduleDriversProceed').addEventListener('click', async () => {
    dialog.close('confirmed')
    await kcpWeeklyPreviousAdvanceScheduleBuilder()
  })
}

function openDriverConfirmationDialog() {
  const dialog = el('scheduleDriversConfirmDialog')
  const activeDrivers = (state.scheduleBuilder?.participants || [])
    .filter(participant => participant.status === 'active' && participant.can_drive)
  const selected = activeDrivers.filter(participant => selectedScheduleParticipants.has(participant.id))
  const excluded = activeDrivers.filter(participant => !selectedScheduleParticipants.has(participant.id))
  const strategy = el('scheduleStrategy')?.value

  if (strategy !== 'manual' && !selected.length) {
    toast('Select at least one driver before previewing.', true)
    return
  }

  el('scheduleDriversConfirmMessage').textContent = excluded.length
    ? `${selected.length} of ${activeDrivers.length} active drivers are selected. Continue only if the excluded drivers should not receive assignments.`
    : `All ${activeDrivers.length} active driver${activeDrivers.length === 1 ? '' : 's'} are included. Generate the schedule preview?`

  el('scheduleDriversConfirmList').innerHTML = `
    <div class="driver-confirm-group">
      <strong>Included</strong>
      ${selected.map(participant => `<span class="driver-confirm-chip included">✓ ${escapeHTML(participant.display_name)}</span>`).join('') || '<span class="meta">None selected</span>'}
    </div>
    ${excluded.length ? `<div class="driver-confirm-group"><strong>Not included</strong>${excluded.map(participant => `<span class="driver-confirm-chip excluded">${escapeHTML(participant.display_name)}</span>`).join('')}</div>` : ''}`
  dialog.showModal()
}

function renderCurrentPreviewWeek() {
  const container = el('schedulePreview')
  if (!container) return
  if (!kcpPreviewWeekGroups.length) {
    container.innerHTML = '<div class="empty-card compact"><p>No trips were generated. Check the date range and weekly ride times.</p></div>'
    return
  }

  const group = kcpPreviewWeekGroups[kcpPreviewWeekIndex]
  const weekEnd = addIsoDays(group.weekStart, 6)
  container.innerHTML = `
    <div class="weekly-preview-toolbar">
      <button class="secondary-button" data-action="preview-week-previous" type="button" ${kcpPreviewWeekIndex === 0 ? 'disabled' : ''} aria-label="Previous week">‹</button>
      <div><strong>${escapeHTML(shortDate(group.weekStart))} – ${escapeHTML(shortDate(weekEnd))}</strong><span>Week ${kcpPreviewWeekIndex + 1} of ${kcpPreviewWeekGroups.length}</span></div>
      <button class="secondary-button" data-action="preview-week-next" type="button" ${kcpPreviewWeekIndex === kcpPreviewWeekGroups.length - 1 ? 'disabled' : ''} aria-label="Next week">›</button>
    </div>
    <div class="weekly-preview-grid" role="table" aria-label="Complete weekly schedule preview">
      ${WEEKDAYS.map((day, index) => previewDayRow(day, addIsoDays(group.weekStart, index), group.rows)).join('')}
    </div>`
}

function previewDayRow(day, date, rows) {
  const dayRows = rows.filter(row => row.actual_date === date)
  return `
    <div class="weekly-preview-day ${dayRows.length ? 'has-rides' : ''}" role="row">
      <div class="weekly-preview-date" role="rowheader"><strong>${day.short}</strong><span>${escapeHTML(shortDate(date))}</span></div>
      <div class="weekly-preview-rides" role="cell">
        ${dayRows.length ? dayRows.map(row => `
          <div class="weekly-preview-ride">
            <time>${escapeHTML(formatTimeLabel(String(row.local_time || '').slice(0, 5)))}</time>
            <span><strong>${escapeHTML(row.display_label || capitalize(row.leg_type || 'Ride'))}</strong><small>${escapeHTML(row.session_name || '')}</small></span>
            <em>${escapeHTML(row.participant_name || 'Coverage needed')}</em>
          </div>`).join('') : '<span class="weekly-no-ride">No ride</span>'}
      </div>
    </div>`
}

function previewActualDate(row) {
  const offset = Number(row?.day_offset || 0)
  return addIsoDays(String(row?.service_date || '').slice(0, 10), offset)
}

function kcpWeekStartIso(value) {
  const date = parseIsoLocal(value)
  const weekday = date.getDay() === 0 ? 7 : date.getDay()
  date.setDate(date.getDate() + 1 - weekday)
  return formatIsoLocal(date)
}

function addIsoDays(value, days) {
  const date = parseIsoLocal(value)
  date.setDate(date.getDate() + Number(days || 0))
  return formatIsoLocal(date)
}

function parseIsoLocal(value) {
  const [year, month, day] = String(value).slice(0, 10).split('-').map(Number)
  return new Date(year, month - 1, day, 12, 0, 0, 0)
}

function formatIsoLocal(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

function availabilityWeekRow(day, sessions) {
  const outboundTimes = uniqueScheduleTimes(sessions, 'outbound')
  const returnTimes = uniqueScheduleTimes(sessions, 'return')
  const dropSelected = state.constraintDraft.drop.includes(day.value)
  const pickupSelected = state.constraintDraft.pickup.includes(day.value)

  return `
    <div class="availability-week-row" role="row">
      <div class="availability-day" role="rowheader"><strong>${day.short}</strong><span>${day.long}</span></div>
      ${availabilityLegCell('drop', day, outboundTimes, dropSelected)}
      ${availabilityLegCell('pickup', day, returnTimes, pickupSelected)}
    </div>`
}

function availabilityLegCell(kind, day, times, selected) {
  const scheduled = times.length > 0
  const label = scheduled ? times.map(formatTimeLabel).join(', ') : 'No ride'
  return `
    <button class="availability-leg ${selected ? 'selected' : ''} ${scheduled ? '' : 'not-scheduled'}" data-action="toggle-weekday" data-kind="${kind}" data-day="${day.value}" type="button" ${scheduled ? '' : 'disabled'} role="cell" aria-pressed="${selected}">
      <span>${selected ? '✓ Available' : 'Unavailable'}</span>
      <time>${escapeHTML(label)}</time>
    </button>`
}

function uniqueScheduleTimes(sessions, leg) {
  const values = []
  for (const session of sessions || []) {
    const enabled = leg === 'outbound'
      ? (session.outbound_enabled ?? session.outboundEnabled)
      : (session.return_enabled ?? session.returnEnabled)
    const value = leg === 'outbound'
      ? (session.outbound_time || session.outboundTime)
      : (session.return_time || session.returnTime)
    if (enabled && value) values.push(String(value).slice(0, 5))
  }
  return [...new Set(values)].sort()
}
