import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

async function text(relative) {
  return readFile(path.join(repoRoot, relative), 'utf8')
}

test('schedule and group close controls cannot submit their forms', async () => {
  const source = await text('web/app.parts/11-schedule-builder-usability.js')

  assert.match(source, /prepareExplicitDialogClose/)
  assert.match(source, /closeButton\.type = 'button'/)
  assert.match(source, /removeAttribute\('formmethod'\)/)
  assert.match(source, /close-schedule-builder-dialog/)
  assert.match(source, /close-generic-group-dialog/)
  assert.match(source, /dialog\.close\('cancel'\)/)
  assert.match(source, /addEventListener\('cancel'/)
})

test('schedule setup uses progressive disclosure without removing capabilities', async () => {
  const [dialogs, enhancement] = await Promise.all([
    text('web/app.parts/09a-generic-dialogs.js'),
    text('web/app.parts/11-schedule-builder-usability.js')
  ])

  assert.match(enhancement, /schedule-progress/)
  assert.match(enhancement, /data-schedule-step-panel/)
  assert.match(enhancement, /scheduleBasicsAdvanced/)
  assert.match(enhancement, /schedule-session-advanced/)
  assert.match(enhancement, /scheduleRotationAdvanced/)
  assert.match(enhancement, /Preview the latest changes before publishing/)

  // The simplified presentation must keep every original feature control.
  for (const id of [
    'schedulePlanName',
    'scheduleStartsOn',
    'scheduleEndsOn',
    'scheduleOutboundLabel',
    'scheduleReturnLabel',
    'scheduleAutoComplete',
    'scheduleSessionsList',
    'scheduleStrategy',
    'scheduleAnchorDate',
    'scheduleCycleBehavior',
    'scheduleFixedParticipant',
    'scheduleParticipantsList',
    'schedulePreview',
    'publishSchedulePlan'
  ]) {
    assert.match(dialogs, new RegExp(`id="${id}"`), `${id} must remain available`)
  }
})

test('active group card has explicit light and dark contrast protection', async () => {
  const styles = await text('web/schedule-builder-usability.css')

  assert.match(styles, /\.group-card\.active\s*\{/)
  assert.match(styles, /\.group-card\.active h2/)
  assert.match(styles, /color:\s*var\(--ink\)/)
  assert.match(styles, /@media \(prefers-color-scheme: dark\)/)
  assert.match(styles, /background:\s*linear-gradient\(180deg, #111f38, var\(--surface\)\)/)
  assert.match(styles, /color:\s*#f8fafc/)
})

test('only one schedule step is displayed and advanced options remain expandable', async () => {
  const styles = await text('web/schedule-builder-usability.css')

  assert.match(styles, /\.schedule-step-card\[hidden\]/)
  assert.match(styles, /display:\s*none !important/)
  assert.match(styles, /\.schedule-advanced > summary/)
  assert.match(styles, /\.schedule-builder-actions\.is-final-step/)
  assert.match(styles, /@media \(max-width: 560px\)/)
})

test('service worker advances and caches the usability stylesheet', async () => {
  const worker = await text('web/service-worker.js')

  assert.match(worker, /kcp-pilot-v7-schedule-builder-usability/)
  assert.match(worker, /\.\/schedule-builder-usability\.css/)
})
