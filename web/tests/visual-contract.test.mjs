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
  const [index, styles, agenda] = await Promise.all([
    text('web/index.html'),
    text('web/styles.css'),
    text('web/app.parts/21-all-group-home-navigation.js')
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
  assert.match(agenda, /agendaFocusIcon/)
  assert.match(agenda, /trip-driver-row/)
  assert.match(styles, /\.trip-focus-icon/)
  assert.match(styles, /\.trip-focus-card \.trip-driver-row[\s\S]*background:\s*rgba\(7,26,61,\.78\)[\s\S]*color:\s*#fff/)
})

test('usability controls remain additive and trip modal keeps stable layout hooks', async () => {
  const [index, fixes, enhancement, databaseDriven] = await Promise.all([
    text('web/index.html'),
    text('web/fixes.css'),
    text('web/app.parts/06.js'),
    text('web/app.parts/14-database-driven-ui.js')
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

  assert.match(databaseDriven, /A calendar is optional/)
  assert.match(databaseDriven, /p_events:\s*\[\]/)
  assert.match(fixes, /\.trip-modal-shell/)
  assert.match(fixes, /\.trip-detail-grid/)
  assert.match(fixes, /\.trip-child-row/)
  assert.match(enhancement, /Accepted coverage/)
  assert.match(enhancement, /10 minutes before the scheduled time/)
  assert.doesNotMatch(index, /BASIS|KCP-BASIS|Thanishka|Saanvi|Kavish|Ishi|Kiran|Mohan|Pavan|Santhosh/i)
})
