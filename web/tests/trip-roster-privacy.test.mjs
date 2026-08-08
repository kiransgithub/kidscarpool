import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/25-trip-scoped-roster.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080006_kcp_trip_scoped_roster_privacy.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')

test('trip loading uses a role-aware RPC instead of broad table select', () => {
  assert.match(source, /table !== 'kcp_trips'/)
  assert.match(source, /kcp_group_trips/)
  assert.match(migration, /revoke select on table public\.kcp_trips from authenticated/)
  assert.match(migration, /membership_role = 'viewer'.*'\[\]'::jsonb/s)
})

test('child master rows are limited to own family or group administrators', () => {
  assert.match(migration, /drop policy if exists kcp_children_member_select/)
  assert.match(migration, /kcp_children_private_select/)
  assert.match(migration, /participant\.user_id = auth\.uid\(\)/)
  assert.match(migration, /public\.kcp_is_admin\(group_id\)/)
})

test('assigned driver roster access is limited to the ride window', () => {
  assert.match(migration, /trip\.scheduled_time - interval '60 minutes'/)
  assert.match(migration, /trip\.scheduled_time \+ interval '8 hours'/)
  assert.match(migration, /assigned_driver/)
  assert.match(migration, /kcp_sensitive_access_events/)
})

test('operational roster offers navigation and emergency actions without rendering for Viewer', () => {
  assert.match(source, /if \(kcpAccess\(\)\.isViewer\) return/)
  assert.match(source, /kcp_get_trip_operational_roster/)
  assert.match(source, /maps\.apple\.com/)
  assert.match(source, /tel:/)
  assert.match(source, /Sensitive roster access is logged/)
})

test('installed app refreshes privacy-scoped roster assets', () => {
  assert.match(worker, /v17-trip-roster-privacy/)
  assert.match(worker, /\.\/trip-roster\.css/)
})
