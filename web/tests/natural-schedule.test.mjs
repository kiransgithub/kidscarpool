import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import {
  parseNaturalSchedule,
  formatNaturalUnderstanding
} from '../natural-schedule.js'

const participants = [
  { id: 'driver-a', display_name: 'Driver A', status: 'active', can_drive: true },
  { id: 'driver-b', display_name: 'Driver B', status: 'active', can_drive: true }
]

const source = fs.readFileSync('web/app.parts/35-natural-language-schedule.js','utf8')
const worker = fs.readFileSync('web/service-worker-v24.js','utf8')

test('evening weekday times and weekly driver order are understood', () => {
  const result = parseNaturalSchedule(
    'Thursday 6:30pm to 7pm and Friday 5pm to 6pm. Driver A and Driver B alternate weekly.',
    { participants, startsOn: '2026-08-10' }
  )

  assert.equal(result.canApply,true)
  assert.equal(result.strategy,'round_robin_week')
  assert.deepEqual(result.participantIds,['driver-a','driver-b'])
  assert.deepEqual(
    result.sessions.map(session => [session.weekday,session.outboundTime,session.returnTime]),
    [[4,'18:30','19:00'],[5,'17:00','18:00']]
  )
  assert.match(formatNaturalUnderstanding(result),/Thursday: 6:30 PM to 7:00 PM/)
  assert.match(result.assignmentSummary,/Driver A → Driver B/)
})

test('ambiguous times require clarification instead of silently choosing AM or PM', () => {
  const result = parseNaturalSchedule(
    'Thursday 6:30 to 7 and Friday 5 to 6. Driver A and Driver B alternate weekly.',
    { participants, startsOn: '2026-08-10' }
  )

  assert.equal(result.canApply,false)
  assert.ok(result.questions.some(question => /specify AM or PM/i.test(question)))
  assert.equal(result.sessions[0].outboundTime,'')
  assert.equal(result.sessions[0].returnTime,'')
})

test('one missing meridiem can be inferred only with a visible warning', () => {
  const result = parseNaturalSchedule(
    'Thursday 6:30 to 7pm. Driver A handles every ride.',
    { participants, startsOn: '2026-08-10' }
  )

  assert.equal(result.canApply,true)
  assert.equal(result.strategy,'fixed')
  assert.equal(result.sessions[0].outboundTime,'18:30')
  assert.equal(result.sessions[0].returnTime,'19:00')
  assert.ok(result.warnings.some(warning => /interpreted 6:30 as PM/i.test(warning)))
})

test('grouped weekdays share an explicitly stated common range', () => {
  const result = parseNaturalSchedule(
    'Thursday and Friday 5pm to 6pm. Assign later.',
    { participants, startsOn: '2026-08-10' }
  )

  assert.equal(result.canApply,true)
  assert.equal(result.strategy,'manual')
  assert.deepEqual(
    result.sessions.map(session => [session.weekday,session.outboundTime,session.returnTime]),
    [[4,'17:00','18:00'],[5,'17:00','18:00']]
  )
  assert.ok(result.warnings.some(warning => /Thursday uses the same times as Friday/i.test(warning)))
})

test('unknown rotation names are not converted into fake participants', () => {
  const result = parseNaturalSchedule(
    'Thursday 6pm to 7pm. Driver A and Unknown Driver alternate weekly.',
    { participants, startsOn: '2026-08-10' }
  )

  assert.equal(result.canApply,false)
  assert.deepEqual(result.participantIds,['driver-a'])
  assert.ok(result.questions.some(question => /Unknown Driver.*could not be matched/i.test(question)))
})

test('pickup-only and overnight phrases map to structured ride legs', () => {
  const pickupOnly = parseNaturalSchedule(
    'Monday pickup only at 11:30pm. Assign later.',
    { startsOn: '2026-08-10' }
  )
  assert.equal(pickupOnly.canApply,true)
  assert.equal(pickupOnly.sessions[0].outboundEnabled,false)
  assert.equal(pickupOnly.sessions[0].returnEnabled,true)
  assert.equal(pickupOnly.sessions[0].returnTime,'23:30')

  const overnight = parseNaturalSchedule(
    'Saturday 11pm to 12:30am next day. Assign later.',
    { startsOn: '2026-08-10' }
  )
  assert.equal(overnight.canApply,true)
  assert.equal(overnight.sessions[0].returnDayOffset,1)
})

test('analysis and confirmation never save or publish directly', () => {
  assert.match(source,/Check my description/)
  assert.match(source,/What KCP understood/)
  assert.match(source,/Nothing has been saved/)
  assert.match(source,/Apply to weekly matrix/)
  assert.doesNotMatch(source,/kcp_publish_schedule_plan/)
  assert.doesNotMatch(source,/kcp_save_schedule_plan/)
})

test('plain-language apply uses only active database participant identifiers', () => {
  assert.match(source,/state\.scheduleBuilder\?\.participants/)
  assert.match(source,/participant\.status === 'active' && participant\.can_drive/)
  assert.match(source,/selectedScheduleParticipants = new Set\(result\.participantIds\)/)
  assert.match(source,/markSchedulePreviewStale/)
})

test('release worker caches natural-language parser and styles', () => {
  assert.match(worker,/kcp-community-v25-natural-schedule/)
  assert.match(worker,/\.\/natural-schedule\.js/)
  assert.match(worker,/\.\/natural-schedule\.css/)
})
