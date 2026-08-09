// Availability must reflect the live published trips, not an unpublished draft
// that an administrator may be editing in the schedule builder.

const kcpWeeklyMatrixRenderConstraints = renderConstraints
renderConstraints = function () {
  const card = el('constraintsCard')
  if (!card || !state.activeGroup) {
    kcpWeeklyMatrixRenderConstraints()
    return
  }

  const outboundLabel = publishedLegLabel('outbound')
  const returnLabel = publishedLegLabel('return')
  const weeklyTimes = publishedWeeklyTripTimes()

  card.innerHTML = `
    <h2>Rides I can drive</h2>
    <p class="meta">These times come from the live schedule. Select the rides you can drive; only a group manager can change the official schedule.</p>
    <div class="availability-week-matrix" role="table" aria-label="Weekly driver availability">
      <div class="availability-week-head" role="row">
        <span role="columnheader">Day</span>
        <span role="columnheader">${escapeHTML(outboundLabel)}</span>
        <span role="columnheader">${escapeHTML(returnLabel)}</span>
      </div>
      ${WEEKDAYS.map(day => publishedAvailabilityRow(day, weeklyTimes.get(day.value))).join('')}
    </div>
    <p class="availability-time-note">Times cannot be changed here. Use Notes if you are available for only part of the time or need a one-time change.</p>
    <label style="margin-top:12px">Notes
      <textarea id="constraintNotes" rows="3" placeholder="Example: Thursday preferred; unavailable after 7:30 PM">${escapeHTML(state.constraintDraft.notes)}</textarea>
    </label>
    <button class="primary-button" data-action="submit-constraints" type="button" style="margin-top:12px">Send availability change</button>`
}

function publishedLegLabel(leg) {
  const trip = (state.trips || []).find(item => currentTripLeg(item) === leg && item.display_label)
  if (trip?.display_label) return trip.display_label
  const plan = state.scheduleBuilder?.plan
  return leg === 'outbound'
    ? (plan?.outbound_label || 'Drop-off / outbound')
    : (plan?.return_label || 'Pickup / return')
}

function publishedWeeklyTripTimes() {
  const result = new Map(WEEKDAYS.map(day => [day.value, { outbound: [], return: [] }]))

  for (const trip of state.trips || []) {
    const dateText = String(trip.trip_date || '').slice(0, 10)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateText)) continue
    const date = new Date(`${dateText}T12:00:00`)
    const weekday = date.getDay() === 0 ? 7 : date.getDay()
    const leg = currentTripLeg(trip)
    if (!result.has(weekday) || !['outbound', 'return'].includes(leg)) continue

    const time = publishedTripLocalTime(trip)
    if (time && !result.get(weekday)[leg].includes(time)) {
      result.get(weekday)[leg].push(time)
      result.get(weekday)[leg].sort()
    }
  }

  // A newly created group has no published trips yet. Fall back to the plan
  // sessions solely to keep the screen useful before its first publication.
  if (![...result.values()].some(day => day.outbound.length || day.return.length)) {
    for (const session of state.scheduleBuilder?.sessions || []) {
      const weekday = Number(session.weekday)
      const day = result.get(weekday)
      if (!day) continue
      if ((session.outbound_enabled ?? session.outboundEnabled) && (session.outbound_time || session.outboundTime)) {
        day.outbound.push(String(session.outbound_time || session.outboundTime).slice(0, 5))
      }
      if ((session.return_enabled ?? session.returnEnabled) && (session.return_time || session.returnTime)) {
        day.return.push(String(session.return_time || session.returnTime).slice(0, 5))
      }
      day.outbound = [...new Set(day.outbound)].sort()
      day.return = [...new Set(day.return)].sort()
    }
  }

  return result
}

function currentTripLeg(trip) {
  if (trip?.leg_type) return trip.leg_type
  return trip?.kind === 'morning_drop' ? 'outbound' : 'return'
}

function publishedTripLocalTime(trip) {
  if (trip?.scheduled_time) {
    const value = new Date(trip.scheduled_time)
    if (!Number.isNaN(value.getTime())) {
      const timezone = state.activeGroup?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone
      const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: timezone,
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23'
      }).formatToParts(value)
      const hour = parts.find(part => part.type === 'hour')?.value
      const minute = parts.find(part => part.type === 'minute')?.value
      if (hour && minute) return `${hour}:${minute}`
    }
  }

  const match = String(trip?.time_label || '').match(/(\d{1,2}):(\d{2})\s*(AM|PM)/i)
  if (!match) return ''
  let hour = Number(match[1]) % 12
  if (match[3].toUpperCase() === 'PM') hour += 12
  return `${String(hour).padStart(2, '0')}:${match[2]}`
}

function publishedAvailabilityRow(day, times = { outbound: [], return: [] }) {
  return `
    <div class="availability-week-row" role="row">
      <div class="availability-day" role="rowheader"><strong>${day.short}</strong><span>${day.long}</span></div>
      ${publishedAvailabilityCell('drop', day, times.outbound, state.constraintDraft.drop.includes(day.value))}
      ${publishedAvailabilityCell('pickup', day, times.return, state.constraintDraft.pickup.includes(day.value))}
    </div>`
}

function publishedAvailabilityCell(kind, day, times, selected) {
  const scheduled = (times || []).length > 0
  const label = scheduled ? times.map(formatTimeLabel).join(', ') : 'No ride'
  return `
    <button class="availability-leg ${selected ? 'selected' : ''} ${scheduled ? '' : 'not-scheduled'}" data-action="toggle-weekday" data-kind="${kind}" data-day="${day.value}" type="button" ${scheduled ? '' : 'disabled'} role="cell" aria-pressed="${selected}">
      <span>${selected ? '✓ Available' : 'Unavailable'}</span>
      <time>${escapeHTML(label)}</time>
    </button>`
}
