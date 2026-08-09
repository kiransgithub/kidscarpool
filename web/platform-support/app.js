import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4'
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../config.js'

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: 'kcp-platform-support-session'
  }
})

const state = {
  session: null,
  me: null,
  dashboard: null,
  groups: [],
  cases: [],
  selectedGroupId: null,
  selectedGroup: null,
  breakGlassEventId: null
}

const el = id => document.getElementById(id)
const qsa = selector => [...document.querySelectorAll(selector)]

init()

async function init() {
  bindEvents()
  const { data: { session }, error } = await supabase.auth.getSession()
  if (error) return showFatal(error)
  state.session = session
  if (!session) return showOnly('supportAuth')
  await enterSupport()
}

function bindEvents() {
  el('supportAuthForm').addEventListener('submit', requestSignIn)
  el('supportSignOut').addEventListener('click', signOut)
  el('deniedSignOut').addEventListener('click', signOut)
  qsa('[data-support-view]').forEach(button => button.addEventListener('click', () => showSupportView(button.dataset.supportView)))
  document.addEventListener('click', handleAction)
  el('groupSearchButton').addEventListener('click', loadGroups)
  el('groupSearch').addEventListener('keydown', event => { if (event.key === 'Enter') loadGroups() })
  el('caseRefresh').addEventListener('click', loadCases)
  el('caseStatus').addEventListener('change', loadCases)
  el('errorSearch').addEventListener('click', searchErrors)
  el('groupDetailClose').addEventListener('click', closeGroupDetails)
  el('groupDetailDialog').addEventListener('cancel', event => { event.preventDefault(); closeGroupDetails() })
  el('breakGlassClose').addEventListener('click', closeBreakGlassPrompt)
  el('breakGlassDialog').addEventListener('cancel', event => { event.preventDefault(); closeBreakGlassPrompt() })
  el('breakGlassForm').addEventListener('submit', openBreakGlass)
}

async function requestSignIn(event) {
  event.preventDefault()
  const email = el('supportEmail').value.trim().toLowerCase()
  el('supportAuthStatus').textContent = 'Sending secure sign-in link…'
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: location.href.split('?')[0].split('#')[0], shouldCreateUser: false }
  })
  el('supportAuthStatus').textContent = error
    ? error.message
    : 'Check your email and open the sign-in link on this device.'
}

async function enterSupport() {
  showOnly('supportLoading')
  const { data, error } = await supabase.rpc('kcp_support_me')
  if (error || !data?.[0]) {
    showOnly('supportDenied')
    return
  }
  state.me = data[0]
  el('supportIdentity').textContent = `${state.me.display_name} · ${humanize(state.me.platform_role)}`
  el('supportSignOut').classList.remove('hidden')
  showOnly('supportApp')
  await refreshSupport()
}

async function signOut() {
  if (state.breakGlassEventId) await closeBreakGlassSession().catch(console.warn)
  await supabase.auth.signOut()
  location.replace(location.pathname)
}

async function refreshSupport() {
  await Promise.all([loadDashboard(), loadGroups(), loadCases()])
  showSupportView('dashboard')
}

async function loadDashboard() {
  const { data, error } = await supabase.rpc('kcp_support_dashboard')
  if (error) throwSupport(error)
  state.dashboard = data || {}
  renderDashboard()
}

async function loadGroups() {
  const { data, error } = await supabase.rpc('kcp_support_groups', {
    p_search: el('groupSearch')?.value.trim() || null,
    p_status: el('groupStatus')?.value || null,
    p_limit: 250,
    p_offset: 0
  })
  if (error) throwSupport(error)
  state.groups = data || []
  renderGroups()
  renderAttention()
}

async function loadCases() {
  const { data, error } = await supabase.rpc('kcp_support_cases_list', {
    p_status: el('caseStatus')?.value || null,
    p_group_id: null,
    p_limit: 250
  })
  if (error) throwSupport(error)
  state.cases = data || []
  renderCases()
}

function renderDashboard() {
  const dashboard = state.dashboard || {}
  const metrics = [
    ['Groups', dashboard.groups],
    ['Active groups', dashboard.activeGroups],
    ['Active members', dashboard.activeMembers],
    ['Rides next 24h', dashboard.ridesNext24Hours],
    ['Open covers', dashboard.openCovers],
    ['Unconfirmed rides', dashboard.unconfirmedRides],
    ['Open cases', dashboard.openSupportCases],
    ['Errors 24h', dashboard.recentClientErrors]
  ]
  el('supportMetrics').innerHTML = metrics.map(([label, value]) => `<article><strong>${Number(value || 0)}</strong><span>${escapeHTML(label)}</span></article>`).join('')
  el('systemStatus').innerHTML = `<dl><div><dt>Latest migration</dt><dd>${escapeHTML(dashboard.latestMigration || 'Unknown')}</dd></div><div><dt>Active clients 24h</dt><dd>${Number(dashboard.activeClients24Hours || 0)}</dd></div><div><dt>Generated</dt><dd>${formatDateTime(dashboard.generatedAt)}</dd></div></dl>`
  el('environmentDetails').textContent = JSON.stringify({
    latestMigration: dashboard.latestMigration,
    generatedAt: dashboard.generatedAt,
    currentSupportUser: state.me?.user_id,
    platformRole: state.me?.platform_role,
    browser: navigator.userAgent
  }, null, 2)
}

function renderAttention() {
  const rows = state.groups
    .filter(group => Number(group.open_cover_count || 0) > 0 || Number(group.unconfirmed_ride_count || 0) > 0 || Number(group.pending_invitation_count || 0) > 0)
    .slice(0, 12)
  el('attentionList').innerHTML = rows.map(group => `<button class="attention-row" data-action="open-support-group" data-group-id="${group.group_id}" type="button"><span><strong>${escapeHTML(group.group_name)}</strong><small>${Number(group.open_cover_count || 0)} covers · ${Number(group.unconfirmed_ride_count || 0)} unconfirmed · ${Number(group.pending_invitation_count || 0)} invites</small></span><b>›</b></button>`).join('') || '<p class="muted">No group currently has an open cover, unconfirmed ride or pending invitation.</p>'
}

function renderGroups() {
  el('supportGroupList').innerHTML = state.groups.map(group => `<article class="support-group-row"><div><span class="group-status ${escapeHTML(group.group_status)}">${escapeHTML(group.group_status)}</span><h2>${escapeHTML(group.group_name)}</h2><p>${escapeHTML(group.group_code)} · ${escapeHTML(humanize(group.group_kind || 'other'))} · Owner ${escapeHTML(group.owner_name_masked || 'Unknown')}</p></div><div class="group-stat-strip"><span><strong>${group.active_member_count}</strong> members</span><span><strong>${group.active_driver_count}</strong> drivers</span><span><strong>${group.open_cover_count}</strong> covers</span><span><strong>${group.unconfirmed_ride_count}</strong> unconfirmed</span></div><div><p>${group.next_trip_time ? `${escapeHTML(group.next_trip_label || 'Ride')} · ${formatDateTime(group.next_trip_time)}` : 'No upcoming ride'}</p><small>Client ${escapeHTML(group.latest_client_build || 'unknown')} · ${group.latest_client_seen_at ? formatRelative(group.latest_client_seen_at) : 'not recently seen'}</small><button class="secondary-button" data-action="open-support-group" data-group-id="${group.group_id}" type="button">Open group</button></div></article>`).join('') || '<div class="support-card"><p>No matching group.</p></div>'
}

function renderCases() {
  el('supportCaseList').innerHTML = state.cases.map(item => `<article class="support-case-row"><div><span class="case-status ${escapeHTML(item.status)}">${escapeHTML(humanize(item.status))}</span><h2>${escapeHTML(item.summary)}</h2><p>${escapeHTML(item.group_name || 'Platform-wide')} · ${escapeHTML(humanize(item.category || 'other'))} · reported by ${escapeHTML(item.reported_by_masked || 'Unknown')}</p><small>${formatDateTime(item.created_at)}</small></div><select data-action="update-support-case" data-case-id="${item.case_id}"><option value="open" ${item.status === 'open' ? 'selected' : ''}>Open</option><option value="in_progress" ${item.status === 'in_progress' ? 'selected' : ''}>In progress</option><option value="resolved" ${item.status === 'resolved' ? 'selected' : ''}>Resolved</option><option value="closed" ${item.status === 'closed' ? 'selected' : ''}>Closed</option></select></article>`).join('') || '<div class="support-card"><p>No matching support case.</p></div>'
}

async function openGroupDetails(groupId) {
  state.selectedGroupId = groupId
  const { data, error } = await supabase.rpc('kcp_support_group_details', { p_group_id: groupId })
  if (error) return throwSupport(error)
  state.selectedGroup = data
  renderGroupDetails()
  el('groupDetailDialog').showModal()
}

function renderGroupDetails() {
  const group = state.selectedGroup || {}
  el('detailGroupName').textContent = group.name || 'Group'
  el('detailGroupMeta').textContent = `${group.code || ''} · ${humanize(group.group_kind || 'other')} · ${group.status || ''}`
  const members = group.members || []
  const invitations = group.invitations || []
  const versions = group.scheduleVersions || []
  const covers = group.openCovers || []
  const clients = group.clients || []

  el('groupDetailContent').innerHTML = `
    <section class="detail-actions"><button class="danger-outline" data-action="open-break-glass" type="button">Reveal sensitive data</button><button class="secondary-button" data-action="toggle-group-status" data-status="${group.status === 'active' ? 'archived' : 'active'}" type="button">${group.status === 'active' ? 'Archive group' : 'Reactivate group'}</button></section>
    <section class="support-card"><h2>Members</h2>${members.map(member => `<div class="detail-row"><span><strong>${escapeHTML(member.name || 'Masked member')}</strong><small>${escapeHTML(humanize(member.role))} · ${escapeHTML(member.status)} · ${member.canDrive ? 'driver' : 'not driving'}</small></span>${member.status === 'active' && member.role !== 'owner' ? `<button class="text-button" data-action="transfer-support-owner" data-user-id="${member.userId}" type="button">Make Owner</button>` : ''}</div>`).join('') || '<p>No members.</p>'}</section>
    <section class="support-card"><h2>Invitations</h2>${invitations.map(invitation => `<div class="detail-row"><span><strong>${escapeHTML(invitation.name || 'Masked invitee')}</strong><small>${escapeHTML(humanize(invitation.role))} · ${escapeHTML(invitation.status)} · expires ${formatDateTime(invitation.expiresAt)}</small></span>${invitation.status !== 'accepted' ? `<button class="text-button" data-action="reissue-support-invite" data-invitation-id="${invitation.id}" type="button">Reissue</button>` : ''}</div>`).join('') || '<p>No invitations.</p>'}</section>
    <section class="support-card"><h2>Schedule versions</h2>${versions.slice(0,10).map(version => `<div class="detail-row"><span><strong>Version ${version.version}</strong><small>${escapeHTML(version.status)} · ${version.publishedAt ? formatDateTime(version.publishedAt) : 'not published'} · ${escapeHTML(version.reason || '')}</small></span></div>`).join('') || '<p>No schedule version.</p>'}</section>
    <section class="support-card"><h2>Coverage</h2>${covers.map(cover => `<div class="detail-row"><span><strong>${escapeHTML(cover.status)}</strong><small>${escapeHTML(cover.stage || '')} · ${formatDateTime(cover.createdAt)}</small></span></div>`).join('') || '<p>No open or accepted cover request.</p>'}</section>
    <section class="support-card"><h2>Recent clients</h2>${clients.map(client => `<div class="detail-row"><span><strong>${escapeHTML(client.build || 'Unknown build')}</strong><small>${escapeHTML(client.platform || 'Unknown platform')} · cache ${escapeHTML(client.cache || 'unknown')} · ${formatRelative(client.lastSeenAt)}</small></span></div>`).join('') || '<p>No recent client heartbeat.</p>'}</section>
    <section id="sensitiveGroupDetails" class="support-card sensitive-card hidden"></section>
    <section class="support-card"><h2>Recent audit</h2>${(group.recentAudit || []).slice(0,20).map(audit => `<div class="detail-row"><span><strong>${escapeHTML(humanize(audit.action))}</strong><small>${escapeHTML(audit.entityType || '')} · ${formatDateTime(audit.occurredAt)}</small></span></div>`).join('') || '<p>No recent audit event.</p>'}</section>`
}

async function closeGroupDetails() {
  if (state.breakGlassEventId) await closeBreakGlassSession().catch(console.warn)
  if (el('groupDetailDialog').open) el('groupDetailDialog').close('cancel')
  state.selectedGroupId = null
  state.selectedGroup = null
}

function openBreakGlassPrompt() {
  el('breakGlassReason').value = ''
  el('breakGlassMinutes').value = '10'
  el('breakGlassDialog').showModal()
}
function closeBreakGlassPrompt() { if (el('breakGlassDialog').open) el('breakGlassDialog').close('cancel') }

async function openBreakGlass(event) {
  event.preventDefault()
  try {
    const { data: eventId, error } = await supabase.rpc('kcp_support_open_break_glass', {
      p_group_id: state.selectedGroupId,
      p_reason: el('breakGlassReason').value.trim(),
      p_minutes: Number(el('breakGlassMinutes').value)
    })
    if (error) throw error
    state.breakGlassEventId = eventId
    closeBreakGlassPrompt()
    const { data, error: detailError } = await supabase.rpc('kcp_support_group_sensitive_details', { p_group_id: state.selectedGroupId })
    if (detailError) throw detailError
    renderSensitiveGroupDetails(data)
    toast('Sensitive data revealed temporarily. Access is audited.')
  } catch (error) { throwSupport(error) }
}

function renderSensitiveGroupDetails(data) {
  const target = el('sensitiveGroupDetails')
  target.classList.remove('hidden')
  target.innerHTML = `<div class="sensitive-heading"><div><span class="eyebrow">BREAK-GLASS VIEW</span><h2>Sensitive operational data</h2></div><button class="danger-outline" data-action="close-break-glass" type="button">Close access</button></div><h3>Members</h3>${(data.members || []).map(member => `<div class="detail-row"><span><strong>${escapeHTML(member.name)}</strong><small>${escapeHTML(member.email || 'No email')} · ${escapeHTML(member.phone || 'No phone')} · ${escapeHTML(humanize(member.role))}</small></span></div>`).join('')}<h3>Children</h3>${(data.children || []).map(child => `<div class="sensitive-child"><strong>${escapeHTML(child.name)}</strong><dl><div><dt>Pickup tag</dt><dd>${escapeHTML(child.pickupTag || '—')}</dd></div><div><dt>Pickup</dt><dd>${escapeHTML(child.pickupAddress || '—')}</dd></div><div><dt>Drop-off</dt><dd>${escapeHTML(child.dropoffAddress || '—')}</dd></div><div><dt>Emergency</dt><dd>${escapeHTML(child.emergencyContact || '—')} · ${escapeHTML(child.emergencyPhone || '—')}</dd></div><div><dt>Critical alert</dt><dd>${escapeHTML(child.criticalAlert || 'None')}</dd></div></dl></div>`).join('') || '<p>No child operational profile.</p>'}`
}

async function closeBreakGlassSession() {
  if (!state.breakGlassEventId) return
  const eventId = state.breakGlassEventId
  state.breakGlassEventId = null
  await supabase.rpc('kcp_support_close_break_glass', { p_event_id: eventId })
  el('sensitiveGroupDetails')?.classList.add('hidden')
  if (el('sensitiveGroupDetails')) el('sensitiveGroupDetails').innerHTML = ''
}

async function searchErrors() {
  const reference = el('errorReference').value.trim().toUpperCase()
  const { data, error } = await supabase.rpc('kcp_support_errors', {
    p_reference_code: reference || null,
    p_group_id: null,
    p_limit: 100
  })
  if (error) return throwSupport(error)
  el('errorResults').innerHTML = (data || []).map(item => `<article class="error-result"><div><strong>${escapeHTML(item.reference_code)}</strong><span>${formatDateTime(item.created_at)} · ${escapeHTML(item.operation || 'unknown operation')} · client ${escapeHTML(item.client_version || 'unknown')}</span></div><pre>${escapeHTML(JSON.stringify(item.safe_metadata || {}, null, 2))}</pre></article>`).join('') || '<p class="muted">No matching error reference.</p>'
}

async function handleAction(event) {
  const action = event.target.closest('[data-action]')
  if (!action) return
  const name = action.dataset.action
  if (name === 'refresh-support') return refreshSupport().catch(throwSupport)
  if (name === 'open-support-group') return openGroupDetails(action.dataset.groupId)
  if (name === 'open-break-glass') return openBreakGlassPrompt()
  if (name === 'close-break-glass') return closeBreakGlassSession().then(() => toast('Break-glass access closed')).catch(throwSupport)
  if (name === 'toggle-group-status') return changeGroupStatus(action.dataset.status)
  if (name === 'transfer-support-owner') return transferOwnership(action.dataset.userId)
  if (name === 'reissue-support-invite') return reissueInvitation(action.dataset.invitationId)
}

document.addEventListener('change', async event => {
  const select = event.target.closest('[data-action="update-support-case"]')
  if (!select) return
  const note = prompt(`Change this case to ${humanize(select.value)}. Optional support note:`)
  if (note === null) { await loadCases(); return }
  const { error } = await supabase.rpc('kcp_support_update_case', {
    p_case_id: select.dataset.caseId,
    p_status: select.value,
    p_note: note || null
  })
  if (error) return throwSupport(error)
  toast('Support case updated')
  await loadCases()
})

async function changeGroupStatus(status) {
  const reason = prompt(`Why should this group be ${status === 'archived' ? 'archived' : 'reactivated'}?`)
  if (reason === null) return
  const { error } = await supabase.rpc('kcp_support_set_group_status', {
    p_group_id: state.selectedGroupId,
    p_status: status,
    p_reason: reason
  })
  if (error) return throwSupport(error)
  toast(`Group ${status}`)
  await loadGroups()
  await openGroupDetails(state.selectedGroupId)
}

async function transferOwnership(userId) {
  const reason = prompt('Describe why platform support is transferring group ownership:')
  if (reason === null) return
  if (!confirm('Transfer ownership to this active member? The current Owner becomes an Admin.')) return
  const { error } = await supabase.rpc('kcp_support_transfer_ownership', {
    p_group_id: state.selectedGroupId,
    p_new_owner_user_id: userId,
    p_reason: reason
  })
  if (error) return throwSupport(error)
  toast('Group ownership transferred')
  await openGroupDetails(state.selectedGroupId)
}

async function reissueInvitation(invitationId) {
  const { data, error } = await supabase.rpc('kcp_support_reissue_invitation', {
    p_invitation_id: invitationId,
    p_days: 14
  })
  if (error) return throwSupport(error)
  const invitation = data?.[0]
  if (invitation?.token) {
    await navigator.clipboard?.writeText(invitation.token).catch(() => {})
    toast('Invitation reissued. New token copied to the clipboard.')
  }
  await openGroupDetails(state.selectedGroupId)
}

function showSupportView(view) {
  qsa('[data-support-section]').forEach(section => section.classList.toggle('hidden', section.dataset.supportSection !== view))
  qsa('[data-support-view]').forEach(button => button.classList.toggle('active', button.dataset.supportView === view))
}
function showOnly(id) {
  ['supportLoading','supportAuth','supportDenied','supportApp'].forEach(section => el(section).classList.toggle('hidden', section !== id))
}
function showFatal(error) {
  showOnly('supportAuth')
  el('supportAuthStatus').textContent = error?.message || String(error)
}
function throwSupport(error) {
  console.error(error)
  toast(error?.message || String(error), true)
}
function toast(message, error = false) {
  const node = el('supportToast')
  node.textContent = message
  node.className = `toast ${error ? 'error' : ''}`
  clearTimeout(toast.timer)
  toast.timer = setTimeout(() => node.classList.add('hidden'), 5000)
}
function formatDateTime(value) { return value ? new Date(value).toLocaleString(undefined, { month:'short', day:'numeric', year:'numeric', hour:'numeric', minute:'2-digit' }) : '—' }
function formatRelative(value) {
  if (!value) return 'never'
  const minutes = Math.round((Date.now() - new Date(value).getTime()) / 60000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  if (minutes < 1440) return `${Math.floor(minutes / 60)}h ago`
  return `${Math.floor(minutes / 1440)}d ago`
}
function humanize(value = '') { return String(value).replaceAll('_',' ').replace(/\b\w/g, letter => letter.toUpperCase()) }
function escapeHTML(value = '') { return String(value).replace(/[&<>'"]/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'})[character]) }
