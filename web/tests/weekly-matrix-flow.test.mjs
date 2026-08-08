import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { WEEKDAYS } from '../generic-schedule.js'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

async function text(relative) {
  return readFile(path.join(repoRoot, relative), 'utf8')
}

test('the compact schedule matrix always exposes Monday through Sunday', async () => {
  const source = await text('web/app.parts/12-weekly-matrix-flow.js')

  assert.equal(WEEKDAYS.length, 7)
  assert.deepEqual(WEEKDAYS.map(day => day.short), ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
  assert.match(source, /id = 'scheduleWeekMatrix'/)
  assert.match(source, /WEEKDAYS\.map\(day => weeklyScheduleRow/)
  assert.match(source, /data-week-matrix-field="dayEnabled"/)
  assert.match(source, /data-week-matrix-field="outboundTime"/)
  assert.match(source, /data-week-matrix-field="returnTime"/)
  assert.match(source, /scheduleAdvancedRideRules/)
  assert.match(source, /Advanced ride rules/)
})

test('driver confirmation requires an explicit yes before preview generation', async () => {
  const source = await text('web/app.parts/12-weekly-matrix-flow.js')

  assert.match(source, /scheduleDriversConfirmDialog/)
  assert.match(source, /Are all intended drivers included\?/)
  assert.match(source, /No, review drivers/)
  assert.match(source, /Yes, generate preview/)
  assert.match(source, /await kcpWeeklyPreviousAdvanceScheduleBuilder\(\)/)
  assert.match(source, /selected\.length.*activeDrivers\.length/s)
  assert.match(source, /excluded\.length/)
})

test('preview renders one complete seven-day week with times and drivers', async () => {
  const source = await text('web/app.parts/12-weekly-matrix-flow.js')

  assert.match(source, /weekly-preview-grid/)
  assert.match(source, /WEEKDAYS\.map\(\(day, index\) => previewDayRow/)
  assert.match(source, /preview-week-previous/)
  assert.match(source, /preview-week-next/)
  assert.match(source, /formatTimeLabel/)
  assert.match(source, /participant_name \|\| 'Coverage needed'/)
  assert.match(source, /No ride/)
})

test('parent availability shows all seven days and official scheduled times', async () => {
  const source = await text('web/app.parts/12-weekly-matrix-flow.js')

  assert.match(source, /My ride availability/)
  assert.match(source, /times below come from the published recurring schedule/i)
  assert.match(source, /WEEKDAYS\.map\(day => availabilityWeekRow/)
  assert.match(source, /uniqueScheduleTimes/)
  assert.match(source, /data-action="toggle-weekday"/)
  assert.match(source, /data-action="submit-constraints"/)
  assert.match(source, /Times are informational here/)
})

test('weekly matrix styles prevent sticky overlap and preserve dark-mode contrast', async () => {
  const css = await text('web/weekly-matrix-flow.css')

  assert.match(css, /\.schedule-progress\s*\{[\s\S]*position:\s*static\s*!important/)
  assert.match(css, /\.weekly-matrix-row/)
  assert.match(css, /\.availability-week-row/)
  assert.match(css, /\.weekly-preview-day/)
  assert.match(css, /\.driver-confirm-dialog/)
  assert.match(css, /@media \(prefers-color-scheme: dark\)/)
  assert.match(css, /color:\s*#f8fafc/)
})

test('service worker advances and caches the weekly matrix stylesheet', async () => {
  const worker = await text('web/service-worker.js')

  assert.match(worker, /kcp-pilot-v8-weekly-matrix-flow/)
  assert.match(worker, /\.\/weekly-matrix-flow\.css/)
})
