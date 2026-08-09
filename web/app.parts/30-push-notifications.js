// Opt-in Web Push. Permission is requested only after a member opens Settings
// and chooses Enable reminders; never on first launch.

state.notificationPreferences = []
state.notificationPublicKey = null
state.pushSubscription = null

const pushedView = new URLSearchParams(location.search).get('view')
if (['home','schedule','requests','groups','more','calendar','settings','leaderboard'].includes(pushedView)) {
  state.currentView = pushedView
  localStorage.setItem(VIEW_KEY, pushedView)
}

const kcpPushPreviousLoadAllGroupFeeds = loadAllGroupFeeds
loadAllGroupFeeds = async function () {
  await kcpPushPreviousLoadAllGroupFeeds()
  if (!state.session?.user?.id) return

  const [{ data: preferences, error: preferenceError }, { data: config, error: configError }] = await Promise.all([
    supabase.rpc('kcp_my_notification_preferences'),
    supabase.rpc('kcp_notification_public_config')
  ])
  if (preferenceError && !/Could not find the function|schema cache/i.test(preferenceError.message || '')) throw preferenceError
  if (configError && !/Could not find the function|schema cache/i.test(configError.message || '')) throw configError
  state.notificationPreferences = preferences || []
  state.notificationPublicKey = config?.[0]?.vapid_public_key || null

  if ('serviceWorker' in navigator && 'PushManager' in window) {
    const registration = await navigator.serviceWorker.ready
    state.pushSubscription = await registration.pushManager.getSubscription()
  }
}

const kcpPushPreviousRenderSettings = renderSettings
renderSettings = function () {
  kcpPushPreviousRenderSettings()
  renderNotificationSettings()
}

function renderNotificationSettings() {
  const settings = el('settingsView')
  settings?.querySelector('[data-notification-settings]')?.remove()
  if (!state.activeGroup || kcpAccess().isViewer && !state.notificationPreferences.length) return

  const supported = 'Notification' in window && 'serviceWorker' in navigator && 'PushManager' in window
  const enabled = Notification.permission === 'granted' && Boolean(state.pushSubscription)
  const labels = {
    upcoming_ride: 'Upcoming ride reminders',
    schedule_changed: 'Schedule changes',
    cover_requested: 'New cover requests',
    cover_accepted: 'Cover accepted',
    cover_escalated: 'Urgent unresolved coverage',
    child_absence: 'Child ride updates',
    driver_confirmation_due: 'Driver confirmation due',
    completion_due: 'Completion confirmation due',
    trip_unconfirmed: 'Unconfirmed ride alerts',
    admin_approval: 'Admin approvals',
    invitation_accepted: 'Invitation accepted',
    swap_requested: 'Ride swap requests',
    swap_resolved: 'Ride swap results',
    points: 'Points and recognition'
  }

  settings?.insertAdjacentHTML('beforeend', `
    <div class="card" data-notification-settings>
      <div class="group-card-head">
        <div><span class="eyebrow">REMINDERS</span><h2>Notifications</h2></div>
        <span class="status-pill ${enabled ? 'complete' : supported ? 'info' : 'warning'}">${enabled ? 'Enabled' : supported ? 'Off' : 'Unavailable'}</span>
      </div>
      <p class="meta">KCP asks for notification permission only when you enable reminders here.</p>
      ${!state.notificationPublicKey ? '<p class="notification-setup-note">Push delivery has not been configured by the platform administrator.</p>' : ''}
      <div class="button-row">
        ${enabled
          ? '<button class="secondary-button" data-action="disable-push" type="button">Disable on this device</button>'
          : `<button class="primary-button" data-action="enable-push" type="button" ${supported && state.notificationPublicKey ? '' : 'disabled'}>Enable reminders</button>`}
      </div>
      ${enabled ? `<div class="notification-preferences">
        ${state.notificationPreferences.map(preference => `
          <label class="notification-toggle">
            <span>${escapeHTML(labels[preference.category] || humanize(preference.category))}</span>
            <input data-notification-category="${preference.category}" type="checkbox" ${preference.global_enabled ? 'checked' : ''}>
          </label>`).join('')}
      </div>` : ''}
    </div>`)
}

document.addEventListener('click', async event => {
  const enable = event.target.closest('[data-action="enable-push"]')
  if (enable) {
    event.preventDefault()
    await enablePushNotifications()
    return
  }
  const disable = event.target.closest('[data-action="disable-push"]')
  if (disable) {
    event.preventDefault()
    await disablePushNotifications()
  }
}, { capture: true })

document.addEventListener('change', async event => {
  const toggle = event.target.closest('[data-notification-category]')
  if (!toggle) return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_set_notification_preference', {
      p_category: toggle.dataset.notificationCategory,
      p_enabled: toggle.checked,
      p_group_id: null
    })
    if (error) throw error
    const preference = state.notificationPreferences.find(item => item.category === toggle.dataset.notificationCategory)
    if (preference) preference.global_enabled = toggle.checked
  }, 'Notification preference updated', { operation: 'set_notification_preference' })
})

async function enablePushNotifications() {
  if (!state.notificationPublicKey) {
    toast('Push delivery is not configured yet.', true)
    return
  }
  await runAction(async () => {
    const permission = await Notification.requestPermission()
    if (permission !== 'granted') throw new Error('Notification permission was not granted. You can enable it later in browser or iPhone settings.')

    const registration = await navigator.serviceWorker.ready
    let subscription = await registration.pushManager.getSubscription()
    if (!subscription) {
      subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: base64UrlToUint8Array(state.notificationPublicKey)
      })
    }
    const json = subscription.toJSON()
    const { error } = await supabase.rpc('kcp_register_push_subscription', {
      p_endpoint: subscription.endpoint,
      p_p256dh: json.keys?.p256dh,
      p_auth_secret: json.keys?.auth,
      p_user_agent: navigator.userAgent,
      p_device_label: navigator.standalone ? 'Installed iPhone app' : 'Web browser'
    })
    if (error) throw error
    state.pushSubscription = subscription
    renderNotificationSettings()
  }, 'Reminders enabled on this device', { operation: 'enable_push' })
}

async function disablePushNotifications() {
  await runAction(async () => {
    const registration = await navigator.serviceWorker.ready
    const subscription = await registration.pushManager.getSubscription()
    if (subscription) {
      const { error } = await supabase.rpc('kcp_revoke_push_subscription', {
        p_endpoint: subscription.endpoint
      })
      if (error) throw error
      await subscription.unsubscribe()
    }
    state.pushSubscription = null
    renderNotificationSettings()
  }, 'Reminders disabled on this device', { operation: 'disable_push' })
}

function base64UrlToUint8Array(base64Url) {
  const padding = '='.repeat((4 - base64Url.length % 4) % 4)
  const base64 = (base64Url + padding).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(base64)
  return Uint8Array.from([...raw].map(character => character.charCodeAt(0)))
}
