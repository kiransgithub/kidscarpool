import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/26-safe-trip-state.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080007_kcp_safe_trip_state_machine.sql', 'utf8')
const coverMigration = fs.readFileSync('supabase/migrations/202608080008_kcp_safe_cover_states.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')

test('time lifecycle never auto-completes a ride or awards points', () => {
  const lifecycle = migration.slice(migration.indexOf('create or replace function public.kcp_process_trip_lifecycle'))
  assert.match(lifecycle, /confirmation_due/)
  assert.match(lifecycle, /completion_due/)
  assert.match(lifecycle, /unconfirmed/)
  assert.match(lifecycle, /'completed', 0/)
  assert.match(lifecycle, /'pointsAwarded', 0/)
  assert.doesNotMatch(lifecycle, /perform public\.kcp_award_confirmed_trip_points/)
})

test('driver flow requires confirmation, start, arrival and explicit completion', () => {
  assert.match(source, /data-action="confirm-trip"/)
  assert.match(source, /data-action="safe-start-trip"/)
  assert.match(source, /data-action="report-arrival"/)
  assert.match(source, /data-action="confirm-completion"/)
  assert.match(source, /kcp_confirm_trip/)
  assert.match(source, /kcp_confirm_trip_completion/)
  assert.match(migration, /status = 'ready'/)
  assert.match(migration, /status = 'completion_due'/)
})

test('points are awarded only by confirmed completion', () => {
  assert.match(migration, /Points require a confirmed completed trip/)
  assert.match(migration, /kcp_award_confirmed_trip_points/)
  assert.match(migration, /completion_confirmed/)
  assert.match(migration, /admin_completion_confirmed/)
})

test('accepted volunteers must reconfirm and can release before the ride starts', () => {
  assert.match(coverMigration, /confirmationRequired/)
  assert.match(coverMigration, /confirmed_at = null/)
  assert.match(coverMigration, /kcp_release_accepted_cover/)
  assert.match(source, /release-accepted-cover/)
})

test('unconfirmed ride is visibly different from completed ride', () => {
  assert.match(source, /Driver confirmation due/)
  assert.match(source, /Completion confirmation due/)
  assert.match(source, /This ride is not recorded as completed/)
  assert.match(source, /tripEventTimeline/)
})

test('installed app refreshes safe-state assets', () => {
  assert.match(worker, /v18-safe-trip-state/)
  assert.match(worker, /\.\/safe-trip-state\.css/)
})
