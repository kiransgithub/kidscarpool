export const WEEKDAYS = [
  { value: 1, short: 'Mon', long: 'Monday' },
  { value: 2, short: 'Tue', long: 'Tuesday' },
  { value: 3, short: 'Wed', long: 'Wednesday' },
  { value: 4, short: 'Thu', long: 'Thursday' },
  { value: 5, short: 'Fri', long: 'Friday' },
  { value: 6, short: 'Sat', long: 'Saturday' },
  { value: 7, short: 'Sun', long: 'Sunday' }
]

export const ASSIGNMENT_STRATEGIES = [
  {
    value: 'fixed',
    title: 'Same driver every time',
    detail: 'One selected driver handles every generated ride.'
  },
  {
    value: 'round_robin_trip',
    title: 'Rotate every ride',
    detail: 'Each drop-off or pickup advances to the next driver.'
  },
  {
    value: 'round_robin_day',
    title: 'Rotate every day',
    detail: 'One driver handles every ride occurring on the same date.'
  },
  {
    value: 'round_robin_week',
    title: 'Rotate by week',
    detail: 'One driver handles all selected days and rides for that week.'
  },
  {
    value: 'balanced',
    title: 'Balance automatically',
    detail: 'Assignments are distributed evenly across selected drivers.'
  },
  {
    value: 'manual',
    title: 'Assign later',
    detail: 'Trips are generated as coverage needed until an admin assigns them.'
  }
]

export function createSessionDraft(overrides = {}) {
  return {
    clientId: overrides.clientId || cryptoSafeId(),
    name: overrides.name || 'Ride day',
    weekday: Number(overrides.weekday || 1),
    intervalWeeks: Number(overrides.intervalWeeks || overrides.recurrence_interval_weeks || 1),
    anchorDate: overrides.anchorDate || overrides.recurrence_anchor_date || '',
    outboundEnabled: overrides.outboundEnabled ?? overrides.outbound_enabled ?? true,
    outboundTime: normalizeTime(overrides.outboundTime || overrides.outbound_time || '07:00'),
    returnEnabled: overrides.returnEnabled ?? overrides.return_enabled ?? true,
    returnTime: normalizeTime(overrides.returnTime || overrides.return_time || '15:35'),
    returnDayOffset: Number(overrides.returnDayOffset ?? overrides.return_day_offset ?? 0),
    destinationOverride: overrides.destinationOverride || overrides.destination_override || '',
    displayOrder: Number(overrides.displayOrder || overrides.display_order || 0)
  }
}

export function normalizeSessionForRpc(session, index = 0) {
  const normalized = createSessionDraft(session)
  return {
    name: normalized.name.trim() || `Session ${index + 1}`,
    weekday: normalized.weekday,
    intervalWeeks: normalized.intervalWeeks,
    anchorDate: normalized.anchorDate || null,
    outboundEnabled: Boolean(normalized.outboundEnabled),
    outboundTime: normalized.outboundEnabled ? normalized.outboundTime : null,
    returnEnabled: Boolean(normalized.returnEnabled),
    returnTime: normalized.returnEnabled ? normalized.returnTime : null,
    returnDayOffset: normalized.returnDayOffset,
    destinationOverride: normalized.destinationOverride.trim() || null,
    displayOrder: index + 1
  }
}

export function validateScheduleDraft({
  startsOn,
  endsOn,
  sessions,
  strategy,
  participantIds,
  fixedParticipantId
}) {
  const errors = []

  if (!isIsoDate(startsOn) || !isIsoDate(endsOn) || startsOn > endsOn) {
    errors.push('Enter a valid schedule start and end date.')
  }

  if (!Array.isArray(sessions) || sessions.length === 0) {
    errors.push('Add at least one recurring ride day and time.')
  }

  for (const [index, raw] of (sessions || []).entries()) {
    const session = createSessionDraft(raw)
    const label = session.name.trim() || `Session ${index + 1}`

    if (session.weekday < 1 || session.weekday > 7) {
      errors.push(`${label}: choose a valid weekday.`)
    }
    if (session.intervalWeeks < 1 || session.intervalWeeks > 52) {
      errors.push(`${label}: repeat interval must be between 1 and 52 weeks.`)
    }
    if (!session.outboundEnabled && !session.returnEnabled) {
      errors.push(`${label}: enable drop-off, pickup, or both.`)
    }
    if (session.outboundEnabled && !isTime(session.outboundTime)) {
      errors.push(`${label}: enter a valid drop-off/outbound time.`)
    }
    if (session.returnEnabled && !isTime(session.returnTime)) {
      errors.push(`${label}: enter a valid pickup/return time.`)
    }
    if (session.returnDayOffset < 0 || session.returnDayOffset > 2) {
      errors.push(`${label}: return day must be the same day or within two days.`)
    }
  }

  const validStrategies = new Set(ASSIGNMENT_STRATEGIES.map(item => item.value))
  if (!validStrategies.has(strategy)) {
    errors.push('Choose how driving responsibility should be assigned.')
  }

  const drivers = [...new Set(participantIds || [])]
  if (strategy !== 'manual' && drivers.length === 0) {
    errors.push('Select at least one driver.')
  }
  if (strategy === 'fixed' && !fixedParticipantId) {
    errors.push('Choose the fixed driver.')
  }
  if (fixedParticipantId && !drivers.includes(fixedParticipantId)) {
    errors.push('The fixed driver must also be selected as a participating driver.')
  }

  return errors
}

export function previewSchedule({
  startsOn,
  endsOn,
  sessions,
  strategy,
  participants,
  anchorDate,
  outboundLabel = 'Drop-off',
  returnLabel = 'Pickup',
  maxOccurrences = 32
}) {
  if (!isIsoDate(startsOn) || !isIsoDate(endsOn)) return []

  const drivers = (participants || []).filter(item => item?.id)
  const normalizedSessions = (sessions || []).map(createSessionDraft)
  const start = parseLocalDate(startsOn)
  const end = parseLocalDate(endsOn)
  const anchor = parseLocalDate(isIsoDate(anchorDate) ? anchorDate : startsOn)
  const occurrences = []

  for (let cursor = new Date(start); cursor <= end && occurrences.length < maxOccurrences; cursor = plusDays(cursor, 1)) {
    const isoWeekday = cursor.getDay() === 0 ? 7 : cursor.getDay()
    const daySessions = normalizedSessions
      .filter(session => session.weekday === isoWeekday)
      .filter(session => {
        const weeks = Math.floor(daysBetween(parseLocalDate(session.anchorDate || startsOn), cursor) / 7)
        return weeks >= 0 && weeks % session.intervalWeeks === 0
      })
      .sort((a, b) => a.displayOrder - b.displayOrder || a.outboundTime.localeCompare(b.outboundTime))

    for (const session of daySessions) {
      if (session.outboundEnabled) {
        occurrences.push(makePreviewOccurrence({
          date: cursor,
          session,
          legType: 'outbound',
          time: session.outboundTime,
          label: outboundLabel
        }))
      }
      if (session.returnEnabled) {
        occurrences.push(makePreviewOccurrence({
          date: plusDays(cursor, session.returnDayOffset),
          serviceDate: cursor,
          session,
          legType: 'return',
          time: session.returnTime,
          label: returnLabel
        }))
      }
    }
  }

  const distinctDates = [...new Set(occurrences.map(item => item.serviceDate))]
  const distinctWeeks = [...new Set(occurrences.map(item => weekStart(item.serviceDate)))]

  return occurrences.slice(0, maxOccurrences).map((occurrence, tripIndex) => {
    const dayIndex = distinctDates.indexOf(occurrence.serviceDate)
    const weekKey = weekStart(occurrence.serviceDate)
    const occurrenceWeekIndex = distinctWeeks.indexOf(weekKey)
    const calendarWeekIndex = Math.floor(daysBetween(parseLocalDate(weekStart(formatIsoDate(anchor))), parseLocalDate(weekKey)) / 7)

    let participant = null
    if (drivers.length) {
      let position = 0
      switch (strategy) {
        case 'fixed':
          position = 0
          break
        case 'round_robin_week':
          position = positiveModulo(calendarWeekIndex, drivers.length)
          break
        case 'round_robin_day':
          position = positiveModulo(dayIndex, drivers.length)
          break
        case 'manual':
          participant = null
          break
        case 'balanced':
        case 'round_robin_trip':
        default:
          position = positiveModulo(tripIndex, drivers.length)
      }
      if (strategy !== 'manual') participant = drivers[position]
    }

    return {
      ...occurrence,
      participantId: participant?.id || null,
      participantName: participant?.display_name || participant?.name || 'Coverage needed',
      blockKey: strategy === 'round_robin_week'
        ? `week:${weekKey}`
        : strategy === 'round_robin_day'
          ? `day:${occurrence.serviceDate}`
          : `trip:${tripIndex}`,
      occurrenceWeekIndex
    }
  })
}

export function formatTimeLabel(value) {
  if (!isTime(value)) return value || '—'
  const [hourText, minute] = value.split(':')
  const hour = Number(hourText)
  const suffix = hour >= 12 ? 'PM' : 'AM'
  const displayHour = hour % 12 || 12
  return `${displayHour}:${minute} ${suffix}`
}

export function weekdayLabel(value, long = false) {
  const item = WEEKDAYS.find(day => day.value === Number(value))
  return item ? (long ? item.long : item.short) : 'Day'
}

function makePreviewOccurrence({ date, serviceDate = date, session, legType, time, label }) {
  return {
    serviceDate: formatIsoDate(serviceDate),
    date: formatIsoDate(date),
    sessionName: session.name,
    weekday: session.weekday,
    legType,
    time,
    label
  }
}

function cryptoSafeId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()
  return `session-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function normalizeTime(value) {
  const text = String(value || '')
  return /^\d{2}:\d{2}/.test(text) ? text.slice(0, 5) : text
}

function isTime(value) {
  if (!/^\d{2}:\d{2}$/.test(String(value || ''))) return false
  const [hours, minutes] = String(value).split(':').map(Number)
  return hours >= 0 && hours <= 23 && minutes >= 0 && minutes <= 59
}

function isIsoDate(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || ''))
}

function parseLocalDate(value) {
  const [year, month, day] = String(value).split('-').map(Number)
  return new Date(year, month - 1, day, 12, 0, 0, 0)
}

function formatIsoDate(date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function plusDays(date, days) {
  const copy = new Date(date)
  copy.setDate(copy.getDate() + Number(days || 0))
  return copy
}

function daysBetween(left, right) {
  return Math.round((right.getTime() - left.getTime()) / 86400000)
}

function weekStart(value) {
  const date = typeof value === 'string' ? parseLocalDate(value) : new Date(value)
  const weekday = date.getDay() === 0 ? 7 : date.getDay()
  return formatIsoDate(plusDays(date, 1 - weekday))
}

function positiveModulo(value, divisor) {
  return ((value % divisor) + divisor) % divisor
}
