import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/29-cover-escalation-swaps.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080011_kcp_cover_escalation_swaps.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')

test('cover requests expose response deadlines and three escalation stages', () => {
  assert.match(migration, /respond_by/)
  assert.match(migration, /eligible_drivers/)
  assert.match(migration, /group_admin/)
  assert.match(migration, /unresolved/)
  assert.match(source, /Respond by/)
  assert.match(source, /Coverage unresolved/)
})

test('escalation never silently assigns a driver', () => {
  const process = migration.slice(migration.indexOf('create or replace function public.kcp_process_cover_escalations'))
  assert.match(process, /escalation_stage/)
  assert.doesNotMatch(process, /actual_driver_id\s*=/)
  assert.doesNotMatch(process, /scheduled_driver_id\s*=/)
})

test('swap request identifies two future rides and requires the other driver response', () => {
  assert.match(source, /Request ride swap/)
  assert.match(source, /Ride you would take instead/)
  assert.match(source, /Accept swap/)
  assert.match(source, /Decline/)
  assert.match(migration, /requested_from <> auth\.uid\(\)/)
})

test('accepted swap exchanges drivers atomically and resets confirmation', () => {
  assert.match(migration, /newOfferedDriver/)
  assert.match(migration, /newRequestedDriver/)
  assert.match(migration, /confirmationReset/)
  assert.match(migration, /confirmed_at = null/)
  assert.match(migration, /status = 'scheduled'/)
})

test('installed app refreshes coverage and swap assets', () => {
  assert.match(worker, /v21-cover-swaps/)
  assert.match(worker, /\.\/cover-swaps\.css/)
})
