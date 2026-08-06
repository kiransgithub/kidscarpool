// Final calendar-optional guardrails. This layer prevents arbitrary activity
// PDFs from being interpreted as the hard-coded BASIS calendar and supplies
// useful default recurring dates for new groups.

function kcpDateInputValue(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000)
  return local.toISOString().slice(0, 10)
}

if (el('newScheduleStart') && !el('newScheduleStart').value) {
  const start = new Date()
  const end = new Date(start)
  end.setDate(end.getDate() + 90)
  el('newScheduleStart').value = kcpDateInputValue(start)
  el('newScheduleEnd').value = kcpDateInputValue(end)
}

const kcpCalendarOptionalUpload = uploadCalendar
uploadCalendar = async function () {
  const canonicalBasis = state.activeGroup?.school_key === 'basis-phoenix-primary'
    && state.activeGroup?.academic_year === '2026-27'

  if (!canonicalBasis) {
    throw new Error(
      'Calendar upload is optional. Generic PDF date extraction is not enabled in this pilot, so KCP will use the recurring date range and weekdays without inventing exception dates.'
    )
  }

  return kcpCalendarOptionalUpload()
}

const kcpCalendarOptionalRender = renderCalendar
renderCalendar = function () {
  if (!state.activeGroup || state.calendar) {
    kcpCalendarOptionalRender()
    return
  }

  const canonicalBasis = state.activeGroup.school_key === 'basis-phoenix-primary'
    && state.activeGroup.academic_year === '2026-27'
  if (canonicalBasis) {
    kcpCalendarOptionalRender()
    return
  }

  const start = state.activeGroup.schedule_start_date
    ? formatDate(state.activeGroup.schedule_start_date)
    : 'Not set'
  const end = state.activeGroup.schedule_end_date
    ? formatDate(state.activeGroup.schedule_end_date)
    : 'Not set'

  el('calendarAnalytics').innerHTML = ''
  el('calendarActions').innerHTML = `
    <h2>Calendar not required</h2>
    <p class="meta">This ${escapeHTML(capitalize(state.activeGroup.group_kind || 'carpool'))} group uses its recurring schedule from ${escapeHTML(start)} through ${escapeHTML(end)}.</p>
    <p class="optional-calendar-note">KCP will not guess closures or special dates from an arbitrary PDF. The recurring weekdays and times remain the source of truth.</p>
    <div class="button-row">
      ${isAdmin() ? '<button class="primary-small" data-action="generate-schedule" type="button">Generate recurring schedule</button>' : ''}
    </div>`
  el('calendarTimeline').innerHTML = ''
}
