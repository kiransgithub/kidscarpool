import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/20-user-safe-errors.js', 'utf8')
const builder = fs.readFileSync('web/build-runtime.mjs', 'utf8')
const worker = fs.readFileSync('web/service-worker-v24.js', 'utf8')

test('family connectivity uses generic online, syncing and offline language', () => {
  assert.match(source, /Online · synced just now/)
  assert.match(source, /Syncing…/)
  assert.match(source, /Offline — changes will sync/)
  assert.match(builder, /Connecting to Supabase….*Connecting…/s)
  assert.match(builder, /Connected securely to Supabase\..*Online/s)
})

test('unexpected backend errors create a support reference instead of exposing internals', () => {
  assert.match(source, /kcp_report_client_error/)
  assert.match(source, /Reference:/)
  assert.match(source, /Your data was not changed/)
  assert.match(source, /duplicate key.*DATA_CONFLICT/s)
  assert.match(source, /sqlstate.*DATABASE_RULE/is)
})

test('known validation and permission errors remain actionable', () => {
  assert.match(source, /You do not have permission/)
  assert.match(source, /invitation has expired/i)
  assert.match(source, /10 minutes before its scheduled time/)
})

test('installed app refreshes user-safe error handling', () => {
  assert.match(worker, /v24-offline-accessibility/)
})
