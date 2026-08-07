import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

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

test('service worker caches the persistent storage module and advances its cache version', async () => {
  const worker = await text('web/service-worker.js')
  assert.match(worker, /kcp-pilot-v4-recovery-withdrawal/)
  assert.match(worker, /\.\/persistence\.js/)
})
