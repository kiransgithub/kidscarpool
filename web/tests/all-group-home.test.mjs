import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/21-all-group-home-navigation.js', 'utf8')
const styles = fs.readFileSync('web/all-group-home.css', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080003_kcp_all_group_agenda_requests.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')

test('primary navigation contains exactly five consumer destinations', () => {
  assert.match(source, /Home/)
  assert.match(source, /Schedule/)
  assert.match(source, /Requests/)
  assert.match(source, /Groups/)
  assert.match(source, /More/)
  assert.match(source, /grid-template-columns:\s*repeat\(5/)
})

test('Home and Schedule load rides across every active group membership', () => {
  assert.match(migration, /kcp_my_agenda/)
  assert.match(migration, /join public\.kcp_memberships/)
  assert.match(migration, /membership\.user_id = auth\.uid\(\)/)
  assert.match(source, /state\.allGroupAgenda/)
  assert.match(source, /group-context-badge/)
  assert.match(source, /allGroupScheduleFilter/)
})

test('requests feed combines cover and availability work across groups', () => {
  assert.match(migration, /kcp_my_requests/)
  assert.match(migration, /'cover'::text/)
  assert.match(migration, /'availability'::text/)
  assert.match(source, /allGroupRequestList/)
  assert.match(source, /requires_my_action/)
  assert.match(source, /data-action="accept-cover"/)
  assert.match(source, /data-action="review-constraint"/)
})

test('administrative utilities move behind More rather than primary tabs', () => {
  assert.match(source, /data-more-view="leaderboard"/)
  assert.match(source, /data-more-view="calendar"/)
  assert.match(source, /data-more-view="settings"/)
  assert.match(styles, /\.more-grid/)
})

test('installed app refreshes the all-group experience', () => {
  assert.match(worker, /v13-all-group-home/)
  assert.match(worker, /\.\/all-group-home\.css/)
})
