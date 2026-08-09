import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4'
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js'
import {
  kcpAuthStorage,
  loadDeviceLinks,
  saveDeviceLink,
  removeDeviceLink
} from './persistence.js'

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: 'kcp-supabase-session',
    storage: kcpAuthStorage
  }
})

const DAY_NAMES = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']
const BASIS_CALENDAR_SHA256 = '3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464'
const ACTIVE_GROUP_KEY = 'kcp.activeGroupId'
const VIEW_KEY = 'kcp.activeView'

const BASIS_EVENTS = [
  event('first_day', 'First Day of School', '2026-08-05', '2026-08-05'),
  event('no_school', 'Labor Day Break', '2026-09-07', '2026-09-07'),
  event('early_release', 'Professional Development', '2026-09-25', '2026-09-25'),
  event('early_release', 'Parent/Teacher Conferences', '2026-10-07', '2026-10-07'),
  event('no_school', 'Fall Break', '2026-10-12', '2026-10-16'),
  event('no_school', 'Veterans Day', '2026-11-11', '2026-11-11'),
  event('no_school', 'Thanksgiving Break', '2026-11-25', '2026-11-30'),
  event('early_release', 'Winter Break Early Release', '2026-12-18', '2026-12-18', 'No Late Bird'),
  event('no_late_bird', 'No Late Bird', '2026-12-18', '2026-12-18'),
  event('no_school', 'Winter Break', '2026-12-21', '2027-01-01'),
  event('no_school', 'MLK Day', '2027-01-18', '2027-01-18'),
  event('early_release', 'Professional Development', '2027-02-12', '2027-02-12'),
  event('no_school', 'Presidents Day', '2027-02-15', '2027-02-15'),
  event('no_school', 'February Break', '2027-02-22', '2027-02-24'),
  event('early_release', 'Parent/Teacher Conferences', '2027-03-10', '2027-03-10'),
  event('no_school', 'Spring Break', '2027-03-15', '2027-03-19'),
  event('early_release', 'Professional Development', '2027-04-01', '2027-04-01'),
  event('no_school', 'April Break', '2027-04-02', '2027-04-05'),
  event('project_week', 'Project Week', '2027-05-24', '2027-05-28'),
  event('last_day', 'Last Day of School', '2027-05-28', '2027-05-28', 'No Late Bird'),
  event('no_late_bird', 'No Late Bird', '2027-05-28', '2027-05-28')
]

function event(event_type, title, start_date, end_date, notes = '') {
  return { event_type, title, start_date, end_date, notes }
}

const state = {
  session: null,
  profile: null,
  groups: [],
  activeGroup: null,
  memberships: [],
  invitations: [],
  constraints: [],
  constraintRequests: [],
  calendar: null,
  calendarEvents: [],
  analytics: null,
  scheduleVersions: [],
  trips: [],
  coverRequests: [],
  points: [],
  auditEvents: [],
  deviceLinks: [],
  currentView: localStorage.getItem(VIEW_KEY) || 'home',
  constraintDraft: { drop: [], pickup: [], notes: '' },
  deferredInstallPrompt: null,
  loading: false
}

const el = id => document.getElementById(id)
const qsa = selector => [...document.querySelectorAll(selector)]

async function restoreRememberedMemberships() {
  const links = await loadDeviceLinks()
  state.deviceLinks = links
  let restored = false

  for (const link of links) {
    const { data, error } = await supabase.rpc('kcp_restore_device_link', {
      p_secret: link.secret
    })

    if (error) {
      const message = error.message || ''
      if (/invalid or revoked|not found|no longer exists/i.test(message)) {
        state.deviceLinks = await removeDeviceLink(link.groupId)
      } else if (!/Could not find the function|schema cache/i.test(message)) {
        console.warn('KCP remembered-device recovery:', message)
      }
      continue
    }

    const restoredGroup = data?.[0]
    if (restoredGroup?.group_id) {
      localStorage.setItem(ACTIVE_GROUP_KEY, restoredGroup.group_id)
      restored = true
    }
  }

  return restored
}

async function rememberGroup(groupId, label = 'Installed KCP app') {
  if (!groupId) return null

  const links = await loadDeviceLinks()
  const existing = links.find(item => item.groupId === groupId)
  if (existing) {
    state.deviceLinks = links
    return existing
  }

  const { data, error } = await supabase.rpc('kcp_create_device_link', {
    p_group_id: groupId,
    p_label: label
  })

  if (error) {
    if (!/Could not find the function|schema cache/i.test(error.message || '')) {
      console.warn('KCP could not remember this group on the device:', error.message || error)
    }
    return null
  }

  const created = data?.[0]
  if (!created?.device_secret) return null

  state.deviceLinks = await saveDeviceLink({
    groupId,
    secret: created.device_secret
  })
  return state.deviceLinks.find(item => item.groupId === groupId) || null
}

async function ensureRememberedGroups(groups = state.groups) {
  for (const group of groups || []) {
    await rememberGroup(group.group_id)
  }
}

window.addEventListener('beforeinstallprompt', event => {
  event.preventDefault()
  state.deferredInstallPrompt = event
  el('installButton').classList.remove('hidden')
})

el('installButton').addEventListener('click', async () => {
  if (state.deferredInstallPrompt) {
    state.deferredInstallPrompt.prompt()
    await state.deferredInstallPrompt.userChoice
    state.deferredInstallPrompt = null
    el('installButton').classList.add('hidden')
  } else {
    alert('On iPhone: open this page in Safari, tap Share, then choose “Add to Home Screen.”')
  }
})

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./service-worker.js').catch(console.warn)
}

init()

async function init() {
  bindStaticEvents()
  try {
    showConnection('Connecting to Supabase…')
    const { data: { session }, error: sessionError } = await supabase.auth.getSession()
    if (sessionError) throw sessionError

    const returningSession = Boolean(session)
    state.session = session
    if (!state.session) {
      const { data, error } = await supabase.auth.signInAnonymously()
      if (error) throw new Error(`${error.message}. Enable Anonymous Sign-Ins in Supabase Authentication settings.`)
      state.session = data.session
    }

    await restoreRememberedMemberships()
    await loadProfile()
    if (!state.profile && typeof ensureVerifiedKcpAccount === 'function') {
      await ensureVerifiedKcpAccount()
    }
    hide('loadingView')
    if (!state.profile) {
      show('onboardingView')
      hide('bottomNav')
      hide('activeGroupBar')
      showConnection('Connected — complete your pilot profile or restore an invitation.', 'success')
      return
    }

    await enterApp({ view: returningSession || state.identity?.identity_verified ? 'home' : state.currentView })
  } catch (error) {
    hide('loadingView')
    show('onboardingView')
    showConnection(error.message || String(error), 'error')
    toast(error.message || String(error), true)
  }
}

function bindStaticEvents() {
  qsa('[data-onboarding-mode]').forEach(button => {
    button.addEventListener('click', () => {
      qsa('[data-onboarding-mode]').forEach(item => item.classList.toggle('active', item === button))
      const inviteMode = button.dataset.onboardingMode === 'invite'
      el('profileForm').classList.toggle('hidden', inviteMode)
      el('joinForm').classList.toggle('hidden', !inviteMode)
    })
  })

  el('profileForm').addEventListener('submit', async event => {
    event.preventDefault()
    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_upsert_profile', {
        p_display_name: el('profileName').value.trim(),
        p_phone: el('profilePhone').value.trim() || null
      }).single()
      if (error) throw error
      state.profile = data
      await enterApp()
    }, 'Profile saved')
  })

  el('joinForm').addEventListener('submit', async event => {
    event.preventDefault()
    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_accept_invitation', {
        p_token: el('joinToken').value.trim().toUpperCase(),
        p_parent_name: el('joinName').value.trim(),
        p_phone: el('joinPhone').value.trim() || null
      })
      if (error) throw error
      await loadProfile()
      if (data?.[0]?.group_id) {
        localStorage.setItem(ACTIVE_GROUP_KEY, data[0].group_id)
        await rememberGroup(data[0].group_id)
      }
      await enterApp()
    }, 'Invitation accepted or restored on this device')
  })

  qsa('[data-nav]').forEach(button => button.addEventListener('click', () => navigate(button.dataset.nav)))
  el('switchGroupButton').addEventListener('click', () => navigate('groups'))
  el('openCreateGroup').addEventListener('click', () => el('createGroupDialog').showModal())

  el('createGroupForm').addEventListener('submit', async event => {
    event.preventDefault()
    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_create_group', {
        p_name: el('newGroupName').value.trim(),
        p_school_name: el('newSchoolName').value.trim(),
        p_school_key: slug(el('newSchoolName').value),
        p_academic_year: el('newAcademicYear').value.trim(),
        p_child_name: el('newChildName').value.trim(),
        p_grade: Number(el('newChildGrade').value),
        p_drop_weekdays: [1, 2, 3, 4, 5],
