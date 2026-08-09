import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const index = fs.readFileSync('web/index.html', 'utf8')
const navigation = fs.readFileSync('web/app.parts/35-page-navigation.js', 'utf8')
const navigationStyles = fs.readFileSync('web/page-navigation.css', 'utf8')
const schedule = fs.readFileSync('web/app.parts/11-schedule-builder-usability.js', 'utf8')
const impact = fs.readFileSync('web/app.parts/31-schedule-templates-impact.js', 'utf8')
const fairness = fs.readFileSync('web/app.parts/32-fairness-ledger.js', 'utf8')
const worker = fs.readFileSync('web/service-worker-v24.js', 'utf8')
const builder = fs.readFileSync('web/build-runtime.mjs', 'utf8')

test('every non-home page has persistent Back and Close controls', () => {
  assert.match(index, /id="pageNavigationBar"/)
  assert.match(index, /id="pageBackButton"/)
  assert.match(index, /id="pageCloseButton"/)
  assert.match(navigationStyles, /\.page-navigation\s*\{[\s\S]*position:\s*sticky/)
  assert.match(navigationStyles, /top:\s*calc\(70px \+ env\(safe-area-inset-top\)\)/)
  assert.match(navigation, /state\.currentView !== 'home'/)
  assert.match(navigation, /navigateBack/)
  assert.match(navigation, /closeCurrentPage/)
})

test('page navigation preserves screen state and scroll position', () => {
  assert.match(navigation, /KCP_VIEW_SCROLL_KEY/)
  assert.match(navigation, /KCP_VIEW_HISTORY_KEY/)
  assert.match(navigation, /sessionStorage\.setItem/)
  assert.match(navigation, /kcpViewScroll\[current\] =/)
  assert.match(navigation, /window\.scrollTo\(\{ top: savedTop/)
  assert.match(navigation, /window\.addEventListener\('popstate'/)
})

test('long dialogs keep Back or Close controls pinned above their scroll area', () => {
  assert.match(index, /page-navigation\.css/)
  assert.match(navigationStyles, /\.dialog-form > \.dialog-title/)
  assert.match(navigationStyles, /\.schedule-builder-form > \.dialog-title/)
  assert.match(navigationStyles, /position:\s*sticky/)
  assert.match(schedule, /kcpScheduleStep === 1.*close\('cancel'\)/s)
})

test('schedule preview remains viewable when the final change check must be retried', () => {
  assert.match(impact, /renderSchedulePreview\(occurrences \|\| \[\]\)/)
  assert.match(impact, /try \{[\s\S]*kcp_prepare_schedule_change[\s\S]*\} catch \(error\) \{/)
  assert.match(impact, /renderScheduleImpactUnavailable/)
  assert.match(impact, /window\.kcpScheduleImpactReady/)
  assert.match(schedule, /The rides are ready to view, but the final change check did not finish/)
  assert.match(schedule, /invited driver.*draft is saved/s)
})

test('family-facing schedule and contribution labels use plain language', () => {
  assert.match(index, /Driving summary/)
  assert.match(schedule, /Check schedule/)
  assert.match(schedule, /making the schedule live/i)
  assert.match(fairness, /How contributions are counted/)
  assert.match(fairness, /Extra credit for longer rides/)
  assert.match(fairness, /Extra credit for carrying more children/)
  assert.doesNotMatch(fairness, /weighted completed workload/)
  assert.doesNotMatch(fairness, /workload units vs average/)
})

test('release cache includes navigation controls and local builds ignore macOS metadata files', () => {
  assert.match(worker, /v25-navigation-language/)
  assert.match(worker, /\.\/page-navigation\.css/)
  assert.match(builder, /!name\.startsWith\('\.'\)/)
})
