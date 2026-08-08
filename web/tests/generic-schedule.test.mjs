import test from 'node:test'
import assert from 'node:assert/strict'
import {
  createSessionDraft,
  formatTimeLabel,
  normalizeSessionForRpc,
  previewSchedule,
  validateScheduleDraft
} from '../generic-schedule.js'

const participants = [
  { id: 'participant-a', display_name: 'Driver A' },
  { id: 'participant-b', display_name: 'Driver B' }
]

const sessions = [
  createSessionDraft({
    name: 'Thursday activity',
    weekday: 4,
    outboundTime: '18:30',
    returnTime: '19:00',
    anchorDate: '2026-08-10'
  }),
  createSessionDraft({
    name: 'Friday activity',
    weekday: 5,
    outboundTime: '17:00',
    returnTime: '18:00',
    anchorDate: '2026-08-10'
  })
]

test('new ride sessions do not invent times', () => {
  const empty = createSessionDraft()
  assert.equal(empty.outboundTime, '')
  assert.equal(empty.returnTime, '')

  const errors = validateScheduleDraft({
    startsOn: '2026-08-10',
    endsOn: '2026-08-31',
    sessions: [empty],
    strategy: 'manual',
    participantIds: [],
    fixedParticipantId: null
  })
  assert.ok(errors.some(error => error.includes('valid drop-off/outbound time')))
  assert.ok(errors.some(error => error.includes('valid pickup/return time')))
})

test('weekday-specific evening times remain independent', () => {
  const preview = previewSchedule({
    startsOn: '2026-08-10',
    endsOn: '2026-08-21',
    sessions,
    strategy: 'round_robin_week',
    participants,
    anchorDate: '2026-08-10',
    outboundLabel: 'Class drop-off',
    returnLabel: 'Class pickup',
    maxOccurrences: 20
  })

  const firstThursday = preview.filter(item => item.serviceDate === '2026-08-13')
  const firstFriday = preview.filter(item => item.serviceDate === '2026-08-14')

  assert.deepEqual(firstThursday.map(item => item.time), ['18:30', '19:00'])
  assert.deepEqual(firstFriday.map(item => item.time), ['17:00', '18:00'])
  assert.deepEqual(firstThursday.map(item => item.label), ['Class drop-off', 'Class pickup'])
})

test('weekly rotation keeps every selected day and leg with one driver', () => {
  const preview = previewSchedule({
    startsOn: '2026-08-10',
    endsOn: '2026-08-28',
    sessions,
    strategy: 'round_robin_week',
    participants,
    anchorDate: '2026-08-10',
    maxOccurrences: 40
  })

  const byWeek = new Map()
  for (const row of preview) {
    if (!byWeek.has(row.blockKey)) byWeek.set(row.blockKey, [])
    byWeek.get(row.blockKey).push(row)
  }

  const weeks = [...byWeek.values()]
  assert.equal(weeks.length, 3)
  assert.deepEqual(new Set(weeks[0].map(item => item.participantName)), new Set(['Driver A']))
  assert.deepEqual(new Set(weeks[1].map(item => item.participantName)), new Set(['Driver B']))
  assert.deepEqual(new Set(weeks[2].map(item => item.participantName)), new Set(['Driver A']))
  assert.deepEqual(weeks.map(rows => rows.length), [4, 4, 4])
})

test('schedule validation accepts evening rides and rejects missing legs or drivers', () => {
  assert.deepEqual(validateScheduleDraft({
    startsOn: '2026-08-10',
    endsOn: '2026-10-30',
    sessions,
    strategy: 'round_robin_week',
    participantIds: participants.map(item => item.id),
    fixedParticipantId: null
  }), [])

  const invalidSession = createSessionDraft({
    name: 'No ride legs',
    weekday: 4,
    outboundEnabled: false,
    returnEnabled: false
  })
  const errors = validateScheduleDraft({
    startsOn: '2026-08-10',
    endsOn: '2026-10-30',
    sessions: [invalidSession],
    strategy: 'round_robin_week',
    participantIds: [],
    fixedParticipantId: null
  })

  assert.ok(errors.some(error => error.includes('enable drop-off, pickup, or both')))
  assert.ok(errors.some(error => error.includes('Select at least one driver')))
})

test('RPC session normalization preserves 24-hour values', () => {
  const normalized = sessions.map(normalizeSessionForRpc)
  assert.equal(normalized[0].outboundTime, '18:30')
  assert.equal(normalized[0].returnTime, '19:00')
  assert.equal(normalized[1].outboundTime, '17:00')
  assert.equal(normalized[1].returnTime, '18:00')
  assert.equal(formatTimeLabel('18:30'), '6:30 PM')
  assert.equal(formatTimeLabel('17:00'), '5:00 PM')
})
