const CACHE = 'kcp-community-v24-offline-accessibility'
const SHELL = [
  './',
  './index.html',
  './styles.css',
  './fixes.css',
  './generic-schedule.css',
  './schedule-builder-usability.css',
  './weekly-matrix-flow.css',
  './account-auth.css',
  './all-group-home.css',
  './role-dashboards.css',
  './adaptive-invitations.css',
  './safety-profiles.css',
  './trip-roster.css',
  './safe-trip-state.css',
  './driver-mode.css',
  './child-absence.css',
  './cover-swaps.css',
  './notifications.css',
  './schedule-impact.css',
  './fairness.css',
  './offline-accessibility.css',
  './app.js',
  './logic.js',
  './persistence.js',
  './generic-schedule.js',
  './offline-queue.js',
  './config.js',
  './manifest.webmanifest',
  './icon-1024.png'
]

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)))
  self.skipWaiting()
})

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(key => key.startsWith('kcp-') && key !== CACHE).map(key => caches.delete(key))
    ))
  )
  self.clients.claim()
})

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return
  const url = new URL(event.request.url)
  if (url.origin !== self.location.origin) return

  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          const copy = response.clone()
          caches.open(CACHE).then(cache => cache.put('./index.html',copy))
          return response
        })
        .catch(() => caches.match('./index.html'))
    )
    return
  }

  event.respondWith(
    fetch(event.request)
      .then(response => {
        const copy = response.clone()
        caches.open(CACHE).then(cache => cache.put(event.request,copy))
        return response
      })
      .catch(() => caches.match(event.request))
  )
})

self.addEventListener('push', event => {
  let payload = {}
  try {
    payload = event.data?.json() || {}
  } catch {
    payload = { body: event.data?.text() || 'Open Kidscarpool for an update.' }
  }

  const title = payload.title || 'Kidscarpool'
  const options = {
    body: payload.body || 'Open Kidscarpool for an update.',
    icon: './icon-1024.png',
    badge: './icon-1024.png',
    tag: payload.category && payload.tripId
      ? `${payload.category}:${payload.tripId}`
      : payload.category || 'kcp-update',
    renotify: ['cover_escalated','trip_unconfirmed','driver_confirmation_due'].includes(payload.category),
    data: {
      url: payload.url || './',
      category: payload.category,
      groupId: payload.groupId,
      tripId: payload.tripId
    }
  }
  event.waitUntil(self.registration.showNotification(title,options))
})

self.addEventListener('notificationclick', event => {
  event.notification.close()
  const target = new URL(event.notification.data?.url || './',self.location.origin).href
  event.waitUntil(
    self.clients.matchAll({ type:'window', includeUncontrolled:true }).then(clients => {
      const existing = clients.find(client => client.url.startsWith(self.location.origin))
      if (existing) {
        existing.navigate(target)
        return existing.focus()
      }
      return self.clients.openWindow(target)
    })
  )
})
