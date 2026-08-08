import { WEEKDAYS, createSessionDraft, formatTimeLabel } from './generic-schedule.js'

const DAY_ALIASES = [
  { value: 1, long: 'Monday', pattern: 'mondays?|mon' },
  { value: 2, long: 'Tuesday', pattern: 'tuesdays?|tues?|tue' },
  { value: 3, long: 'Wednesday', pattern: 'wednesdays?|weds?|wed' },
  { value: 4, long: 'Thursday', pattern: 'thursdays?|thurs?|thu' },
  { value: 5, long: 'Friday', pattern: 'fridays?|fri' },
  { value: 6, long: 'Saturday', pattern: 'saturdays?|sat' },
  { value: 7, long: 'Sunday', pattern: 'sundays?|sun' }
]

const DAY_REGEX = new RegExp(`\\b(${DAY_ALIASES.map(day => day.pattern).join('|')})\\b`, 'gi')
const TIME_TOKEN = '(?:[01]?\\d|2[0-3])(?::[0-5]\\d)?\\s*(?:a\\.?m\\.?|p\\.?m\\.?)?'
const TIME_RANGE_REGEX = new RegExp(`(${TIME_TOKEN})\\s*(?:-|–|—|to|until|through|thru)\\s*(${TIME_TOKEN})`, 'i')
const DROP_PICKUP_REGEX = new RegExp(`(?:drop(?:-?off)?|outbound)\\s*(?:at|:)?\\s*(${TIME_TOKEN})[\\s,;]*(?:and|&)?\\s*(?:pickup|pick-up|return)\\s*(?:at|:)?\\s*(${TIME_TOKEN})`, 'i')
const PICKUP_DROP_REGEX = new RegExp(`(?:pickup|pick-up|return)\\s*(?:at|:)?\\s*(${TIME_TOKEN})[\\s,;]*(?:and|&)?\\s*(?:drop(?:-?off)?|outbound)\\s*(?:at|:)?\\s*(${TIME_TOKEN})`, 'i')
const SINGLE_TIME_REGEX = new RegExp(`\\b(${TIME_TOKEN})\\b`, 'i')

const STRATEGY_RULES = [
  {
    value: 'round_robin_week',
    pattern: /\b(?:alternate|alternating|rotate|rotation|take turns?)\b[\s\S]{0,35}\b(?:weekly|each week|every week|week by week)\b|\bthis week\b[\s\S]{0,80}\bnext week\b|\bevery other week\b/i
  },
  {
    value: 'round_robin_day',
    pattern: /\b(?:alternate|alternating|rotate|rotation|take turns?)\b[\s\S]{0,30}\b(?:daily|each day|every day|by day)\b/i
  },
  {
    value: 'round_robin_trip',
    pattern: /\b(?:alternate|alternating|rotate|rotation|take turns?)\b[\s\S]{0,30}\b(?:each ride|every ride|each trip|every trip)\b/i
  },
  {
    value: 'balanced',
    pattern: /\b(?:balance|balanced|distribute evenly|even distribution|share fairly|fair sharing)\b/i
  },
  {
    value: 'fixed',
    pattern: /\b(?:same driver|fixed driver|one driver every time|always driven by|always handles?|handled by)\b/i
  },
  {
    value: 'manual',
    pattern: /\b(?:assign later|manual assignment|choose later|coverage needed)\b/i
  }
]

export function parseNaturalSchedule(text, {
  participants = [],
  startsOn = '',
  defaultStrategy = 'manual'
} = {}) {
  const original = String(text || '').trim()
  const questions = []
  const warnings = []
  if (!original) {
    return emptyResult('Describe at least one recurring day and time.')
  }

  const dayMentions = findDayMentions(original)
  if (!dayMentions.length) {
    return emptyResult('Name at least one weekday, such as Thursday or Friday.')
  }

  const segments = dayMentions.map((mention, index) => ({
    ...mention,
    text: original.slice(mention.index, dayMentions[index + 1]?.index ?? original.length).trim()
  }))

  const parsedSegments = segments.map(segment => parseDaySegment(segment, original, questions, warnings))
  shareGroupedDayTimes(parsedSegments, questions, warnings)

  const intervalWeeks = parseRecurrenceInterval(original, warnings)
  const sessions = parsedSegments.map((segment, index) => createSessionDraft({
    name: `${segment.long} ride`,
    weekday: segment.value,
    intervalWeeks,
    anchorDate: startsOn,
    outboundEnabled: segment.outboundEnabled,
    outboundTime: segment.outboundTime || '',
    returnEnabled: segment.returnEnabled,
    returnTime: segment.returnTime || '',
    returnDayOffset: segment.returnDayOffset || 0,
    displayOrder: index + 1
  }))

  const strategy = detectStrategy(original, defaultStrategy)
  const participantMatch = matchParticipants(original, participants)
  const participantIds = participantMatch.matches.map(match => match.participant.id)
  const participantNames = participantMatch.matches.map(match => displayName(match.participant))

  for (const unmatched of participantMatch.unmatchedRotationNames) {
    questions.push(`“${unmatched}” could not be matched to an active driver in this group.`)
  }
  if (strategy === 'fixed' && participantIds.length !== 1) {
    questions.push(
      participantIds.length
        ? 'A fixed schedule needs exactly one matched active driver.'
        : 'Name the one active driver who should handle every ride.'
    )
  } else if (strategy !== 'manual' && !participantIds.length) {
    warnings.push('No active driver name was matched. Select the participating drivers in Step 3 before previewing.')
  }

  const unresolvedSessions = sessions.filter(session =>
    (session.outboundEnabled && !session.outboundTime)
      || (session.returnEnabled && !session.returnTime)
  )
  if (unresolvedSessions.length && !questions.length) {
    questions.push('Enter an unambiguous time for every enabled ride leg.')
  }

  const uniqueQuestions = unique(questions)
  const uniqueWarnings = unique(warnings)
  const summaryLines = sessions.map(session => sessionSummary(session))
  const assignmentSummary = assignmentText(strategy, participantNames)

  return {
    original,
    sessions,
    strategy,
    participantIds,
    participantNames,
    summaryLines,
    assignmentSummary,
    questions: uniqueQuestions,
    warnings: uniqueWarnings,
    canApply: sessions.length > 0 && uniqueQuestions.length === 0,
    startsOn
  }
}

export function formatNaturalUnderstanding(result) {
  if (!result) return ''
  const rideText = result.summaryLines?.length
    ? result.summaryLines.join('; ')
    : 'No recurring rides understood'
  return `${rideText}. ${result.assignmentSummary || 'Driver assignment remains manual.'}`
}

function parseDaySegment(segment, fullText, questions, warnings) {
  const lower = segment.text.toLowerCase()
  const pickupOnly = /\b(?:pickup|pick-up|return)\s*(?:only)?\b/i.test(lower)
    && /\b(?:pickup only|return only|only pickup|only return)\b/i.test(lower)
  const dropOnly = /\b(?:drop(?:-?off)?|outbound)\s*(?:only)?\b/i.test(lower)
    && /\b(?:drop(?:-?off)? only|outbound only|only drop(?:-?off)?|only outbound)\b/i.test(lower)
  const overnight = /\b(?:next day|following day|overnight|after midnight)\b/i.test(lower)

  let firstToken = null
  let secondToken = null
  let outboundEnabled = !pickupOnly
  let returnEnabled = !dropOnly

  const dropPickup = segment.text.match(DROP_PICKUP_REGEX)
  const pickupDrop = segment.text.match(PICKUP_DROP_REGEX)
  const range = segment.text.match(TIME_RANGE_REGEX)

  if (dropPickup) {
    firstToken = dropPickup[1]
    secondToken = dropPickup[2]
  } else if (pickupDrop) {
    firstToken = pickupDrop[2]
    secondToken = pickupDrop[1]
  } else if (range) {
    firstToken = range[1]
    secondToken = range[2]
  } else if (pickupOnly || dropOnly) {
    const single = segment.text.match(SINGLE_TIME_REGEX)
    firstToken = single?.[1] || null
    if (pickupOnly) secondToken = firstToken
  }

  if (!firstToken && !secondToken) {
    return {
      ...segment,
      outboundEnabled,
      returnEnabled,
      outboundTime: '',
      returnTime: '',
      returnDayOffset: overnight ? 1 : 0,
      missingTimes: true
    }
  }

  if (dropOnly) {
    const parsed = resolveSingleTime(firstToken, `${segment.long} drop-off`, questions)
    return {
      ...segment,
      outboundEnabled: true,
      returnEnabled: false,
      outboundTime: parsed || '',
      returnTime: '',
      returnDayOffset: 0,
      missingTimes: !parsed
    }
  }

  if (pickupOnly) {
    const parsed = resolveSingleTime(secondToken || firstToken, `${segment.long} pickup`, questions)
    return {
      ...segment,
      outboundEnabled: false,
      returnEnabled: true,
      outboundTime: '',
      returnTime: parsed || '',
      returnDayOffset: overnight ? 1 : 0,
      missingTimes: !parsed
    }
  }

  const rangeResult = resolveTimeRange(firstToken, secondToken, segment.long, overnight, questions, warnings)
  return {
    ...segment,
    outboundEnabled: true,
    returnEnabled: true,
    outboundTime: rangeResult.outboundTime,
    returnTime: rangeResult.returnTime,
    returnDayOffset: rangeResult.returnDayOffset,
    missingTimes: !rangeResult.outboundTime || !rangeResult.returnTime
  }
}

function resolveTimeRange(firstToken, secondToken, dayName, overnight, questions, warnings) {
  if (!firstToken || !secondToken) {
    questions.push(`${dayName}: provide both the drop-off and pickup time, or say drop-off only / pickup only.`)
    return { outboundTime: '', returnTime: '', returnDayOffset: overnight ? 1 : 0 }
  }

  let first = parseTimeToken(firstToken)
  let second = parseTimeToken(secondToken)
  if (!first.valid || !second.valid) {
    questions.push(`${dayName}: one of the times could not be understood.`)
    return { outboundTime: '', returnTime: '', returnDayOffset: overnight ? 1 : 0 }
  }

  if (first.ambiguous && second.ambiguous) {
    questions.push(`${dayName}: specify AM or PM for ${cleanTime(firstToken)} to ${cleanTime(secondToken)}.`)
    return { outboundTime: '', returnTime: '', returnDayOffset: overnight ? 1 : 0 }
  }

  if (first.ambiguous && second.meridiem) {
    first = parseTimeToken(`${cleanTime(firstToken)} ${second.meridiem}`)
    warnings.push(`${dayName}: interpreted ${cleanTime(firstToken)} as ${second.meridiem.toUpperCase()} to match the pickup time.`)
  } else if (second.ambiguous && first.meridiem) {
    second = parseTimeToken(`${cleanTime(secondToken)} ${first.meridiem}`)
    warnings.push(`${dayName}: interpreted ${cleanTime(secondToken)} as ${first.meridiem.toUpperCase()} to match the drop-off time.`)
  } else if (first.ambiguous || second.ambiguous) {
    questions.push(`${dayName}: specify AM or PM for the ambiguous time.`)
    return { outboundTime: '', returnTime: '', returnDayOffset: overnight ? 1 : 0 }
  }

  const firstMinutes = minutesOfDay(first.value)
  const secondMinutes = minutesOfDay(second.value)
  if (secondMinutes < firstMinutes && !overnight) {
    questions.push(`${dayName}: the pickup time is earlier than the drop-off time. Say “next day” if this is an overnight ride.`)
    return { outboundTime: '', returnTime: '', returnDayOffset: 0 }
  }

  return {
    outboundTime: first.value,
    returnTime: second.value,
    returnDayOffset: secondMinutes < firstMinutes || overnight ? 1 : 0
  }
}

function resolveSingleTime(token, label, questions) {
  if (!token) {
    questions.push(`${label}: enter a time.`)
    return ''
  }
  const parsed = parseTimeToken(token)
  if (!parsed.valid) {
    questions.push(`${label}: the time could not be understood.`)
    return ''
  }
  if (parsed.ambiguous) {
    questions.push(`${label}: specify AM or PM for ${cleanTime(token)}.`)
    return ''
  }
  return parsed.value
}

function shareGroupedDayTimes(segments, questions, warnings) {
  for (let index = 0; index < segments.length - 1; index += 1) {
    const current = segments[index]
    const next = segments[index + 1]
    if (!current.missingTimes || next.missingTimes) continue
    const connector = current.text.replace(new RegExp(`^\\s*(?:${dayPatternFor(current.value)})\\b`, 'i'), '').trim()
    if (!/^(?:,|and|&|\/|\s)+$/i.test(connector)) continue

    current.outboundEnabled = next.outboundEnabled
    current.returnEnabled = next.returnEnabled
    current.outboundTime = next.outboundTime
    current.returnTime = next.returnTime
    current.returnDayOffset = next.returnDayOffset
    current.missingTimes = next.missingTimes
    warnings.push(`${current.long} uses the same times as ${next.long} because those days were grouped together.`)

    removeQuestionPrefix(questions, `${current.long}:`)
  }
}

function parseRecurrenceInterval(text, warnings) {
  const explicit = text.match(/\bevery\s+(\d{1,2})(?:st|nd|rd|th)?\s+weeks?\b/i)
  if (explicit) {
    const value = Number(explicit[1])
    if (value >= 1 && value <= 52) return value
  }
  if (/\b(?:every other week|every two weeks|biweekly|fortnightly)\b/i.test(text)) {
    warnings.push('Interpreted the recurring rides as every 2 weeks. Weekly driver rotation remains a separate assignment rule.')
    return 2
  }
  return 1
}

function detectStrategy(text, defaultStrategy) {
  const matched = STRATEGY_RULES.find(rule => rule.pattern.test(text))
  if (matched) return matched.value
  if (/\b[A-Z][\w.'-]*(?:\s+[A-Z][\w.'-]*){0,2}\s+(?:drives|handles)\b/.test(text)) return 'fixed'
  return defaultStrategy
}

function matchParticipants(text, participants) {
  const normalizedParticipants = participants
    .filter(participant => participant?.id && participant?.status !== 'removed' && participant?.can_drive !== false)
    .map(participant => ({ participant, name: displayName(participant).trim() }))
    .filter(item => item.name)

  const firstNameCounts = new Map()
  for (const item of normalizedParticipants) {
    const first = normalizeName(item.name).split(' ')[0]
    firstNameCounts.set(first, (firstNameCounts.get(first) || 0) + 1)
  }

  const found = []
  for (const item of normalizedParticipants) {
    const aliases = [item.name]
    const first = item.name.trim().split(/\s+/)[0]
    if (first && firstNameCounts.get(normalizeName(first)) === 1) aliases.push(first)

    let firstIndex = Infinity
    for (const alias of unique(aliases)) {
      const regex = new RegExp(`(^|[^\\p{L}\\p{N}])${escapeRegExp(alias).replace(/\\\s+/g, '\\s+')}(?=$|[^\\p{L}\\p{N}])`, 'iu')
      const match = regex.exec(text)
      if (match) firstIndex = Math.min(firstIndex, match.index + match[1].length)
    }
    if (Number.isFinite(firstIndex)) found.push({ participant: item.participant, index: firstIndex })
  }

  found.sort((left, right) => left.index - right.index)
  const deduped = []
  const seen = new Set()
  for (const match of found) {
    if (seen.has(match.participant.id)) continue
    seen.add(match.participant.id)
    deduped.push(match)
  }

  const unmatchedRotationNames = extractRotationNames(text)
    .filter(candidate => !normalizedParticipants.some(item => participantNameMatches(candidate, item.name)))

  return { matches: deduped, unmatchedRotationNames: unique(unmatchedRotationNames) }
}

function extractRotationNames(text) {
  const names = []
  const pair = text.match(/\b([A-Z][\p{L}.'-]*(?:\s+[A-Z][\p{L}.'-]*){0,2})\s+(?:and|&)\s+([A-Z][\p{L}.'-]*(?:\s+[A-Z][\p{L}.'-]*){0,2})\s+(?:alternate|alternating|rotate|take turns?)/u)
  if (pair) names.push(pair[1].trim(), pair[2].trim())
  const labelled = text.match(/\bdrivers?\s*:\s*([^.;\n]+)/i)
  if (labelled) {
    names.push(...labelled[1].split(/,|\band\b|&/i).map(value => value.trim()).filter(Boolean))
  }
  return names.filter(name => !/^(?:driver|drivers|parent|parents)$/i.test(name))
}

function participantNameMatches(candidate, participantName) {
  const candidateName = normalizeName(candidate)
  const full = normalizeName(participantName)
  const first = full.split(' ')[0]
  return candidateName === full || candidateName === first
}

function findDayMentions(text) {
  const matches = []
  for (const match of text.matchAll(DAY_REGEX)) {
    const day = dayFromAlias(match[1])
    if (day) matches.push({ ...day, index: match.index, token: match[0] })
  }
  return matches
}

function dayFromAlias(alias) {
  const value = String(alias || '').toLowerCase()
  return DAY_ALIASES.find(day => new RegExp(`^(?:${day.pattern})$`, 'i').test(value)) || null
}

function dayPatternFor(value) {
  return DAY_ALIASES.find(day => day.value === value)?.pattern || ''
}

function parseTimeToken(raw) {
  const normalized = String(raw || '').toLowerCase().replace(/\./g, '').replace(/\s+/g, '')
  const match = normalized.match(/^(\d{1,2})(?::(\d{2}))?(am|pm)?$/)
  if (!match) return { valid: false, value: '', ambiguous: false, meridiem: null }
  let hour = Number(match[1])
  const minute = Number(match[2] || 0)
  const meridiem = match[3] || null
  if (hour > 23 || minute > 59 || (meridiem && (hour < 1 || hour > 12))) {
    return { valid: false, value: '', ambiguous: false, meridiem }
  }
  const ambiguous = !meridiem && hour >= 1 && hour <= 12
  if (meridiem) {
    if (hour === 12) hour = 0
    if (meridiem === 'pm') hour += 12
  }
  return {
    valid: true,
    value: `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`,
    ambiguous,
    meridiem
  }
}

function sessionSummary(session) {
  const day = WEEKDAYS.find(item => item.value === Number(session.weekday))?.long || 'Day'
  if (session.outboundEnabled && session.returnEnabled) {
    const returnSuffix = Number(session.returnDayOffset || 0) ? ' next day' : ''
    return `${day}: ${formatTimeLabel(session.outboundTime)} to ${formatTimeLabel(session.returnTime)}${returnSuffix}`
  }
  if (session.outboundEnabled) return `${day}: drop-off only at ${formatTimeLabel(session.outboundTime)}`
  if (session.returnEnabled) return `${day}: pickup only at ${formatTimeLabel(session.returnTime)}`
  return `${day}: no enabled ride`
}

function assignmentText(strategy, participantNames) {
  const names = participantNames.length ? participantNames.join(' → ') : 'drivers selected in Step 3'
  return ({
    round_robin_week: `Weekly rotation: ${names}`,
    round_robin_day: `Daily rotation: ${names}`,
    round_robin_trip: `Each ride rotates: ${names}`,
    balanced: `Assignments are balanced across ${names}`,
    fixed: `Fixed driver: ${participantNames[0] || 'select one driver in Step 3'}`,
    manual: 'Drivers will be assigned later'
  })[strategy] || 'Drivers will be assigned later'
}

function emptyResult(question) {
  return {
    original: '',
    sessions: [],
    strategy: 'manual',
    participantIds: [],
    participantNames: [],
    summaryLines: [],
    assignmentSummary: 'Drivers will be assigned later',
    questions: [question],
    warnings: [],
    canApply: false,
    startsOn: ''
  }
}

function removeQuestionPrefix(questions, prefix) {
  for (let index = questions.length - 1; index >= 0; index -= 1) {
    if (questions[index].startsWith(prefix)) questions.splice(index, 1)
  }
}
function displayName(participant) { return participant.display_name || participant.parent_name || participant.name || '' }
function normalizeName(value) { return String(value || '').trim().toLocaleLowerCase().replace(/\s+/g, ' ') }
function cleanTime(value) { return String(value || '').trim().replace(/\s+/g, ' ') }
function minutesOfDay(value) { const [hour, minute] = String(value).split(':').map(Number); return hour * 60 + minute }
function escapeRegExp(value) { return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') }
function unique(values) { return [...new Set(values.filter(Boolean))] }
