import test from 'node:test'
import assert from 'node:assert/strict'
import {
  acceptedCoverForTrip,
  coverAcceptedLabel,
  orderTripsByProximity,
  tripStartGate,
  upcomingActionableTrips
} from '../logic.js'

const trip = (id, scheduled_time, kind = 'morning_drop', status = 'scheduled') => ({
  id,
  trip_date: scheduled_time.slice(0, 10),
  scheduled_time,
  kind,
  status
})

test('nearest current trip is ordered first, including same-day drop before pickup', () => {
  const now = new Date('2026-08-10T06:50:00-07:00')
  const input = [
    trip('pickup', '2026-08-10T15:35:00-07:00', 'afternoon_pickup'),
    trip('tomorrow', '2026-08-11T07:00:00-07:00'),
    trip('drop', '2026-08-10T07:00:00-07:00')
  ]
  assert.deepEqual(orderTripsByProximity(input, now).map(item => item.id), ['drop', 'pickup', 'tomorrow'])
})

test('after the morning trip, the afternoon pickup becomes the nearest upcoming trip', () => {
  const now = new Date('2026-08-10T08:00:00-07:00')
  const input = [
    trip('drop', '2026-08-10T07:00:00-07:00'),
    trip('pickup', '2026-08-10T15:35:00-07:00', 'afternoon_pickup')
  ]
  assert.equal(upcomingActionableTrips(input, now)[0].id, 'pickup')
  assert.deepEqual(orderTripsByProximity(input, now).map(item => item.id), ['pickup', 'drop'])
})

test('start gate requires ready state, opens ten minutes before and closes after ninety minutes', () => {
  const unconfirmed = trip('drop', '2026-08-10T07:00:00-07:00', 'morning_drop', 'scheduled')
  assert.equal(tripStartGate(unconfirmed, new Date('2026-08-10T06:55:00-07:00')).allowed, false)
  assert.match(tripStartGate(unconfirmed, new Date('2026-08-10T06:55:00-07:00')).reason, /Confirm the ride/)

  const ready = trip('drop', '2026-08-10T07:00:00-07:00', 'morning_drop', 'ready')
  assert.equal(tripStartGate(ready, new Date('2026-08-10T06:49:59-07:00')).allowed, false)
  assert.equal(tripStartGate(ready, new Date('2026-08-10T06:50:00-07:00')).allowed, true)
  assert.equal(tripStartGate(ready, new Date('2026-08-10T08:30:00-07:00')).allowed, true)
  assert.equal(tripStartGate(ready, new Date('2026-08-10T08:30:01-07:00')).allowed, false)
})

test('confirmation and completion-due states remain actionable', () => {
  const now = new Date('2026-08-10T08:00:00-07:00')
  const input = [
    trip('confirmation', '2026-08-10T07:00:00-07:00', 'morning_drop', 'confirmation_due'),
    trip('completion', '2026-08-10T06:30:00-07:00', 'morning_drop', 'completion_due'),
    trip('later', '2026-08-10T10:00:00-07:00')
  ]
  const ids = upcomingActionableTrips(input, now).map(item => item.id)
  assert.ok(ids.includes('completion'))
  assert.ok(ids.includes('later'))
})

test('accepted cover identifies the accepting driver', () => {
  const requests = [{ id: 'r1', trip_id: 't1', status: 'accepted', accepted_by: 'u2' }]
  const memberships = [{ user_id: 'u2', parent_name: 'Driver B' }]
  const request = acceptedCoverForTrip(requests, 't1')
  assert.equal(request.id, 'r1')
  assert.equal(coverAcceptedLabel(request, memberships), 'Accepted by Driver B')
})
