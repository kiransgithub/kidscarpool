import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/23-adaptive-invitations.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080004_kcp_adaptive_invitations.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')

test('Viewer invitation needs no child and can never be assigned to drive', () => {
  assert.match(source, /role !== 'viewer'/)
  assert.match(source, /childVisible = role !== 'viewer'/)
  assert.match(source, /canDrive\.disabled = role === 'viewer'/)
  assert.match(migration, /case when p_role = 'viewer' then false/)
  assert.match(migration, /alter column child_name drop not null/)
})

test('Parent invitation requires a child while Admin child data is optional', () => {
  assert.match(source, /childRequired = role === 'parent'/)
  assert.match(migration, /p_role = 'parent' and normalized_child is null/)
  assert.match(source, /Admin.*Child information and driving are optional/s)
})

test('shared invitation is a deep link with a server-backed preview', () => {
  assert.match(source, /searchParams\.set\('invite', invitation\.token\)/)
  assert.match(source, /kcp_invitation_preview/)
  assert.match(source, /invitationAcceptDialog/)
  assert.match(source, /new URLSearchParams\(location\.search\)\.get\('invite'\)/)
})

test('Owner and Admin can rotate or revoke invitation codes', () => {
  assert.match(source, /resend-invite/)
  assert.match(source, /revoke-invite/)
  assert.match(migration, /kcp_resend_invitation/)
  assert.match(migration, /kcp_revoke_invitation/)
})

test('installed app refreshes adaptive invitation assets', () => {
  assert.match(worker, /v15-adaptive-invitations/)
  assert.match(worker, /\.\/adaptive-invitations\.css/)
})
