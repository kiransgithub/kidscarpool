    })
    if (error) throw error
    await loadWorkspace(); renderAll()
  }, `Constraint request ${decision}`)
}

async function requestCover(tripId) {
  const note = prompt('Why do you need coverage?', '')
  if (note === null) return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_request_cover', { p_trip_id: tripId, p_note: note })
    if (error) throw error
    await loadWorkspace(); renderAll()
  }, 'Cover request posted')
}

async function acceptCover(requestId) {
  if (!confirm('Accept this additional trip? It earns 20 points after completion.')) return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_accept_cover', { p_request_id: requestId })
    if (error) throw error
    await loadWorkspace(); renderAll()
  }, 'Volunteer trip accepted')
}

async function tripAction(rpcName, tripId, successMessage) {
  await runAction(async () => {
    const { data, error } = await supabase.rpc(rpcName, { p_trip_id: tripId })
    if (error) throw error
    await loadWorkspace(); renderAll()
    el('tripDialog').close()
    return data
  }, successMessage)
}

function showTrip(tripId) {
  const trip = state.trips.find(item => item.id === tripId)
  if (!trip) return
  const driverId = trip.actual_driver_id || trip.scheduled_driver_id
  const isDriver = driverId === state.session.user.id
  const openRequest = state.coverRequests.find(request => request.trip_id === trip.id && request.status === 'open')
  const actions = []
  if (trip.status === 'scheduled' && trip.scheduled_driver_id === state.session.user.id) actions.push(`<button class="action-button orange" data-action="request-cover" data-trip-id="${trip.id}" type="button">Request cover</button>`)
  if (openRequest && trip.scheduled_driver_id !== state.session.user.id) actions.push(`<button class="action-button green" data-action="accept-cover" data-request-id="${openRequest.id}" type="button">Volunteer · 20 points</button>`)
  if (isDriver && ['scheduled', 'cover_accepted'].includes(trip.status)) actions.push(`<button class="primary-button" data-action="start-trip" data-trip-id="${trip.id}" type="button">Start trip</button>`)
  if (isDriver && trip.status === 'in_progress') actions.push(`<button class="primary-button" data-action="complete-trip" data-trip-id="${trip.id}" type="button">Complete trip</button>`)
  el('tripDialogContent').innerHTML = `<div class="dialog-title"><h2>${kindLabel(trip.kind)}</h2><button class="close-button" onclick="document.getElementById('tripDialog').close()" aria-label="Close">×</button></div><p class="meta">${formatDate(trip.trip_date)} · ${escapeHTML(trip.time_label)}</p><h1>${escapeHTML(driverName(trip))}</h1><p>${statusPill(trip.status)}</p><p><strong>Children:</strong> ${trip.child_names.map(escapeHTML).join(', ') || 'No children listed'}</p>${trip.notes ? `<p class="meta">${escapeHTML(trip.notes)}</p>` : ''}<div class="button-row">${actions.join('') || '<span class="meta">No action is available for your role and the current trip status.</span>'}</div>`
  el('tripDialog').showModal()
}

async function shareInvitation(invitation) {
  if (!invitation) return
  const url = location.href.split('#')[0]
  const text = `Join ${state.activeGroup?.name || 'my Kidscarpool group'}\nParent: ${invitation.invited_parent_name}\nInvite code: ${invitation.token}\nOpen: ${url}`
  if (navigator.share) await navigator.share({ title: 'Kidscarpool invitation', text, url })
  else {
    await navigator.clipboard.writeText(text)
    toast('Invitation copied to clipboard')
  }
}

async function runAction(action, successMessage) {
  if (state.loading) return
  state.loading = true
  showConnection('Working…')
  try {
    const result = await action()
    if (successMessage) toast(successMessage)
    showConnection('Connected securely to Supabase.', 'success')
    return result
  } catch (error) {
    showConnection(error.message || String(error), 'error')
    throw error
  } finally {
    state.loading = false
  }
}

function activeTrips() {
  const today = new Date().toISOString().slice(0, 10)
  return state.trips
    .filter(trip => trip.trip_date >= today || ['in_progress', 'cover_requested'].includes(trip.status))
    .sort((a, b) => a.trip_date.localeCompare(b.trip_date) || a.kind.localeCompare(b.kind))
}

function currentMembership() { return state.memberships.find(member => member.user_id === state.session?.user?.id) }
function isAdmin() { return ['owner', 'admin'].includes(currentMembership()?.role) }
function memberName(userId) { return state.memberships.find(member => member.user_id === userId)?.parent_name || (userId ? 'Parent' : 'Unassigned') }
function driverName(trip) { return memberName(trip.actual_driver_id || trip.scheduled_driver_id) }
function kindLabel(kind) { return kind === 'morning_drop' ? 'Morning drop' : 'Afternoon pickup' }
function typeLabel(type) { return ({ no_school: 'No school', early_release: 'Early pickup', no_late_bird: 'No Late Bird', project_week: 'Project Week', first_day: 'First day', last_day: 'Last day' })[type] || humanize(type) }
function statusPill(status) {
  const labels = { scheduled: 'Confirmed', coverage_needed: 'Coverage needed', cover_requested: 'Cover requested', cover_accepted: 'Volunteer assigned', in_progress: 'In progress', completed: 'Completed', cancelled: 'Cancelled' }
  const css = ['coverage_needed', 'cover_requested'].includes(status) ? 'warning' : status === 'completed' ? 'complete' : ['cover_accepted', 'in_progress'].includes(status) ? 'info' : ''
  return `<span class="status-pill ${css}">${escapeHTML(labels[status] || capitalize(status))}</span>`
}
function countdownText(trip) {
  if (!trip.scheduled_time) return 'Time confirmation required'
  const diff = new Date(trip.scheduled_time).getTime() - Date.now()
  if (diff <= 0) return trip.status === 'in_progress' ? 'Trip underway' : 'Scheduled time reached'
  const days = Math.floor(diff / 86400000)
  const hours = Math.floor((diff % 86400000) / 3600000)
  const minutes = Math.floor((diff % 3600000) / 60000)
  if (days) return `In ${days}d ${hours}h`
  if (hours) return `In ${hours}h ${minutes}m`
  return `In ${Math.max(minutes, 1)} minutes`
}
function daysText(days = []) { return days.length ? days.map(day => DAY_NAMES[day - 1]).join(', ') : 'None' }
function formatDate(value) { return dateOnly(value).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }) }
function formatDateTime(value) { return new Date(value).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) }
function formatRange(start, end) { return start === end ? dateOnly(start).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : `${dateOnly(start).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}–${dateOnly(end).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}` }
function dateOnly(value) { return new Date(`${String(value).slice(0, 10)}T12:00:00`) }
function month(value) { return dateOnly(value).toLocaleDateString(undefined, { month: 'short' }) }
function day(value) { return dateOnly(value).getDate() }
function capitalize(value = '') { return value ? value.charAt(0).toUpperCase() + value.slice(1).replaceAll('_', ' ') : '' }
function humanize(value = '') { return value.replaceAll('_', ' ').replace(/\b\w/g, letter => letter.toUpperCase()) }
function slug(value) { return value.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') }
function empty(message) { return `<div class="empty-card"><p>${escapeHTML(message)}</p></div>` }
function escapeHTML(value = '') { return String(value).replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[char]) }
function show(id) { el(id).classList.remove('hidden') }
function hide(id) { el(id).classList.add('hidden') }
function showConnection(message, type = '') { const banner = el('connectionBanner'); banner.textContent = message; banner.className = `connection-banner ${type}`; banner.classList.remove('hidden') }
function toast(message, isError = false) { const node = el('toast'); node.textContent = message; node.className = `toast ${isError ? 'error' : ''}`; clearTimeout(toast.timer); toast.timer = setTimeout(() => node.classList.add('hidden'), 4200) }
async function sha256(file) { const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer()); return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('') }
