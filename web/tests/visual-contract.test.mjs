import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

async function text(relative) {
  return readFile(path.join(repoRoot, relative), 'utf8')
}

test('existing KCP theme and navigation remain intact', async () => {
  const [index, styles] = await Promise.all([
    text('web/index.html'),
    text('web/styles.css')
  ])

  assert.match(styles, /--navy:\s*#071a3d/)
  assert.match(styles, /--blue:\s*#155eef/)
  assert.match(styles, /\.topbar\s*\{/)
  assert.match(styles, /\.trip-focus-card\.morning/)
  assert.match(styles, /\.trip-focus-card\.pickup/)
  assert.equal((index.match(/class="nav-item/g) || []).length, 7)
  assert.match(index, /KIDSCARPOOL/)
  assert.match(index, /nextDropCard/)
  assert.match(index, /nextPickupCard/)
})

test('new usability controls are additive and trip modal has stable layout hooks', async () => {
  const [index, fixes, enhancement] = await Promise.all([
    text('web/index.html'),
    text('web/fixes.css'),
    text('web/app.parts/06.js')
  ])

  for (const id of [
    'newGroupType',
    'newScheduleStart',
    'newScheduleEnd',
    'newDropTime',
    'newPickupTime',
    'newAutoCompleteMinutes'
  ]) {
    assert.match(index, new RegExp(`id="${id}"`))
  }

  assert.match(index, /A school or activity calendar is optional/)
  assert.match(fixes, /\.trip-modal-shell/)
  assert.match(fixes, /\.trip-detail-grid/)
  assert.match(fixes, /\.trip-child-row/)
  assert.match(enhancement, /Accepted coverage/)
  assert.match(enhancement, /10 minutes before the scheduled time/)
  assert.match(enhancement, /calendar upload is optional/)
})
