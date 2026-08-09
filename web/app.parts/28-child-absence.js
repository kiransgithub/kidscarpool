// Child absence and separate-pickup reporting across all memberships.

state.myChildren = []
state.absenceReports = []

const kcpAbsencePreviousLoadAllGroupFeeds = loadAllGroupFeeds
loadAllGroupFeeds = async function () {
  await kcpAbsencePreviousLoadAllGroupFeeds()
  if (!state.session?.user?.id) {
    state.myChildren = []
    state.absenceReports = []
    return
  }

  const [{ data: children, error: childError }, { data: reports, error: reportError }] = await Promise.all([
    supabase.rpc('kcp_my_children'),
    supabase.rpc('kcp_my_absence_reports', { p_include_past: false })
  ])
  if (childError && !/Could not find the function|schema cache/i.test(childError.message || '')) throw childError
  if (reportError && !/Could not find the function|schema cache/i.test(reportError.message || '')) throw reportError
  state.myChildren = children || []
  state.absenceReports = reports || []
}

if (!el('childAbsenceDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="childAbsenceDialog" class="modal child-absence-dialog">
      <form id="childAbsenceForm" class="dialog-form">
        <div class="dialog-title">
          <div><span class="eyebrow">RIDE UPDATE</span><h2>Child is not riding</h2></div>
          <button id="childAbsenceClose" class="close-button" type="button" aria-label="Close">×</button>
        </div>
        <label>Child or rider<select id="absenceChild" required></select></label>
        <label>Which ride?
          <select id="absenceTrip"><option value="">Date or date range</option></select>
        </label>
        <div id="absenceDateRange" class="two-column-form">
          <label>Starts<input id="absenceStarts" type="date" required></label>
          <label>Ends<input id="absenceEnds" type="date" required></label>
        </div>
        <label>Reason
          <select id="absenceReason">
            <option value="absent">Absent</option>
            <option value="picked_up_separately">Picked up separately</option>
            <option value="student_hours">Student hours</option>
            <option value="after_school_activity">After-school activity</option>
            <option value="appointment">Appointment</option>
            <option value="other">Other</option>
          </select>
        </label>
        <label>Note <span class="optional">optional</span><textarea id="absenceNote" rows="3" placeholder="Anything the assigned driver should know"></textarea></label>
        <label class="checkbox-row"><input id="absenceNotifyDriver" type="checkbox" checked><span><strong>Notify the assigned driver</strong><small>The driver's child list updates immediately.</small></span></label>
        <button class="primary-button" type="submit">Tell the driver</button>
      </form>
    </dialog>`)
}

function closeAbsenceDialog() {
  if (el('childAbsenceDialog')?.open) el('childAbsenceDialog').close('cancel')
  el('childAbsenceForm')?.reset()
}

el('childAbsenceClose')?.addEventListener('click', closeAbsenceDialog)
el('childAbsenceDialog')?.addEventListener('cancel', event => {
  event.preventDefault()
  closeAbsenceDialog()
})
el('childAbsenceDialog')?.addEventListener('click', event => {
  if (event.target === el('childAbsenceDialog')) closeAbsenceDialog()
})

function openAbsenceDialog(preselectedChildId = null, preselectedTripId = null) {
  if (!state.myChildren.length) {
    toast('No child or rider is attached to your active memberships.', true)
    return
  }

  const childSelect = el('absenceChild')
  childSelect.innerHTML = state.myChildren.map(child => `
    <option value="${child.child_id}">${escapeHTML(child.child_name)} · ${escapeHTML(child.group_name)}</option>`).join('')
  childSelect.value = preselectedChildId && state.myChildren.some(child => child.child_id === preselectedChildId)
    ? preselectedChildId
    : state.myChildren[0].child_id
  const today = new Date().toISOString().slice(0, 10)
  el('absenceStarts').value = today
  el('absenceEnds').value = today
  populateAbsenceTrips(preselectedTripId)
  el('childAbsenceDialog').showModal()
}

function populateAbsenceTrips(preselectedTripId = null) {
  const child = state.myChildren.find(item => item.child_id === el('absenceChild').value)
  const select = el('absenceTrip')
  if (!child) return
  const trips = state.allGroupAgenda.filter(trip =>
    trip.group_id === child.group_id
      && (trip.child_names || []).includes(child.child_name)
      && !['completed','cancelled'].includes(trip.status)
      && (!trip.scheduled_time || new Date(trip.scheduled_time).getTime() >= Date.now() - 15 * 60 * 1000)
  )
  select.innerHTML = '<option value="">Date or date range</option>' + trips.map(trip => `
    <option value="${trip.trip_id}" data-trip-date="${trip.trip_date}">${escapeHTML(trip.display_label || 'Ride')} · ${escapeHTML(agendaDateTime(trip))}</option>`).join('')
  if (preselectedTripId && trips.some(trip => trip.trip_id === preselectedTripId)) select.value = preselectedTripId
  updateAbsenceDateMode()
}

function updateAbsenceDateMode() {
  const option = el('absenceTrip').selectedOptions[0]
  const tripDate = option?.dataset.tripDate
  el('absenceDateRange').classList.toggle('hidden', Boolean(el('absenceTrip').value))
  if (tripDate) {
    el('absenceStarts').value = tripDate
    el('absenceEnds').value = tripDate
  }
}

el('absenceChild')?.addEventListener('change', () => populateAbsenceTrips())
el('absenceTrip')?.addEventListener('change', updateAbsenceDateMode)

el('childAbsenceForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_report_child_absence', {
      p_child_id: el('absenceChild').value,
      p_trip_id: el('absenceTrip').value || null,
      p_starts_on: el('absenceStarts').value,
      p_ends_on: el('absenceEnds').value,
      p_reason: el('absenceReason').value,
      p_note: el('absenceNote').value.trim() || null,
      p_notify_driver: el('absenceNotifyDriver').checked
    })
    if (error) throw error
    closeAbsenceDialog()
    await loadAllGroupFeeds()
    if (state.activeGroup) await loadWorkspace()
    renderAll()
    navigate('requests')
  }, 'Child ride update saved', { operation: 'report_child_absence' })
})

document.addEventListener('click', async event => {
  const open = event.target.closest('[data-action="report-child-absence"]')
  if (open) {
    event.preventDefault()
    openAbsenceDialog(open.dataset.childId || null, open.dataset.tripId || null)
    return
  }

  const cancel = event.target.closest('[data-action="cancel-child-absence"]')
  if (!cancel) return
  event.preventDefault()
  const reason = prompt('Why is this child available again?', 'Plans changed')
  if (reason === null) return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_cancel_child_absence', {
      p_report_id: cancel.dataset.reportId,
      p_reason: reason
    })
    if (error) throw error
    await loadAllGroupFeeds()
    if (state.activeGroup) await loadWorkspace()
    renderAll()
  }, 'Child ride update cancelled', { operation: 'cancel_child_absence' })
}, { capture: true })

function renderAbsenceQuickAction() {
  el('childAbsenceQuickAction')?.remove()
  if (!state.myChildren.length || kcpRolePortfolio().viewerOnly) return
  el('homeAlerts')?.insertAdjacentHTML('afterend', `
    <div id="childAbsenceQuickAction" class="card absence-quick-action">
      <div><span class="eyebrow">PLANS CHANGED?</span><h2>Child not riding?</h2><p class="meta">Report an absence, separate pickup, student hours or after-school activity.</p></div>
      <button class="primary-small" data-action="report-child-absence" type="button">Report update</button>
    </div>`)
}

function renderAbsenceRequests() {
  const list = el('allGroupRequestList')
  if (!list) return
  list.querySelectorAll('[data-absence-report]').forEach(node => node.remove())
  const reports = state.absenceReports.filter(report => report.status === 'active')
  if (!reports.length) return

  list.insertAdjacentHTML('afterbegin', reports.map(report => `
    <article class="request-card absence-request" data-absence-report="${report.report_id}">
      <div class="group-card-head">
        <div><span class="group-context-badge">${escapeHTML(report.group_name)}</span><h3>${escapeHTML(report.child_name)} · ${escapeHTML(humanize(report.reason))}</h3></div>
        <span class="status-pill info">Active</span>
      </div>
      <p class="meta">${report.trip_time ? `${escapeHTML(report.trip_label)} · ${formatDateTime(report.trip_time)}` : `${formatDate(report.starts_on)}${report.ends_on !== report.starts_on ? ` – ${formatDate(report.ends_on)}` : ''}`}</p>
      ${report.note ? `<p>${escapeHTML(report.note)}</p>` : ''}
      <p class="meta">${report.notify_driver ? 'Assigned driver should be notified' : 'Driver notification was not requested'}</p>
      ${report.can_cancel ? `<button class="action-button" data-action="cancel-child-absence" data-report-id="${report.report_id}" type="button">Child is riding again</button>` : ''}
    </article>`).join(''))
}

const kcpAbsencePreviousRenderAll = renderAll
renderAll = function () {
  kcpAbsencePreviousRenderAll()
  renderAbsenceQuickAction()
  renderAbsenceRequests()
}

const kcpAbsencePreviousRenderAllGroupRequests = renderAllGroupRequests
renderAllGroupRequests = function () {
  kcpAbsencePreviousRenderAllGroupRequests()
  renderAbsenceRequests()
}

// Show parent-reported absence context inside Driver mode.
const kcpAbsencePreviousDriverChildCard = driverChildCard
driverChildCard = function (child, tripStatus) {
  const html = kcpAbsencePreviousDriverChildCard(child, tripStatus)
  if (!child.absence_reason) return html
  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const card = template.content.firstElementChild
  card?.classList.add('reported-absence', 'skipped')
  card?.querySelector('.driver-child-top')?.insertAdjacentHTML('afterend', `
    <div class="driver-reported-absence"><strong>Reported ${escapeHTML(humanize(child.absence_reason))}</strong>${child.absence_note ? `<span>${escapeHTML(child.absence_note)}</span>` : ''}</div>`)
  return card?.outerHTML || html
}
