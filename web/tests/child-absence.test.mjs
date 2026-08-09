import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/28-child-absence.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080010_kcp_child_absence_reports.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker-v24.js', 'utf8')

test('parent can report one ride or a date range with common absence reasons', () => {
  assert.match(source, /Child is not riding/)
  assert.match(source, /Date or date range/)
  assert.match(source, /picked_up_separately/)
  assert.match(source, /student_hours/)
  assert.match(source, /after_school_activity/)
  assert.match(migration, /kcp_report_child_absence/)
})

test('Home and Requests expose reversible child ride updates', () => {
  assert.match(source, /childAbsenceQuickAction/)
  assert.match(source, /allGroupRequestList/)
  assert.match(source, /Child is riding again/)
  assert.match(source, /kcp_cancel_child_absence/)
})

test('driver snapshot marks a reported absence as not riding', () => {
  assert.match(migration, /kcp_driver_trip_snapshot_base/)
  assert.match(migration, /absence_reason/)
  assert.match(migration, /'child_skipped'/)
  assert.match(source, /driver-reported-absence/)
})

test('Viewer portfolio does not receive the absence reporting quick action', () => {
  assert.match(source, /kcpRolePortfolio\(\)\.viewerOnly/)
})

test('installed app refreshes child absence assets', () => {
  assert.match(worker, /v24-offline-accessibility/)
  assert.match(worker, /\.\/child-absence\.css/)
})
