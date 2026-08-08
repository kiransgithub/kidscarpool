import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import {
  createOfflineAction,
  sortOfflineActions,
  nextSyncBatch
} from '../offline-queue.js'

const source = fs.readFileSync('web/app.parts/34-offline-sync-accessibility.js','utf8')
const worker = fs.readFileSync('web/service-worker-v24.js','utf8')
const registration = fs.readFileSync('web/app.parts/34b-release-service-worker.js','utf8')
const styles = fs.readFileSync('web/offline-accessibility.css','utf8')
const migration = fs.readFileSync('supabase/migrations/202608080018_kcp_offline_action_receipts.sql','utf8')
const deviceTime = fs.readFileSync('supabase/migrations/202608080019_kcp_offline_device_time.sql','utf8')

test('offline actions retain deterministic creation order', () => {
  const later = createOfflineAction({ id:'offline-later-0002', tripId:'trip-1', action:'start_trip', createdAt:'2026-08-08T10:01:00Z' })
  const first = createOfflineAction({ id:'offline-first-0001', tripId:'trip-1', action:'confirm_trip', createdAt:'2026-08-08T10:00:00Z' })
  assert.deepEqual(sortOfflineActions([later,first]).map(action => action.id),['offline-first-0001','offline-later-0002'])
})

test('a failed action blocks later actions for the same ride but not another ride', () => {
  const actions = [
    { ...createOfflineAction({ id:'failed-action-001', tripId:'trip-a', action:'start_trip', createdAt:'2026-08-08T10:00:00Z' }), status:'failed' },
    createOfflineAction({ id:'blocked-action-002', tripId:'trip-a', action:'child_picked_up', createdAt:'2026-08-08T10:01:00Z' }),
    createOfflineAction({ id:'other-trip-action-003', tripId:'trip-b', action:'confirm_trip', createdAt:'2026-08-08T10:02:00Z' })
  ]
  assert.deepEqual(nextSyncBatch(actions).map(action => action.id),['other-trip-action-003'])
})

test('client queues Driver mode actions before existing online handlers when offline', () => {
  assert.match(source, /window\.addEventListener\('click'/)
  assert.match(source, /if \(navigator\.onLine\) return/)
  assert.match(source, /event\.stopImmediatePropagation\(\)/)
  assert.match(source, /kcp_apply_offline_trip_action/)
  assert.match(source, /blockedTrips/)
})

test('Driver mode caches an imminent operational snapshot for offline use', () => {
  assert.match(source, /cacheDriverSnapshot/)
  assert.match(source, /loadDriverSnapshot/)
  assert.match(source, /Ride details are not available offline/)
  assert.match(source, /completed_pending_sync/)
})

test('server receipts make delayed replay idempotent and bound device time', () => {
  assert.match(migration, /unique \(user_id, client_action_id\)/)
  assert.match(migration, /pg_advisory_xact_lock/)
  assert.match(deviceTime, /scheduled_time - interval '10 minutes'/)
  assert.match(deviceTime, /scheduled_time \+ interval '90 minutes'/)
  assert.match(deviceTime, /started_source = 'offline'/)
})

test('release worker provides offline navigation and retains push delivery', () => {
  assert.match(worker, /kcp-community-v24-offline-accessibility/)
  assert.match(worker, /event\.request\.mode === 'navigate'/)
  assert.match(worker, /caches\.match\('\.\/index\.html'\)/)
  assert.match(worker, /addEventListener\('push'/)
  assert.match(registration, /service-worker-v24\.js/)
})

test('accessibility contract includes skip navigation, focus, touch targets and reduced motion', () => {
  assert.match(source, /Skip to main content/)
  assert.match(source, /aria-modal/)
  assert.match(styles, /min-height:\s*44px/)
  assert.match(styles, /:focus-visible/)
  assert.match(styles, /prefers-reduced-motion/)
  assert.match(styles, /prefers-contrast: more/)
  assert.match(styles, /\.status-pill::before/)
})
