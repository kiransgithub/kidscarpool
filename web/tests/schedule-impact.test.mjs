import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/31-schedule-templates-impact.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080013_kcp_schedule_templates_impact.sql', 'utf8')
const security = fs.readFileSync('supabase/migrations/202608080014_kcp_schedule_impact_security.sql', 'utf8')

test('templates prefill the generic plan without embedded clock times', () => {
  assert.match(migration, /school_weekdays/)
  assert.match(migration, /single_activity/)
  assert.match(migration, /weekly_rotation/)
  assert.match(migration, /pickup_only/)
  assert.match(migration, /custom/)
  const templateSection = migration.slice(migration.indexOf("('school_weekdays'"), migration.indexOf('create table if not exists public.kcp_schedule_change_sets'))
  assert.doesNotMatch(templateSection, /\b(?:0?7:00|15:35|18:30|17:00)\b/)
  assert.match(source, /Enter the actual days and times/)
})

test('quick actions copy times, select drivers and configure weekly or pickup-only patterns', () => {
  assert.match(source, /copy-first-ride-times/)
  assert.match(source, /select-all-schedule-drivers/)
  assert.match(source, /alternate-weekly/)
  assert.match(source, /make-pickup-only/)
  assert.match(source, /round_robin_week/)
  assert.match(source, /outboundEnabled: false/)
})

test('schedule check calls the server change engine before making rides live', () => {
  assert.match(source, /kcp_prepare_schedule_change/)
  assert.match(source, /kcp_schedule_change_details/)
  assert.match(source, /activeScheduleChangeSetId/)
  assert.match(source, /Check the latest rides before making the schedule live/)
  assert.match(source, /kcp_publish_schedule_plan_v3/)
})

test('change view shows ride changes, overlaps and urgent driver confirmation', () => {
  assert.match(source, /CHANGES TO REVIEW/)
  assert.match(source, /Time changes/)
  assert.match(source, /Driver changes/)
  assert.match(source, /Rides that overlap another group/)
  assert.match(source, /Changes within 24 hours/)
  assert.match(migration, /cross_group_conflict/)
  assert.match(migration, /kcp_schedule_acknowledgements/)
})

test('affected drivers can confirm or report schedule changes from Updates', () => {
  assert.match(source, /Confirm changes/)
  assert.match(source, /Report a problem/)
  assert.match(source, /kcp_acknowledge_schedule_change/)
  assert.match(source, /kcp_my_schedule_acknowledgements/)
})

test('browser roles cannot bypass impact review through the renamed base publisher', () => {
  assert.match(security, /revoke all on function public\.kcp_publish_schedule_plan_base/)
  assert.match(security, /from public, anon, authenticated/)
  assert.match(security, /Owner or Admin role required to inspect an unpublished schedule preview/)
})
