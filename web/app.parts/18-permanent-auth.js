// Permanent email identity and multi-device account support.
// Existing anonymous pilot users keep the same Auth UUID when they link email,
// so memberships, stable participants, trips and points remain unchanged.

state.identity = null
state.accountDevices = []

const KCP_DEVICE_ID_KEY = 'kcp.deviceId.v1'
const KCP_APP_VERSION = 'account-v1'

function kcpDeviceId() {
  let value = localStorage.getItem(KCP_DEVICE_ID_KEY)
  if (!value) {
    value = globalThis.crypto?.randomUUID?.() || `device-${Date.now()}-${Math.random().toString(16).slice(2)}`
    localStorage.setItem(KCP_DEVICE_ID_KEY, value)
  }
  return value
}

function kcpDeviceLabel() {
  const standalone = window.matchMedia?.('(display-mode: standalone)')?.matches
  const platform = navigator.userAgentData?.platform || navigator.platform || 'Web'
  return `${standalone ? 'Installed KCP' : 'KCP browser'} · ${platform}`.slice(0, 120)
}

async function loadKcpIdentity() {
  if (!state.session?.user?.id) {
    state.identity = null
    state.accountDevices = []
    return
  }

  const [{ data: identityData, error: identityError }, { data: devicesData, error: devicesError }] = await Promise.all([
    supabase.rpc('kcp_identity_status'),
    supabase.rpc('kcp_list_my_devices')
  ])

  if (identityError && !/Could not find the function|schema cache/i.test(identityError.message || '')) throw identityError
  if (devicesError && !/Could not find the function|schema cache/i.test(devicesError.message || '')) throw devicesError

  state.identity = identityData?.[0] || null
  state.accountDevices = devicesData || []
}

async function registerKcpDevice() {
  if (!state.session?.user?.id) return
  const deviceId = kcpDeviceId()
  const { data, error } = await supabase.rpc('kcp_register_device', {
    p_device_id: deviceId,
    p_label: kcpDeviceLabel(),
    p_platform: 'pwa',
    p_app_version: KCP_APP_VERSION
  })
  if (error) {
    if (!/Could not find the function|schema cache/i.test(error.message || '')) throw error
    return
  }

  const device = data?.[0]
  if (device?.revoked_at) {
    await supabase.auth.signOut()
    throw new Error('This device was removed from the account. Sign in again from an approved device or contact the group owner.')
  }
}

const kcpPermanentPreviousLoadProfile = loadProfile
loadProfile = async function () {
  await kcpPermanentPreviousLoadProfile()
  await registerKcpDevice()
  await loadKcpIdentity()

  if (state.identity?.identity_verified && !state.profile?.identity_verified_at) {
    const { error } = await supabase.rpc('kcp_record_identity_upgrade')
    if (!error) {
      await kcpPermanentPreviousLoadProfile()
      await loadKcpIdentity()
    }
  }
}

if (!el('emailAccountDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="emailAccountDialog" class="modal account-dialog">
      <form id="emailAccountForm" class="dialog-form">
        <div class="dialog-title">
          <div><span class="eyebrow">SECURE ACCOUNT</span><h2>Use KCP on every device</h2></div>
          <button id="emailAccountClose" class="close-button" type="button" aria-label="Close">×</button>
        </div>
        <p class="meta">Link a verified email to this account. Your existing groups, roles, schedules, trips and points stay attached to the same account.</p>
        <label>Email address
          <input id="emailAccountAddress" type="email" required autocomplete="email" placeholder="you@example.com">
        </label>
        <div id="emailAccountStatus" class="account-status hidden" role="status" aria-live="polite"></div>
        <button id="emailAccountSubmit" class="primary-button" type="submit">Send verification link</button>
      </form>
    </dialog>`)
}

if (!el('emailSignInForm')) {
  const onboarding = el('onboardingView')
  const tabs = onboarding?.querySelector('.segmented')
  const joinForm = el('joinForm')
  tabs?.insertAdjacentHTML('beforeend', '<button class="segment" data-onboarding-mode="email" type="button">Email sign in</button>')
  joinForm?.insertAdjacentHTML('afterend', `
    <form id="emailSignInForm" class="card form-card hidden">
      <h2>Continue with email</h2>
      <p class="meta">Use a linked email to sign in, or enter a new email to create your verified KCP account.</p>
      <label>Email address<input id="emailSignInAddress" type="email" required autocomplete="email" placeholder="you@example.com"></label>
      <div id="emailSignInStatus" class="account-status hidden" role="status" aria-live="polite"></div>
      <button class="primary-button" type="submit">Email me a sign-in link</button>
    </form>`)
}

function setAccountStatus(targetId, message = '', tone = 'info') {
  const target = el(targetId)
  if (!target) return
  target.textContent = message
  target.className = `account-status ${tone}`
  target.classList.toggle('hidden', !message)
}

function closeEmailAccountDialog() {
  const dialog = el('emailAccountDialog')
  if (dialog?.open) dialog.close('cancel')
  el('emailAccountForm')?.reset()
  setAccountStatus('emailAccountStatus')
}

el('emailAccountClose')?.addEventListener('click', closeEmailAccountDialog)
el('emailAccountDialog')?.addEventListener('cancel', event => {
  event.preventDefault()
  closeEmailAccountDialog()
})
el('emailAccountDialog')?.addEventListener('click', event => {
  if (event.target === el('emailAccountDialog')) closeEmailAccountDialog()
})

el('emailAccountForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  const email = el('emailAccountAddress').value.trim().toLowerCase()
  const submit = el('emailAccountSubmit')
  submit.disabled = true
  submit.textContent = 'Sending…'
  setAccountStatus('emailAccountStatus', 'Sending a secure verification link…')

  try {
    const { error } = await supabase.auth.updateUser(
      { email },
      { emailRedirectTo: `${location.origin}${location.pathname}` }
    )
    if (error) throw error
    setAccountStatus(
      'emailAccountStatus',
      'Check your email and open the verification link on this device. KCP will finish the upgrade automatically.',
      'success'
    )
  } catch (error) {
    setAccountStatus('emailAccountStatus', accountAuthMessage(error), 'error')
  } finally {
    submit.disabled = false
    submit.textContent = 'Send verification link'
  }
})

el('emailSignInForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  const email = el('emailSignInAddress').value.trim().toLowerCase()
  const button = event.submitter || el('emailSignInForm').querySelector('button[type="submit"]')
  button.disabled = true
  setAccountStatus('emailSignInStatus', 'Sending a sign-in link…')
  try {
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${location.origin}${location.pathname}`,
        shouldCreateUser: true
      }
    })
    if (error) throw error
    setAccountStatus('emailSignInStatus', 'Check your email and open the sign-in link.', 'success')
  } catch (error) {
    setAccountStatus('emailSignInStatus', accountAuthMessage(error), 'error')
  } finally {
    button.disabled = false
  }
})

document.addEventListener('click', event => {
  const signOut = event.target.closest('[data-action="sign-out"]')
  if (signOut) {
    event.preventDefault()
    if (!confirm('Sign out and remove this device’s remembered group access?')) return
    runAction(async () => {
      const links = await loadDeviceLinks()
      for (const link of links) await removeDeviceLink(link.groupId)
      localStorage.removeItem(ACTIVE_GROUP_KEY)
      await supabase.auth.signOut()
      location.reload()
    }, 'Signed out')
    return
  }

  const modeButton = event.target.closest('[data-onboarding-mode]')
  if (modeButton) {
    event.stopImmediatePropagation()
    const mode = modeButton.dataset.onboardingMode
    qsa('[data-onboarding-mode]').forEach(item => item.classList.toggle('active', item === modeButton))
    el('profileForm')?.classList.toggle('hidden', mode !== 'profile')
    el('joinForm')?.classList.toggle('hidden', mode !== 'invite')
    el('emailSignInForm')?.classList.toggle('hidden', mode !== 'email')
    return
  }

  const secure = event.target.closest('[data-action="secure-account"]')
  if (secure) {
    event.preventDefault()
    el('emailAccountAddress').value = state.identity?.email || ''
    el('emailAccountDialog').showModal()
    setTimeout(() => el('emailAccountAddress')?.focus(), 0)
    return
  }

  const revoke = event.target.closest('[data-action="revoke-account-device"]')
  if (revoke) {
    event.preventDefault()
    const current = revoke.dataset.deviceId === kcpDeviceId()
    if (!confirm(current
      ? 'Remove this device? KCP will sign out here.'
      : 'Remove this device from your KCP account?')) return

    runAction(async () => {
      const { error } = await supabase.rpc('kcp_revoke_device', {
        p_device_id: revoke.dataset.deviceId,
        p_reason: 'Removed from account settings'
      })
      if (error) throw error
      if (current) {
        await supabase.auth.signOut()
        location.reload()
        return
      }
      await loadKcpIdentity()
      renderSettings()
    }, 'Device removed')
  }
}, { capture: true })

const kcpPermanentPreviousRenderSettings = renderSettings
renderSettings = function () {
  kcpPermanentPreviousRenderSettings()
  const profileCard = el('profileCard')
  if (!profileCard || profileCard.querySelector('[data-account-security]')) return

  const identity = state.identity
  const verified = Boolean(identity?.identity_verified)
  const currentDevice = kcpDeviceId()
  profileCard.insertAdjacentHTML('afterend', `
    <div class="card" data-account-security>
      <div class="group-card-head">
        <div><span class="eyebrow">ACCOUNT ACCESS</span><h2>${verified ? 'Verified email account' : 'Account saved only on this device'}</h2></div>
        <span class="status-pill ${verified ? 'complete' : 'warning'}">${verified ? 'Verified' : 'Add a recovery email'}</span>
      </div>
      <p class="meta">${verified
        ? `Signed in as ${escapeHTML(identity.email || '')}. You can use the same KCP account on multiple devices.`
        : 'Link an email before a wider pilot so clearing browser data or changing phones does not remove access.'}</p>
      <div class="button-row">
        ${verified ? '' : '<button class="primary-small" data-action="secure-account" type="button">Secure with email</button>'}
        <button class="action-button orange" data-action="sign-out" type="button">Sign out</button>
      </div>
      <h3 style="margin:18px 0 8px">Your devices</h3>
      <div class="account-device-list">
        ${(state.accountDevices || []).map(device => `
          <div class="timeline-row account-device ${device.revoked_at ? 'revoked' : ''}">
            <div><strong>${escapeHTML(device.label)}</strong><span class="meta">${escapeHTML(device.platform)} · last used ${formatDateTime(device.last_seen_at)}${device.device_id === currentDevice ? ' · this device' : ''}</span></div>
            ${device.revoked_at
              ? '<span class="badge">Removed</span>'
              : `<button class="action-button" data-action="revoke-account-device" data-device-id="${escapeHTML(device.device_id)}" type="button">Remove</button>`}
          </div>`).join('') || '<p class="meta">This device will appear after the next sync.</p>'}
      </div>
    </div>`)
}

supabase.auth.onAuthStateChange(async event => {
  if (!['SIGNED_IN', 'USER_UPDATED', 'TOKEN_REFRESHED'].includes(event)) return
  queueMicrotask(async () => {
    try {
      const { data: { session } } = await supabase.auth.getSession()
      state.session = session
      await registerKcpDevice()
      await loadKcpIdentity()
      if (state.identity?.identity_verified) {
        await supabase.rpc('kcp_record_identity_upgrade')
        await loadProfile()
        if (state.profile) {
          await refreshAll()
          showConnection('Account synced.', 'success')
        }
      }
    } catch (error) {
      console.warn('KCP identity refresh:', error.message || error)
    }
  })
})

function accountAuthMessage(error) {
  const message = error?.message || String(error)
  if (/otp_disabled|signups not allowed for otp/i.test(`${error?.code || ''} ${message}`)) {
    return 'Email sign-in is disabled for this KCP environment. Ask the platform administrator to enable email authentication.'
  }
  if (/manual linking|identity.*link/i.test(message)) {
    return 'Account linking is not enabled yet. A platform administrator must enable manual identity linking in Authentication settings.'
  }
  if (/rate limit/i.test(message)) return 'Too many email attempts. Wait a few minutes and try again.'
  if (/already registered|already been registered|email.*exists/i.test(message)) {
    return 'That email already belongs to another KCP account. Sign in with it instead of linking it here.'
  }
  return 'The email request could not be completed. Check the address and try again.'
}
