// Enhancements for the preloaded BASIS Phoenix Primary 2026-27 pilot.
// This file is concatenated after the core app and intentionally wraps the
// existing functions instead of duplicating the main implementation.

state.rosterSlots = []

const kcpOriginalLoadWorkspace = loadWorkspace
loadWorkspace = async function () {
  await kcpOriginalLoadWorkspace()
  if (!state.activeGroup) {
    state.rosterSlots = []
    return
  }
  try {
    state.rosterSlots = await selectRows(
      'kcp_roster_slots',
      query => query.eq('group_id', state.activeGroup.id).order('fixed_weekday')
    )
  } catch (error) {
    // Keeps older/local schemas usable while the additive migration is applied.
    console.warn('KCP roster slots are not available yet:', error.message || error)
    state.rosterSlots = []
  }
}

const kcpOriginalClearWorkspace = clearWorkspace
clearWorkspace = function () {
  kcpOriginalClearWorkspace()
  state.rosterSlots = []
}

const kcpOriginalDriverName = driverName
driverName = function (trip) {
  if (trip?.actual_driver_name) return trip.actual_driver_name
  if (trip?.scheduled_driver_name) return trip.scheduled_driver_name
  return kcpOriginalDriverName(trip)
}

const kcpOriginalMemberName = memberName
memberName = function (userId) {
  const member = state.memberships.find(item => item.user_id === userId)
  if (member) return member.parent_name
  const slot = state.rosterSlots.find(item => item.claimed_user_id === userId)
  if (slot) return slot.parent_name
  return userId ? kcpOriginalMemberName(userId) : 'System'
}

const kcpOriginalRenderGroups = renderGroups
renderGroups = function () {
  kcpOriginalRenderGroups()

  const canonicalLoaded = state.groups.some(group => group.group_code === 'KCP-BASIS-2026-27')
  const mayClaim = /^kiran\b/i.test(state.profile?.display_name || '') && !canonicalLoaded
  if (!mayClaim) return

  const card = `
    <article class="group-card active">
      <div class="group-card-head">
        <div>
          <span class="eyebrow">PRELOADED PILOT</span>
          <h2>BASIS Phoenix Primary Carpool</h2>
          <div class="meta">2026–27 · schedule begins Monday, Aug 10</div>
        </div>
        <span class="status-pill info">Ready</span>
      </div>
      <p class="meta">Includes the authoritative holiday calendar, four-family roster, pickup tags, 177 school days, 354 trips, and the agreed weekday/Friday rotation.</p>
      <button class="primary-button" data-action="claim-basis-pilot" type="button">Load the preconfigured group</button>
    </article>`
  el('groupsList').insertAdjacentHTML('afterbegin', card)
}

const kcpOriginalRenderGroupAdminPanel = renderGroupAdminPanel
renderGroupAdminPanel = function () {
  kcpOriginalRenderGroupAdminPanel()
  if (!state.activeGroup || !state.rosterSlots.length) return

  const weekday = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday']
  const rosterCard = `
    <div class="card">
      <h2>Confirmed pilot roster</h2>
      <p class="meta">Pickup tags are visible only to approved members of this private group.</p>
      ${state.rosterSlots.map(slot => `
        <div class="timeline-row">
          <div>
            <strong>${escapeHTML(slot.parent_name)}</strong>
            <span class="meta">${escapeHTML(slot.child_name)} · Grade ${slot.grade} · ${weekday[slot.fixed_weekday]} · Friday position ${slot.friday_rotation_order}</span>
          </div>
          <div>
            <span class="badge">Tag ${escapeHTML(slot.pickup_tag)}</span>
            <span class="role-pill">${slot.claimed_user_id ? 'Joined' : 'Invited'}</span>
          </div>
        </div>`).join('')}
    </div>`
  el('groupAdminPanel').insertAdjacentHTML('beforeend', rosterCard)
}

const kcpOriginalShowTrip = showTrip
showTrip = function (tripId) {
  kcpOriginalShowTrip(tripId)
  const trip = state.trips.find(item => item.id === tripId)
  if (!trip || !state.rosterSlots.length) return

  const tags = (trip.child_names || []).map(child => {
    const slot = state.rosterSlots.find(item => item.child_name === child)
    return slot ? `${escapeHTML(child)} <span class="badge">Tag ${escapeHTML(slot.pickup_tag)}</span>` : escapeHTML(child)
  }).join('<br>')

  const content = el('tripDialogContent')
  const marker = content.querySelector('[data-kcp-pickup-tags]')
  if (marker) marker.remove()
  content.insertAdjacentHTML(
    'beforeend',
    `<div class="card" data-kcp-pickup-tags style="margin-top:14px"><h3>Pickup tags</h3><p style="line-height:2">${tags || 'No children listed'}</p></div>`
  )
}

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-action="claim-basis-pilot"]')
  if (!button) return
  event.preventDefault()

  try {
    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_claim_basis_pilot')
      if (error) throw error
      const claimed = data?.[0]
      if (claimed?.group_id) localStorage.setItem(ACTIVE_GROUP_KEY, claimed.group_id)
      await refreshAll()
      navigate('groups')
    }, 'BASIS pilot group loaded with the published schedule')
  } catch (error) {
    toast(error.message || String(error), true)
  }
})
