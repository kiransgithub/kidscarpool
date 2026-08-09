import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/18-permanent-auth.js', 'utf8')
const bootstrap = fs.readFileSync('web/app.parts/00.js', 'utf8')
const workspace = fs.readFileSync('web/app.parts/01.js', 'utf8')
const worker = fs.readFileSync('web/service-worker-v24.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080001_kcp_permanent_identity_devices.sql', 'utf8')
const resumeMigration = fs.readFileSync('supabase/migrations/202608090002_kcp_verified_email_session_resume.sql', 'utf8')

test('anonymous users can link a verified email without replacing their user id', () => {
  assert.match(source, /supabase\.auth\.updateUser/)
  assert.match(source, /emailRedirectTo/)
  assert.match(source, /kcp_record_identity_upgrade/)
  assert.match(source, /existing groups, roles, schedules, trips and points stay attached/i)
})

test('email onboarding supports new verified accounts and existing-account sign in', () => {
  assert.match(source, /supabase\.auth\.signInWithOtp/)
  assert.match(source, /shouldCreateUser:\s*true/)
  assert.match(source, /enter a new email to create your verified KCP account/i)
  assert.match(source, /Email sign in/)
})

test('returning verified sessions resume their profile, groups and Home screen', () => {
  assert.match(source, /ensureVerifiedKcpAccount/)
  assert.match(source, /kcp_resume_verified_account/)
  assert.match(source, /enterApp\(\{ view: 'home' \}\)/)
  assert.match(bootstrap, /returningSession/)
  assert.match(bootstrap, /ensureVerifiedKcpAccount/)
  assert.match(workspace, /ensureRememberedGroups\(\)/)
  assert.match(resumeMigration, /lower\(profile\.account_email\) = lower\(auth_user\.email\)/)
  assert.match(resumeMigration, /kcp_transfer_group_membership/)
})

test('email configuration failures are explained clearly', () => {
  assert.match(source, /otp_disabled/)
  assert.match(source, /Email sign-in is disabled for this KCP environment/)
})

test('device registry is user-scoped and supports removal', () => {
  assert.match(migration, /create table if not exists public\.kcp_devices/)
  assert.match(migration, /using \(user_id = auth\.uid\(\)\)/)
  assert.match(migration, /kcp_register_device/)
  assert.match(migration, /kcp_revoke_device/)
  assert.match(source, /kcpDeviceId/)
  assert.match(source, /revoke-account-device/)
})

test('installed app refreshes permanent account assets', () => {
  assert.match(worker, /v24-offline-accessibility/)
  assert.match(worker, /\.\/account-auth\.css/)
})

test('settings exposes a sign out that removes remembered device access', () => {
  assert.match(source, /data-action="sign-out"/)
  assert.match(source, /removeDeviceLink/)
  assert.match(source, /supabase\.auth\.signOut/)
})
