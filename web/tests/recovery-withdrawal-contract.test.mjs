import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile, access } from 'node:fs/promises'
import { constants } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

async function text(relative) {
  return readFile(path.join(repoRoot, relative), 'utf8')
}

async function exists(relative) {
  try {
    await access(path.join(repoRoot, relative), constants.F_OK)
    return true
  } catch {
    return false
  }
}

test('production no longer contains a preloaded-person claim-state UI', async () => {
  assert.equal(await exists('web/app.parts/05.js'), false)
  assert.equal(await exists('web/app.parts/09.js'), false)

  const source = await text('web/app.parts/15-generic-recovery.js')
  assert.doesNotMatch(source, /seededPilotStatus|claim_state|open-basis-recovery/i)
  assert.match(source, /No group code or member identity is embedded/i)
  assert.match(source, /recoverGroupCode'\)\.value\.trim/)
  assert.match(source, /recoverParentName'\)\.value\.trim/)
})

test('generic recovery UI and invitation restoration language remain present', async () => {
  const [index, bootstrap, recovery] = await Promise.all([
    text('web/index.html'),
    text('web/app.parts/00.js'),
    text('web/app.parts/15-generic-recovery.js')
  ])

  assert.match(index, /id="recoverGroupDialog"/)
  assert.match(index, /id="recoverGroupForm"/)
  assert.match(index, /Join \/ restore with invite/)
  assert.match(index, /placeholder="Group code"/)
  assert.match(index, /placeholder="Member name"/)
  assert.match(bootstrap, /storage:\s*kcpAuthStorage/)
  assert.match(bootstrap, /restoreRememberedMemberships/)
  assert.match(bootstrap, /rememberGroup\(data\[0\]\.group_id\)/)
  assert.match(recovery, /kcp_recover_seeded_roster/)
})

test('generic recovery modal close controls cannot submit the form', async () => {
  const source = await text('web/app.parts/15-generic-recovery.js')

  assert.match(source, /kcpGenericRecoveryClose\.type = 'button'/)
  assert.match(source, /removeAttribute\('formmethod'\)/)
  assert.match(source, /kcpGenericRecoveryDialog\.close\('cancel'\)/)
  assert.match(source, /addEventListener\('cancel'/)
  assert.match(source, /event\.target === kcpGenericRecoveryDialog/)
})

test('recovery uses values entered by the user and refreshes cloud data after success', async () => {
  const source = await text('web/app.parts/15-generic-recovery.js')

  assert.match(source, /recoverGroupCode'\)\.value\.trim\(\)\.toUpperCase\(\)/)
  assert.match(source, /recoverParentName'\)\.value\.trim\(\)/)
  assert.match(source, /recoverCode'\)\.value\.trim\(\)\.toUpperCase\(\)/)
  assert.match(source, /p_group_code:\s*groupCode/)
  assert.match(source, /p_parent_name:\s*memberName/)
  assert.match(source, /p_recovery_code:\s*recoveryCode/)
  assert.match(source, /await rememberGroup\(recovered\.group_id/)
  assert.match(source, /await refreshAll\(\)/)
  assert.doesNotMatch(source, /KCP-BASIS|\bKiran\b|BASIS Phoenix/i)
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

test('service worker preserves durable access and advances with database-driven modules', async () => {
  const worker = await text('web/service-worker.js')
  const version = worker.match(/kcp-pilot-v(\d+)-/)?.[1]

  assert.ok(version, 'Service-worker cache must contain a numeric application version')
  assert.ok(Number(version) >= 9, `Expected cache version 9 or newer, found ${version}`)
  assert.match(worker, /\.\/persistence\.js/)
  assert.match(worker, /\.\/generic-schedule\.js/)
  assert.match(worker, /\.\/generic-schedule\.css/)
})
