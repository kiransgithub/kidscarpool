import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/32-fairness-ledger.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080015_kcp_fairness_gamification.sql', 'utf8')

test('fairness is presented as workload rather than a competitive score', () => {
  assert.match(source, /WORKLOAD, NOT A SCORE/)
  assert.match(source, /Completed rides are the base/)
  assert.match(source, /estimated_minutes/)
  assert.match(source, /children_transported/)
  assert.match(migration, /fairness_time_weight/)
  assert.match(migration, /fairness_child_weight/)
})

test('operational fairness and gamification remain separate', () => {
  assert.match(source, /Volunteer points are displayed separately/)
  assert.match(migration, /points_enabled/)
  assert.match(migration, /public_leaderboard_enabled/)
  assert.match(migration, /if not enabled then return 0/)
})

test('group manager can disable points or public participation', () => {
  assert.match(source, /groupPointsEnabled/)
  assert.match(source, /groupPublicLeaderboard/)
  assert.match(source, /kcp_set_participation_settings/)
  assert.match(migration, /Owner or Admin role required/)
})

test('private participation returns only the current parent while managers retain the group view', () => {
  assert.match(migration, /group_record\.public_leaderboard_enabled/)
  assert.match(migration, /caller_role in \('owner','admin'\)/)
  assert.match(migration, /totals\.user_id = auth\.uid\(\)/)
})

test('Viewer receives no operational fairness rows', () => {
  assert.match(source, /kcpAccess\(\)\.isViewer/)
  assert.match(source, /Participation details are available to driving members/)
  assert.match(migration, /if caller_role = 'viewer' then return/)
})
