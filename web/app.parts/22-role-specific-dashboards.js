// Role-specific consumer presentation. A user may hold different roles in
// different groups, so Home summarizes the highest responsibilities in their
// membership portfolio while each group card follows that group's role.

function kcpRolePortfolio() {
  const groups = state.groups || []
  const managedGroups = groups.filter(group => ['owner', 'admin'].includes(group.role))
  const parentGroups = groups.filter(group => ['owner', 'admin', 'parent'].includes(group.role))
  const viewerOnly = groups.length > 0 && groups.every(group => group.role === 'viewer')
  return { groups, managedGroups, parentGroups, viewerOnly }
}

function roleForGroup(groupId) {
  return state.groups.find(group => group.group_id === groupId)?.role
    || (state.activeGroup?.id === groupId ? currentMembership()?.role : null)
    || 'viewer'
}

function updateRoleSpecificNavigation() {
  const portfolio = kcpRolePortfolio()
  const requestsButton = document.querySelector('[data-kcp-primary-nav][data-nav="requests"]')
  if (requestsButton) requestsButton.classList.toggle('hidden', portfolio.viewerOnly)

  if (portfolio.viewerOnly && state.currentView === 'requests') navigate('home')
  document.body.dataset.kcpPortfolio = portfolio.viewerOnly
    ? 'viewer'
    : portfolio.managedGroups.length
      ? 'manager'
      : 'parent'
}

renderHome = function () {
  const portfolio = kcpRolePortfolio()
  const upcoming = state.allGroupAgenda.filter(item =>
    !['completed','cancelled'].includes(item.status)
      && (item.scheduled_time ? new Date(item.scheduled_time).getTime() >= Date.now() - 90 * 60 * 1000 : true)
  )
  const nextRide = upcoming[0] || null
  const nextAssignment = upcoming.find(item =>
    (item.actual_driver_id || item.scheduled_driver_id) === state.session?.user?.id
  ) || null

  if (portfolio.viewerOnly) {
    renderAgendaFocusCard(el('nextDropCard'), nextRide, 'NEXT RIDE', 'ride')
    renderAgendaFocusCard(el('nextPickupCard'), upcoming[1] || null, 'AFTER THAT', 'ride')
    el('homeAlerts').innerHTML = `
      <span class="eyebrow">READ-ONLY VIEW</span>
      <h2>${nextRide ? 'Your group schedule is current' : 'No upcoming rides'}</h2>
      <p class="meta">View live rides and assigned drivers. Group-management settings are hidden.</p>
      <button class="secondary-button" data-nav="schedule" type="button">View schedule</button>`
    updateRoleSpecificNavigation()
    return
  }

  renderAgendaFocusCard(el('nextDropCard'), nextRide, 'NEXT RIDE', 'ride')
  renderAgendaFocusCard(el('nextPickupCard'), nextAssignment, 'YOUR NEXT DRIVE', 'drive')

  if (portfolio.managedGroups.length) {
    const pendingChanges = state.allGroupRequests.filter(item =>
      item.request_type === 'availability' && item.requires_my_action
    )
    const openCovers = state.allGroupRequests.filter(item =>
      item.request_type === 'cover' && item.status === 'open'
    )
    const unassigned = upcoming.filter(item => !item.actual_driver_id && !item.scheduled_driver_id)
    const pendingInvites = portfolio.managedGroups.reduce(
      (total, group) => total + Number(group.pending_invitation_count || 0),
      0
    )
    const total = pendingChanges.length + openCovers.length + unassigned.length + pendingInvites

    el('homeAlerts').innerHTML = `
      <div class="group-card-head">
        <div><span class="eyebrow">OWNER + ADMIN OVERVIEW</span><h2>${total ? `${total} item${total === 1 ? '' : 's'} need review` : 'Groups are ready'}</h2></div>
        <span class="status-pill ${total ? 'warning' : 'complete'}">${total ? 'Review' : 'Clear'}</span>
      </div>
      <div class="metric-row manager-metrics">
        <div class="metric"><strong>${openCovers.length}</strong><small>Open covers</small></div>
        <div class="metric"><strong>${unassigned.length}</strong><small>Unassigned rides</small></div>
        <div class="metric"><strong>${pendingChanges.length}</strong><small>Pending changes</small></div>
        <div class="metric"><strong>${pendingInvites}</strong><small>Pending invites</small></div>
      </div>
      ${total ? '<button class="secondary-button" data-nav="requests" type="button">Review updates</button>' : '<p class="meta">No update needs attention across the groups you manage.</p>'}`
  } else {
    const ownRequests = state.allGroupRequests.filter(item =>
      item.requested_by === state.session?.user?.id
        || item.accepted_by === state.session?.user?.id
        || item.requires_my_action
    )
    el('homeAlerts').innerHTML = `
      <div class="group-card-head">
        <div><span class="eyebrow">YOUR RIDES</span><h2>${ownRequests.length ? `${ownRequests.length} update${ownRequests.length === 1 ? '' : 's'}` : 'You are up to date'}</h2></div>
        <span class="status-pill ${ownRequests.length ? 'info' : 'complete'}">${ownRequests.length ? 'Review' : 'Clear'}</span>
      </div>
      ${ownRequests.slice(0, 3).map(request => `
        <button class="attention-row" data-nav="requests" type="button">
          <span><strong>${escapeHTML(request.group_name)}</strong><small>${escapeHTML(request.display_label || humanize(request.request_type))}</small></span><span>›</span>
        </button>`).join('')}
      ${ownRequests.length ? '<button class="secondary-button" data-nav="requests" type="button">View requests</button>' : '<p class="meta">Your assignments and child rides are shown above.</p>'}`
  }

  updateRoleSpecificNavigation()
}

renderGroups = function () {
  const list = el('groupsList')
  if (!state.groups.length) {
    list.innerHTML = '<div class="empty-card"><h2>No groups yet</h2><p>Create a private group or accept an invitation.</p></div>'
    el('groupAdminPanel').classList.add('hidden')
    return
  }

  list.innerHTML = state.groups.map(group => {
    const active = state.activeGroup?.id === group.group_id
    const role = group.role || 'viewer'
    const manager = ['owner','admin'].includes(role)
    const destination = group.destination_name || group.school_name || 'No destination'
    const term = group.term_label || group.academic_year || ''

    return `<article class="group-card ${active ? 'active' : ''}" data-group-role="${escapeHTML(role)}">
      <div class="group-card-head">
        <div><h2>${escapeHTML(group.group_name)}</h2><div class="meta">${escapeHTML(destination)}${term ? ` · ${escapeHTML(term)}` : ''}</div></div>
        ${active
          ? '<span class="status-pill">Active</span>'
          : `<button class="action-button" data-action="switch-group" data-group-id="${group.group_id}" type="button">Switch</button>`}
      </div>
      <div class="button-row"><span class="role-pill">${escapeHTML(capitalize(role))}</span>${role === 'viewer' ? '<span class="badge">Read only</span>' : ''}</div>
      ${manager ? `<div class="metric-row">
        <div class="metric"><strong>${group.active_member_count || 0}</strong><small>Members</small></div>
        <div class="metric"><strong>${group.pending_invitation_count || 0}</strong><small>Invites</small></div>
        <div class="metric"><strong>${group.pending_constraint_count || 0}</strong><small>Changes</small></div>
        <div class="metric"><strong>${group.current_schedule_version || 0}</strong><small>Schedule</small></div>
      </div>` : role === 'parent' ? `<div class="metric-row compact-role-metrics">
        <div class="metric"><strong>${group.active_member_count || 0}</strong><small>Members</small></div>
        <div class="metric"><strong>${group.calendar_registered ? 'Yes' : 'Optional'}</strong><small>Calendar</small></div>
      </div>` : ''}
    </article>`
  }).join('')

  renderGroupAdminPanel()
  renderRoleSpecificGroupPanel()
}

function renderRoleSpecificGroupPanel() {
  const panel = el('groupAdminPanel')
  if (!state.activeGroup || !panel) return
  const role = currentMembership()?.role || roleForGroup(state.activeGroup.id)
  if (['owner','admin'].includes(role)) return

  const upcoming = state.allGroupAgenda.filter(item =>
    item.group_id === state.activeGroup.id && !['completed','cancelled'].includes(item.status)
  )
  panel.classList.remove('hidden')
  panel.innerHTML = `
    <div class="card">
      <span class="eyebrow">${role === 'viewer' ? 'READ-ONLY GROUP' : 'YOUR MEMBERSHIP'}</span>
      <h2>${escapeHTML(state.activeGroup.name)}</h2>
      <p class="meta">${role === 'viewer'
        ? 'You can view live rides and assigned drivers. Group-management settings are hidden.'
        : 'Use Schedule for rides, Requests for coverage, and Settings for your availability.'}</p>
      <div class="button-row">
        <button class="primary-small" data-nav="schedule" type="button">View schedule</button>
        <button class="secondary-button" data-nav="calendar" type="button">Calendar</button>
        ${role === 'viewer' ? '' : '<button class="secondary-button" data-nav="settings" type="button">Availability</button>'}
      </div>
      <div class="metric-row compact-role-metrics">
        <div class="metric"><strong>${upcoming.length}</strong><small>Upcoming rides</small></div>
        <div class="metric"><strong>${escapeHTML(capitalize(role))}</strong><small>Your role</small></div>
      </div>
    </div>`
}

const kcpRoleDashboardPreviousRenderAll = renderAll
renderAll = function () {
  kcpRoleDashboardPreviousRenderAll()
  updateRoleSpecificNavigation()
}
