import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4'
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../config.js'
import { kcpAuthStorage } from '../persistence.js'

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: 'kcp-supabase-session',
    storage: kcpAuthStorage
  }
})

const state = {
  role: null,
  groups: [],
  cases: [],
  errors: []
}

const el = id => document.getElementById(id)

init()

async function init() {
  try {
    const { data: { session }, error: sessionError } = await supabase.auth.getSession()
    if (sessionError) throw sessionError
    if (!session) throw new Error('Sign in to the family app with the platform administrator account first.')

    const { data: roleData, error: roleError } = await supabase.rpc('kcp_platform_role')
    if (roleError) throw roleError
    state.role = roleData?.[0] || null
    if (!state.role) throw new Error('This account does not have platform support access.')

    el('supportStatus').textContent = `Platform role: ${humanize(state.role.role)}`
    el('supportStatus').classList.add('success')
    el('supportApp').classList.remove('hidden')
    bindEvents()
    await refreshAll()
  } catch (error) {
    el('supportStatus').textContent = error.message || String(error)
    el('supportStatus').classList.add('error')
  }
}

function bindEvents() {
  el('refreshSupport').addEventListener('click', refreshAll)
  el('groupSearch').addEventListener('input', debounce(loadGroups, 250))
  el('closeGroupOverview').addEventListener('click', () => el('groupOverviewDialog').close())
  el('groupOverviewDialog').addEventListener('click', event => {
    if (event.target === el('groupOverviewDialog')) el('groupOverviewDialog').close()
  })

  document.addEventListener('click', async event => {
    const tab = event.target.closest('[data-support-tab]')
    if (tab) {
      document.querySelectorAll('[data-support-tab]').forEach(item => item.classList.toggle('active', item === tab))
      document.querySelectorAll('[data-support-panel]').forEach(panel => panel.classList.toggle('hidden', panel.dataset.supportPanel !== tab.dataset.supportTab))
      return
    }

    const open = event.target.closest('[data-action="open-group-overview"]')
    if (open) {
      await showGroupOverview(open.dataset.groupId)
      return
    }

    const access = event.target.closest('[data-action="open-break-glass"]')
    if (access) {
      const reason = prompt('Enter the support reason. This access is audited and expires in 10 minutes.')
      if (!reason) return
      const { data, error } = await supabase.rpc('kcp_admin_open_break_glass', {
        p_group_id: access.dataset.groupId,
        p_reason: reason
      })
      if (error) return alert(error.message)
      alert(`Temporary support access opened until ${formatDateTime(data?.[0]?.expires_at)}.`)
      return
    }

    const createCase = event.target.closest('[data-action="create-support-case"]')
    if (createCase) {
      const summary = prompt('Support case summary')
      if (!summary) return
      const { data, error } = await supabase.rpc('kcp_admin_create_support_case', {
        p_group_id: createCase.dataset.groupId,
        p_category: 'group_support',
        p_priority: 'normal',
        p_summary: summary,
        p_safe_details: {}
      })
      if (error) return alert(error.message)
      alert(`Case created: ${data?.[0]?.reference_code || ''}`)
      await loadCases()
    }
  })
}

async function refreshAll() {
  el('refreshSupport').disabled = true
  try {
    await Promise.all([loadGroups(), loadCases(), loadErrors()])
  } finally {
    el('refreshSupport').disabled = false
  }
}

async function loadGroups() {
  const { data, error } = await supabase.rpc('kcp_admin_list_groups', {
    p_search: el('groupSearch').value.trim() || null,
    p_limit: 100,
    p_offset: 0
  })
  if (error) throw error
  state.groups = data || []
  el('groupList').innerHTML = state.groups.map(groupCard).join('') || empty('No matching groups.')
}

async function loadCases() {
  const { data, error } = await supabase.rpc('kcp_admin_list_support_cases', { p_limit: 100 })
  if (error) throw error
  state.cases = data || []
  el('caseList').innerHTML = state.cases.map(item => `
    <article class="support-card">
      <div class="card-head"><strong>${escapeHTML(item.reference_code)}</strong><span class="pill ${item.priority}">${escapeHTML(item.priority)}</span></div>
      <h3>${escapeHTML(item.summary)}</h3>
      <p>${escapeHTML(humanize(item.category))} · ${escapeHTML(humanize(item.status))}</p>
      <small>${formatDateTime(item.created_at)}</small>
    </article>`).join('') || empty('No support cases.')
}

async function loadErrors() {
  const { data, error } = await supabase.rpc('kcp_admin_list_client_errors', { p_limit: 100 })
  if (error) throw error
  state.errors = data || []
  el('errorList').innerHTML = state.errors.map(item => `
    <article class="support-card">
      <div class="card-head"><strong>${escapeHTML(item.reference_code)}</strong><span class="pill">${escapeHTML(item.client_version || 'unknown client')}</span></div>
      <h3>${escapeHTML(item.operation)}</h3>
      <p>${escapeHTML(item.message_code || 'Unexpected error')}</p>
      <details><summary>Technical context</summary><pre>${escapeHTML(item.technical_message || JSON.stringify(item.safe_metadata || {}, null, 2))}</pre></details>
      <small>${formatDateTime(item.created_at)}</small>
    </article>`).join('') || empty('No client errors.')
}

function groupCard(group) {
  return `
    <article class="support-card">
      <div class="card-head"><strong>${escapeHTML(group.group_name)}</strong><span class="pill">${escapeHTML(group.status)}</span></div>
      <p>${escapeHTML(group.destination_name || 'No destination')} ${group.term_label ? `· ${escapeHTML(group.term_label)}` : ''}</p>
      <dl>
        <div><dt>Owner</dt><dd>${escapeHTML(group.owner_name || 'Unassigned')}</dd></div>
        <div><dt>Members</dt><dd>${group.active_member_count}</dd></div>
        <div><dt>Open covers</dt><dd>${group.open_cover_count}</dd></div>
        <div><dt>Next ride</dt><dd>${group.next_trip_at ? formatDateTime(group.next_trip_at) : 'None'}</dd></div>
      </dl>
      <div class="button-row">
        <button data-action="open-group-overview" data-group-id="${group.group_id}" type="button">Open</button>
        <button data-action="create-support-case" data-group-id="${group.group_id}" type="button">New case</button>
        ${state.role?.can_break_glass ? `<button class="warning" data-action="open-break-glass" data-group-id="${group.group_id}" type="button">Temporary access</button>` : ''}
      </div>
    </article>`
}

async function showGroupOverview(groupId) {
  el('groupOverviewContent').innerHTML = '<p>Loading…</p>'
  el('groupOverviewDialog').showModal()
  const { data, error } = await supabase.rpc('kcp_admin_group_overview', { p_group_id: groupId })
  if (error) {
    el('groupOverviewContent').innerHTML = `<p class="error-text">${escapeHTML(error.message)}</p>`
    return
  }

  const overview = data || {}
  const group = overview.group || {}
  el('groupOverviewContent').innerHTML = `
    <h3>${escapeHTML(group.name || '')}</h3>
    <p>${escapeHTML(group.code || '')} · ${escapeHTML(group.status || '')}</p>
    <div class="metric-grid">
      <div><strong>${overview.counts?.trips || 0}</strong><span>Trips</span></div>
      <div><strong>${overview.counts?.openCovers || 0}</strong><span>Open covers</span></div>
      <div><strong>${overview.counts?.pendingInvitations || 0}</strong><span>Invites</span></div>
      <div><strong>${overview.counts?.pendingChanges || 0}</strong><span>Changes</span></div>
    </div>
    <h4>Members</h4>
    ${(overview.members || []).map(member => `<div class="row"><span>${escapeHTML(member.name)}</span><span>${escapeHTML(humanize(member.role))} · ${escapeHTML(member.status)}</span></div>`).join('')}
    <h4>Next rides</h4>
    ${(overview.nextTrips || []).map(trip => `<div class="row"><span>${escapeHTML(trip.display_label || 'Ride')}</span><span>${trip.scheduled_time ? formatDateTime(trip.scheduled_time) : 'Time pending'} · ${escapeHTML(trip.actual_driver_name || trip.scheduled_driver_name || 'Unassigned')}</span></div>`).join('') || '<p>No upcoming rides.</p>'}`
}

function empty(message) {
  return `<div class="empty">${escapeHTML(message)}</div>`
}

function debounce(fn, wait) {
  let timer
  return (...args) => {
    clearTimeout(timer)
    timer = setTimeout(() => fn(...args).catch(error => alert(error.message)), wait)
  }
}

function humanize(value = '') {
  return String(value).replaceAll('_', ' ').replace(/\b\w/g, character => character.toUpperCase())
}

function formatDateTime(value) {
  if (!value) return '—'
  return new Date(value).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
}

function escapeHTML(value = '') {
  return String(value).replace(/[&<>'"]/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  })[character])
}
