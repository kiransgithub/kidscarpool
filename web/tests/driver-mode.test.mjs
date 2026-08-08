import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/27-driver-mode.js', 'utf8')
const styles = fs.readFileSync('web/driver-mode.css', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080009_kcp_driver_execution.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')

test('driver mode is a focused full-screen execution flow', () => {
  assert.match(source, /driverModeDialog/)
  assert.match(source, /Pickup checklist/)
  assert.match(source, /Start ride/)
  assert.match(source, /Arrived at destination/)
  assert.match(source, /Confirm ride completed/)
  assert.match(styles, /height:\s*100dvh/)
  assert.match(styles, /min-height:\s*48px/)
})

test('child cards provide navigation, contact and accountability actions', () => {
  assert.match(source, /maps\.apple\.com/)
  assert.match(source, /href="tel:/)
  assert.match(source, /data-driver-child-action="picked_up"/)
  assert.match(source, /data-driver-child-action="skipped"/)
  assert.match(source, /Critical alert/)
  assert.match(migration, /kcp_mark_child_trip_status/)
})

test('safety-required groups block arrival until every child is accounted for', () => {
  assert.match(migration, /Account for every child as Picked up or Skipped/)
  assert.match(source, /group\.safetyRequired && !allAccounted/)
  assert.match(source, /Account for every child before reporting destination arrival/)
})

test('driver actions use idempotent client event identifiers', () => {
  assert.match(source, /driverClientEventId/)
  assert.match(source, /p_client_event_id/)
  assert.match(migration, /client_event_id/)
})

test('ride issues and destination arrival are auditable server events', () => {
  assert.match(migration, /kcp_report_trip_issue/)
  assert.match(migration, /issue_reported/)
  assert.match(migration, /kcp_report_destination_arrival/)
  assert.match(migration, /arrived_destination/)
})

test('installed app refreshes driver-mode assets', () => {
  assert.match(worker, /v19-driver-mode/)
  assert.match(worker, /\.\/driver-mode\.css/)
})
