import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/18-permanent-auth.js', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080001_kcp_permanent_identity_devices.sql', 'utf8')

test('anonymous users can link a verified email without replacing their user id', () => {
  assert.match(source, /supabase\.auth\.updateUser/)
  assert.match(source, /emailRedirectTo/)
  assert.match(source, /kcp_record_identity_upgrade/)
  assert.match(source, /existing groups, roles, schedules, trips and points stay attached/i)
})

test('permanent users can request an email sign-in link on another device', () => {
  assert.match(source, /supabase\.auth\.signInWithOtp/)
  assert.match(source, /shouldCreateUser:\s*false/)
  assert.match(source, /Email sign in/)
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
  assert.match(worker, /v10-permanent-account/)
  assert.match(worker, /\.\/account-auth\.css/)
})
