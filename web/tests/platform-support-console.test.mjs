import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const app = fs.readFileSync('web/platform-support/app.js', 'utf8')
const index = fs.readFileSync('web/platform-support/index.html', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080016_kcp_support_console_operations.sql', 'utf8')
const cases = fs.readFileSync('supabase/migrations/202608080017_kcp_support_console_cases.sql', 'utf8')
const heartbeat = fs.readFileSync('web/app.parts/33-client-heartbeat.js', 'utf8')

test('support console is separate and requires a platform administrator session', () => {
  assert.match(index, /KCP Platform Support/)
  assert.match(app, /kcp_support_me/)
  assert.match(app, /This account is not a platform administrator/)
  assert.doesNotMatch(app, /SUPABASE_SERVICE_ROLE_KEY|service_role/i)
  assert.match(migration, /kcp_is_platform_admin\('support_admin'\)/)
})

test('support can inspect all groups without unmasking people by default', () => {
  assert.match(app, /kcp_support_groups/)
  assert.match(app, /kcp_support_group_details/)
  assert.match(migration, /kcp_mask_support_text/)
  assert.match(migration, /owner_name_masked/)
  assert.match(cases, /invitations/)
})

test('sensitive access requires a reason, expires and is audited', () => {
  assert.match(index, /Specific support reason/)
  assert.match(app, /kcp_support_open_break_glass/)
  assert.match(app, /kcp_support_group_sensitive_details/)
  assert.match(app, /kcp_support_close_break_glass/)
  assert.match(migration, /expires_at/)
  assert.match(migration, /break_glass_data_viewed/)
})

test('support repairs are explicit and audited', () => {
  assert.match(app, /transferOwnership/)
  assert.match(app, /reissueInvitation/)
  assert.match(app, /changeGroupStatus/)
  assert.match(migration, /support_ownership_transferred/)
  assert.match(migration, /support_invitation_reissued/)
  assert.match(migration, /support_group_status_changed/)
})

test('normal PWA sends privacy-safe build heartbeats only', () => {
  assert.match(heartbeat, /kcp_register_client_heartbeat/)
  assert.match(heartbeat, /build_version/)
  assert.match(heartbeat, /active_group_id/)
  assert.doesNotMatch(heartbeat, /pickup_address|emergency|child_names|prompt/i)
})

test('support console includes cases and reference-code diagnostics', () => {
  assert.match(index, /Support cases/)
  assert.match(index, /Find an error reference/)
  assert.match(app, /kcp_support_cases_list/)
  assert.match(app, /kcp_support_errors/)
  assert.match(cases, /kcp_support_update_case/)
})
