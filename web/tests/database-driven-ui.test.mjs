import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const ui = fs.readFileSync('web/app.parts/14-database-driven-ui.js', 'utf8')
const recovery = fs.readFileSync('web/app.parts/15-generic-recovery.js', 'utf8')
const roleGuard = fs.readFileSync('web/app.parts/16-role-action-guard.js', 'utf8')
const stateSync = fs.readFileSync('web/app.parts/17-database-state-sync.js', 'utf8')
const index = fs.readFileSync('web/index.html', 'utf8')
const builder = fs.readFileSync('web/build-runtime.mjs', 'utf8')
const serviceWorker = fs.readFileSync('web/service-worker.js', 'utf8')

test('group, destination, term, member, child and trip labels are read from state/DB fields', () => {
  assert.match(ui, /state\.activeGroup/)
  assert.match(ui, /state\.memberships/)
  assert.match(ui, /state\.scheduleBuilder\?\.participants/)
  assert.match(ui, /trip\?\.display_label/)
  assert.match(ui, /group\?\.destination_name \|\| group\?\.school_name/)
  assert.match(ui, /group\?\.term_label \|\| group\?\.academic_year/)
})

test('current driving permission is loaded from the stable participant row', () => {
  assert.match(stateSync, /kcp_group_participants/)
  assert.match(stateSync, /\.eq\('user_id', userId\)/)
  assert.match(stateSync, /state\.currentParticipant = participants\[0\]/)
  assert.match(stateSync, /kcpCurrentParticipant = function/)
})

test('children and private pickup tags are loaded from database records', () => {
  assert.match(stateSync, /'kcp_children'/)
  assert.match(stateSync, /state\.children = children/)
  assert.match(stateSync, /child\?\.pickup_tag/)
  assert.match(stateSync, /data-db-pickup-tag/)
  assert.doesNotMatch(stateSync, /Thanishka|Saanvi|Kavish|Ishi/i)
})

test('role and can-drive fields control admin, volunteer and viewer presentation', () => {
  assert.match(ui, /role === 'owner' \|\| role === 'admin'/)
  assert.match(ui, /role !== 'viewer'/)
  assert.match(ui, /data-nav="volunteers"/)
  assert.match(ui, /open-generic-schedule/)
  assert.match(ui, /This membership is read-only/)
})

test('stale cached controls cannot bypass role-aware presentation', () => {
  assert.match(roleGuard, /KCP_DRIVING_ACTIONS/)
  assert.match(roleGuard, /KCP_ADMIN_ACTIONS/)
  assert.match(roleGuard, /event\.stopImmediatePropagation\(\)/)
  assert.match(roleGuard, /kcpAccess\(\)\.canDrive/)
  assert.match(roleGuard, /querySelectorAll\(\[/)
  assert.match(roleGuard, /data-action="accept-cover"/)
  assert.match(roleGuard, /data-action="open-generic-schedule-builder"|open-generic-schedule-builder/)
})

test('new schedule drafts and advanced rides do not invent a weekday time', () => {
  assert.match(ui, /scheduleDraftSessions = \[\]/)
  assert.match(ui, /defaultWeeklyTime = function \(\) \{\s*return ''/s)
  assert.match(stateSync, /outboundTime: previous\?\.outboundTime \?\? ''/)
  assert.match(stateSync, /returnTime: previous\?\.returnTime \?\? ''/)
})

test('new groups default to the device timezone instead of the active group timezone', () => {
  assert.match(stateSync, /Intl\.DateTimeFormat\(\)\.resolvedOptions\(\)\.timeZone/)
  assert.match(stateSync, /select\.value = timezone/)
})

test('calendar uploads store generic metadata and no embedded event list', () => {
  assert.match(ui, /p_events: \[\]/)
  assert.match(ui, /kcpGroupDestination/)
  assert.doesNotMatch(ui, /calendar sha|authoritative school/i)
})

test('recovery requires user-entered group and member identity', () => {
  assert.match(recovery, /recoverGroupCode.*value\.trim/s)
  assert.match(recovery, /recoverParentName.*value\.trim/s)
  assert.doesNotMatch(recovery, /value\s*=\s*['"][^'"]+['"].*recoverGroupCode/s)
})

test('production HTML contains neutral empty inputs rather than real pilot identities', () => {
  assert.match(index, /placeholder="Your name"/)
  assert.match(index, /placeholder="Destination or activity"/)
  assert.doesNotMatch(index, /BASIS|KCP-BASIS|Thanishka|Saanvi|Kavish|Ishi|Kiran|Mohan|Pavan|Santhosh/i)
})

test('Pages uses the runtime builder and installed apps receive the DB-driven cache', () => {
  assert.match(builder, /Production runtime still contains pilot data/)
  assert.match(serviceWorker, /v9-database-driven-ui/)
})
