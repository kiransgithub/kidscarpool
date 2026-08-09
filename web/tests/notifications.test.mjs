import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/30-push-notifications.js', 'utf8')
const worker = fs.readFileSync('web/service-worker.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080012_kcp_web_push_notifications.sql', 'utf8')
const dispatcher = fs.readFileSync('supabase/functions/send-notifications/index.ts', 'utf8')

test('notification permission is requested only after an explicit Settings action', () => {
  assert.match(source, /data-action="enable-push"/)
  assert.match(source, /Notification\.requestPermission\(\)/)
  assert.doesNotMatch(source, /Notification\.requestPermission\(\)[\s\S]*init\(/)
})

test('push subscription and preferences are stored server-side', () => {
  assert.match(source, /kcp_register_push_subscription/)
  assert.match(source, /kcp_set_notification_preference/)
  assert.match(migration, /kcp_push_subscriptions/)
  assert.match(migration, /kcp_notification_preferences/)
})

test('operational triggers enqueue covers, absences, trip states, swaps and reminders', () => {
  assert.match(migration, /kcp_cover_notification_trigger/)
  assert.match(migration, /kcp_absence_notification_trigger/)
  assert.match(migration, /kcp_trip_status_notification_trigger/)
  assert.match(migration, /kcp_swap_notification_trigger/)
  assert.match(migration, /kcp_enqueue_trip_reminders/)
})

test('service worker displays notifications and routes clicks into the app', () => {
  assert.match(worker, /addEventListener\('push'/)
  assert.match(worker, /showNotification/)
  assert.match(worker, /addEventListener\('notificationclick'/)
  assert.match(worker, /clients\.openWindow/)
  assert.match(worker, /v22-web-push/)
})

test('dispatcher requires a secret and revokes gone subscriptions', () => {
  assert.match(dispatcher, /NOTIFICATION_DISPATCH_SECRET/)
  assert.match(dispatcher, /x-kcp-dispatch-secret/)
  assert.match(dispatcher, /statusCode === 404 \|\| statusCode === 410/)
  assert.match(dispatcher, /revoked_at/)
  assert.match(dispatcher, /webpush\.sendNotification/)
})
