// Consumer-first information architecture: one personal agenda across all
// groups, five primary destinations, and management details behind Groups/More.

state.allGroupAgenda = []
state.allGroupRequests = []
state.agendaGroupFilter = 'all'

function primaryNavIcon(name) {
  const paths = {
    home: '<path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10.5V20h13v-9.5"/><path d="M9.5 20v-6h5v6"/>',
    schedule: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/><path d="m9 16 2 2 4-4"/>',
    requests: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"/><path d="M10 21h4"/>',
    groups: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
    more: '<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>',
    points: '<path d="m12 2 3.1 6.3 6.9 1-5 4.9 1.2 6.8-6.2-3.2L5.8 21 7 14.2 2 9.3l6.9-1Z"/>',
    calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21h-4v-.1A1.7 1.7 0 0 0 8.6 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H3v-4h.1A1.7 1.7 0 0 0 4.6 8.6a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1V3h4v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.37.38.58.9.6 1.4V13c-.02.52-.23 1.02-.6 1.4Z"/>'
  }
  return `<svg class="nav-icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name]}</svg>`
}

if (!el('requestsView')) {
  el('mainContent')?.insertAdjacentHTML('beforeend', `
    <section id="requestsView" class="view hidden" data-view="requests">
      <div class="section-heading"><div><span class="eyebrow">NEEDS ATTENTION</span><h1>Requests</h1></div></div>
      <div id="allGroupRequestList" class="stack"></div>
    </section>
    <section id="moreView" class="view hidden" data-view="more">
      <div class="section-heading"><div><span class="eyebrow">ACCOUNT + GROUP TOOLS</span><h1>More</h1></div></div>
      <div class="more-grid">
        <button class="more-card" data-more-view="leaderboard" type="button"><span>${primaryNavIcon('points')}</span><strong>Driving summary</strong><small>Completed, volunteer and upcoming rides</small></button>
        <button class="more-card" data-more-view="calendar" type="button"><span>${primaryNavIcon('calendar')}</span><strong>Calendar</strong><small>Closures and exception dates</small></button>
        <button class="more-card" data-more-view="settings" type="button"><span>${primaryNavIcon('settings')}</span><strong>Settings</strong><small>Profile, availability and devices</small></button>
      </div>
    </section>`)
}

function installFiveTabNavigation() {
  const nav = el('bottomNav')
  if (!nav || nav.dataset.fiveTab === 'true') return
  nav.dataset.fiveTab = 'true'
  nav.innerHTML = `
    <button class="nav-item active" data-nav="home" data-kcp-primary-nav type="button"><span>${primaryNavIcon('home')}</span><small>Home</small></button>
    <button class="nav-item" data-nav="schedule" data-kcp-primary-nav type="button"><span>${primaryNavIcon('schedule')}</span><small>Schedule</small></button>
    <button class="nav-item" data-nav="requests" data-kcp-primary-nav type="button"><span>${primaryNavIcon('requests')}</span><small>Requests</small></button>
    <button class="nav-item" data-nav="groups" data-kcp-primary-nav type="button"><span>${primaryNavIcon('groups')}</span><small>Groups</small></button>
    <button class="nav-item" data-nav="more" data-kcp-primary-nav type="button"><span>${primaryNavIcon('more')}</span><small>More</small></button>`
}

installFiveTabNavigation()

async function loadAllGroupFeeds() {
  if (!state.session?.user?.id) {
    state.allGroupAgenda = []
    state.allGroupRequests = []
    return
  }

  const now = new Date()
  const from = new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString()
  const to = new Date(now.getTime() + 90 * 24 * 60 * 60 * 1000).toISOString()
  const [{ data: agenda, error: agendaError }, { data: requests, error: requestsError }] = await Promise.all([
    supabase.rpc('kcp_my_agenda', { p_from: from, p_to: to, p_limit: 500 }),
    supabase.rpc('kcp_my_requests', { p_limit: 300 })
  ])

  if (agendaError && !/Could not find the function|schema cache/i.test(agendaError.message || '')) throw agendaError
  if (requestsError && !/Could not find the function|schema cache/i.test(requestsError.message || '')) throw requestsError
  state.allGroupAgenda = agenda || []
  state.allGroupRequests = requests || []
}

const kcpAgendaPreviousLoadGroups = loadGroups
loadGroups = async function () {
  await kcpAgendaPreviousLoadGroups()
  await loadAllGroupFeeds()
}

const kcpAgendaPreviousClearWorkspace = clearWorkspace
clearWorkspace = function () {
  kcpAgendaPreviousClearWorkspace()
  // All-group feeds remain available when no single group is selected.
}

renderHome = function () {
  const upcoming = state.allGroupAgenda.filter(item =>
    !['completed','cancelled'].includes(item.status)
      && (item.scheduled_time ? new Date(item.scheduled_time).getTime() >= Date.now() - 90 * 60 * 1000 : true)
  )
  const nextRide = upcoming[0] || null
  const nextAssignment = upcoming.find(item =>
    (item.actual_driver_id || item.scheduled_driver_id) === state.session?.user?.id
  ) || null
  const attention = state.allGroupRequests.filter(item => item.requires_my_action)

  renderAgendaFocusCard(el('nextDropCard'), nextRide, 'NEXT RIDE', 'ride')
  renderAgendaFocusCard(el('nextPickupCard'), nextAssignment, 'YOUR NEXT DRIVE', 'drive')

  el('homeAlerts').innerHTML = `
    <div class="group-card-head">
      <div><span class="eyebrow">ACROSS ALL GROUPS</span><h2>${attention.length ? `${attention.length} item${attention.length === 1 ? '' : 's'} need attention` : 'You are up to date'}</h2></div>
      ${attention.length ? '<span class="status-pill warning">Review</span>' : '<span class="status-pill complete">Clear</span>'}
    </div>
    ${attention.slice(0, 3).map(request => `
      <button class="attention-row" data-nav="requests" type="button">
        <span><strong>${escapeHTML(request.group_name)}</strong><small>${escapeHTML(request.display_label || humanize(request.request_type))}</small></span>
        <span>›</span>
      </button>`).join('')}
    ${attention.length ? '<button class="secondary-button" data-nav="requests" type="button">View requests</button>' : `<p class="meta">${state.allGroupAgenda.length ? 'Upcoming rides from every group are shown here automatically.' : 'Create a group or accept an invitation to begin.'}</p>`}`
}

function agendaFocusIcon(name) {
  const paths = name === 'drive'
    ? '<path d="M5 17h14v-5l-2-5H7l-2 5v5Z"/><path d="M6 12h12M7 17v2M17 17v2"/><circle cx="8" cy="14.5" r="1"/><circle cx="16" cy="14.5" r="1"/>'
    : '<path d="M5 19c0-4 2-6 6-6h8"/><path d="m15 9 4 4-4 4"/><circle cx="5" cy="19" r="2"/>'
  return `<svg class="trip-focus-icon" viewBox="0 0 24 24" aria-hidden="true">${paths}</svg>`
}

function renderAgendaFocusCard(container, trip, heading, focusIcon) {
  container.className = `trip-focus-card ${focusIcon === 'drive' ? 'pickup' : 'morning'}`
  if (!trip) {
    container.classList.add('empty')
    container.innerHTML = `<div class="trip-symbol">${agendaFocusIcon(focusIcon)}</div><div class="trip-label">${heading}</div><h2>No upcoming ride</h2><p class="meta">Live rides from all of your groups will appear here.</p>`
    return
  }

  const driver = trip.actual_driver_name || trip.scheduled_driver_name || 'Unassigned'
  container.innerHTML = `
    <div class="trip-symbol">${agendaFocusIcon(focusIcon)}</div>
    <div class="trip-label">${escapeHTML(heading)}</div>
    <span class="group-context-badge">${escapeHTML(trip.group_name)}</span>
    <div class="driver">${escapeHTML(trip.display_label || 'Ride')}</div>
    <div class="trip-time">${escapeHTML(agendaDateTime(trip))}</div>
    <div class="trip-driver-row"><span>Driver</span><strong>${escapeHTML(driver)}</strong></div>
    ${statusPill(trip.status)}
    <div style="height:12px"></div>
    <button class="primary-button" data-action="open-agenda-trip" data-group-id="${trip.group_id}" data-trip-id="${trip.trip_id}" type="button">View ride</button>`
}

renderSchedule = function () {
  const list = el('scheduleList')
  const groups = [...new Map(state.allGroupAgenda.map(item => [item.group_id, item.group_name])).entries()]
  const rows = state.allGroupAgenda
    .filter(item => state.agendaGroupFilter === 'all' || item.group_id === state.agendaGroupFilter)
    .filter(item => !['cancelled'].includes(item.status))

  const view = el('scheduleView')
  let filter = el('allGroupScheduleFilter')
  if (!filter) {
    view.querySelector('.section-heading')?.insertAdjacentHTML('beforeend', `
      <label class="agenda-filter-label">Group
        <select id="allGroupScheduleFilter"><option value="all">All groups</option></select>
      </label>`)
    filter = el('allGroupScheduleFilter')
  }
  filter.innerHTML = '<option value="all">All groups</option>' + groups
    .map(([id, name]) => `<option value="${id}">${escapeHTML(name)}</option>`).join('')
  filter.value = state.agendaGroupFilter

  list.innerHTML = rows.length
    ? rows.map(allGroupTripRow).join('')
    : empty('No live rides match this group filter.')
}

function allGroupTripRow(trip) {
  const driver = trip.actual_driver_name || trip.scheduled_driver_name || 'Unassigned'
  return `<article class="trip-row all-group-trip-row">
    <div class="trip-date"><small>${month(trip.trip_date)}</small><strong>${day(trip.trip_date)}</strong></div>
    <div>
      <span class="group-context-badge">${escapeHTML(trip.group_name)}</span>
      <h3>${escapeHTML(trip.display_label || 'Ride')} · ${escapeHTML(driver)}</h3>
      <p>${escapeHTML(agendaDateTime(trip))}</p>
      <p>${statusPill(trip.status)} ${trip.volunteer_assignment ? '<span class="badge">Volunteer</span>' : ''}</p>
    </div>
    <div class="button-row"><button class="action-button" data-action="open-agenda-trip" data-group-id="${trip.group_id}" data-trip-id="${trip.trip_id}" type="button">View</button></div>
  </article>`
}

function renderAllGroupRequests() {
  const list = el('allGroupRequestList')
  const requests = state.allGroupRequests || []
  if (!requests.length) {
    list.innerHTML = empty('No cover or availability requests need attention.')
    return
  }

  list.innerHTML = requests.map(request => `
    <article class="request-card ${request.requires_my_action ? 'needs-action' : ''}">
      <div class="group-card-head">
        <div><span class="group-context-badge">${escapeHTML(request.group_name)}</span><h3>${escapeHTML(request.display_label || humanize(request.request_type))}</h3></div>
        ${statusPill(request.status)}
      </div>
      <p class="meta">${request.scheduled_time ? escapeHTML(agendaDateTime(request)) : escapeHTML(humanize(request.request_type))}</p>
      <p>${escapeHTML(request.note || (request.request_type === 'cover' ? 'Coverage requested' : 'Availability change submitted'))}</p>
      ${request.accepted_by_name ? `<p class="cover-acceptance">✓ Accepted by ${escapeHTML(request.accepted_by_name)}</p>` : ''}
      <div class="button-row">
        ${request.request_type === 'cover' && request.status === 'open' && request.requires_my_action
          ? `<button class="action-button green" data-action="accept-cover" data-request-id="${request.request_id}" type="button">Volunteer</button>` : ''}
        ${request.request_type === 'cover' && request.trip_id
          ? `<button class="action-button" data-action="open-agenda-trip" data-group-id="${request.group_id}" data-trip-id="${request.trip_id}" type="button">View ride</button>` : ''}
        ${request.request_type === 'availability' && request.requires_my_action
          ? `<button class="action-button green" data-action="review-constraint" data-request-id="${request.request_id}" data-decision="approved" type="button">Approve</button><button class="action-button" data-action="review-constraint" data-request-id="${request.request_id}" data-decision="rejected" type="button">Reject</button>` : ''}
      </div>
    </article>`).join('')
}

const kcpAgendaPreviousRenderAll = renderAll
renderAll = function () {
  installFiveTabNavigation()
  kcpAgendaPreviousRenderAll()
  renderAllGroupRequests()
}

const kcpAgendaPreviousNavigate = navigate
navigate = function (view) {
  kcpAgendaPreviousNavigate(view)
  const primary = ['home','schedule','requests','groups'].includes(view) ? view : 'more'
  qsa('[data-kcp-primary-nav]').forEach(button => button.classList.toggle('active', button.dataset.nav === primary))
  if (view === 'requests') renderAllGroupRequests()
}

document.addEventListener('change', event => {
  if (event.target.id !== 'allGroupScheduleFilter') return
  state.agendaGroupFilter = event.target.value
  renderSchedule()
})

document.addEventListener('click', async event => {
  const primary = event.target.closest('[data-kcp-primary-nav]')
  if (primary) {
    event.preventDefault()
    event.stopImmediatePropagation()
    navigate(primary.dataset.nav)
    return
  }

  const more = event.target.closest('[data-more-view]')
  if (more) {
    event.preventDefault()
    navigate(more.dataset.moreView)
    return
  }

  const navButton = event.target.closest('[data-nav]')
  if (navButton && !navButton.classList.contains('nav-item')) {
    event.preventDefault()
    navigate(navButton.dataset.nav)
    return
  }

  const tripButton = event.target.closest('[data-action="open-agenda-trip"]')
  if (!tripButton) return
  event.preventDefault()
  const groupId = tripButton.dataset.groupId
  const tripId = tripButton.dataset.tripId
  if (state.activeGroup?.id !== groupId) {
    localStorage.setItem(ACTIVE_GROUP_KEY, groupId)
    await refreshAll()
  }
  showTrip(tripId)
}, { capture: true })

function agendaDateTime(item) {
  if (item.scheduled_time) return formatDateTime(item.scheduled_time)
  return `${formatDate(item.trip_date)} · ${item.time_label || 'Time confirmation required'}`
}
