import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const support = fs.readFileSync('web/support/app.js', 'utf8')
const platform = fs.readFileSync('web/app.parts/19-platform-admin.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080002_kcp_platform_admin_support.sql', 'utf8')

test('platform role is separate from group membership', () => {
  assert.match(migration, /create table if not exists public\.kcp_platform_admins/)
  assert.match(migration, /kcp_is_platform_admin/)
  assert.match(platform, /kcp_platform_role/)
  assert.match(platform, /state\.platformRole/)
})

test('Super Admin can search every group through a protected RPC', () => {
  assert.match(migration, /kcp_admin_list_groups/)
  assert.match(migration, /Platform administrator role required/)
  assert.match(support, /kcp_admin_list_groups/)
  assert.match(support, /Search group name, code or destination|groupSearch/)
})

test('support errors use reference codes and break-glass access is audited', () => {
  assert.match(migration, /kcp_client_error_events/)
  assert.match(migration, /KCP-/)
  assert.match(migration, /kcp_break_glass_events/)
  assert.match(migration, /break_glass_opened/)
  assert.match(support, /Temporary support access/)
})

test('family app exposes support console only after platform-role lookup', () => {
  assert.match(platform, /if \(!state\.platformRole/)
  assert.match(platform, /\.\/support\//)
})
