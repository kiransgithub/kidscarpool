import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import {
  normalizeRecoveryCode,
  recoveryErrorMessage,
  resolveRecoveryAttempt
} from '../logic.js'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

async function text(relative) {
  return readFile(path.join(repoRoot, relative), 'utf8')
}

test('seeded pilot distinguishes available, current and another-device claim states', async () => {
  const source = await text('web/app.parts/05.js')

  assert.match(source, /claim_state/)
  assert.match(source, /available:/)
  assert.match(source, /current_user:/)
  assert.match(source, /another_device:/)
  assert.match(source, /Recover group access/)
  assert.match(source, /data-seeded-claim-state/)
})

test('recovery UI and invitation restoration language remain present', async () => {
  const [index, bootstrap] = await Promise.all([
    text('web/index.html'),
    text('web/app.parts/00.js')
  ])

  assert.match(index, /id="recoverGroupDialog"/)
  assert.match(index, /id="recoverGroupForm"/)
  assert.match(index, /Join \/ restore with invite/)
  assert.match(bootstrap, /storage:\s*kcpAuthStorage/)
  assert.match(bootstrap, /restoreRememberedMemberships/)
  assert.match(bootstrap, /rememberGroup\(data\[0\]\.group_id\)/)
})

test('recovery modal close button cannot submit the recovery form', async () => {
  const source = await text('web/app.parts/09.js')

  assert.match(source, /kcpRecoveryCloseButton\.type = 'button'/)
  assert.match(source, /removeAttribute\('formmethod'\)/)
  assert.match(source, /data-action="close-recovery-dialog"|dataset\.action = 'close-recovery-dialog'/)
  assert.match(source, /closeRecoveryDialog/)
  assert.match(source, /kcpRecoveryDialog\.close\('cancel'\)/)
  assert.match(source, /addEventListener\('cancel'/)
})

test('recovery modal exposes progress and errors inside the visible dialog', async () => {
  const [source, fixes] = await Promise.all([
    text('web/app.parts/09.js'),
    text('web/fixes.css')
  ])

  assert.match(source, /recoverGroupStatus/)
  assert.match(source, /aria-live/)
  assert.match(source, /setRecoveryStatus\('Checking the roster and one-time recovery code/)
  assert.match(source, /recoveryErrorMessage\(error\)/)
  assert.match(source, /setRecoveryBusy\(false\)/)
  assert.match(fixes, /\.recovery-dialog-status\.error/)
  assert.match(fixes, /\.recovery-dialog-status\.success/)
})

test('recovery is idempotent when the database committed before the client refreshed', () => {
  const result = resolveRecoveryAttempt({
    rpcError: new Error('Recovery code is invalid, expired, or already used'),
    status: {
      group_id: 'group-1',
      group_code: 'KCP-BASIS-2026-27',
      claim_state: 'current_user'
    }
  })

  assert.equal(result.ok, true)
  assert.equal(result.alreadyRecovered, true)
  assert.equal(result.groupId, 'group-1')
})

test('recovery code normalization and user-facing error text remain stable', () => {
  assert.equal(normalizeRecoveryCode('  rec-ab12-cd34  '), 'REC-AB12-CD34')
  assert.match(
    recoveryErrorMessage(new Error('Recovery code is invalid, expired, or already used')),
    /Issue a new one-time code/
  )
})

test('open cover requests expose withdrawal without changing the existing trip layout', async () => {
  const [enhancement, fixes] = await Promise.all([
    text('web/app.parts/08.js'),
    text('web/fixes.css')
  ])

  assert.match(enhancement, /data-action="withdraw-cover"/)
  assert.match(enhancement, /kcp_withdraw_cover/)
  assert.match(enhancement, /Only an open cover request|no longer open/i)
  assert.match(fixes, /\.trip-modal-shell/)
  assert.match(fixes, /\.trip-detail-grid/)
})

test('service worker preserves durable access and advances with new app modules', async () => {
  const worker = await text('web/service-worker.js')
  const version = worker.match(/kcp-pilot-v(\d+)-/)?.[1]

  assert.ok(version, 'Service-worker cache must contain a numeric application version')
  assert.ok(Number(version) >= 6, `Expected cache version 6 or newer, found ${version}`)
  assert.match(worker, /\.\/persistence\.js/)
  assert.match(worker, /\.\/generic-schedule\.js/)
  assert.match(worker, /\.\/generic-schedule\.css/)
})
