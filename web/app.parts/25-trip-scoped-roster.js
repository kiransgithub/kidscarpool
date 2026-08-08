// Trip data is loaded through a role-aware RPC so Viewer records never include
// child names or free-form notes. Sensitive roster details are fetched only
// when the current role and ride window authorize them.

const kcpPrivatePreviousSelectRows = selectRows
selectRows = async function (table, configure) {
  if (table !== 'kcp_trips') return kcpPrivatePreviousSelectRows(table, configure)
  if (!state.activeGroup?.id) return []

  const { data, error } = await supabase.rpc('kcp_group_trips', {
    p_group_id: state.activeGroup.id
  })
  if (error) throw error
  return Array.isArray(data) ? data : []
}

const kcpRosterPreviousShowTrip = showTrip
showTrip = function (tripId) {
  kcpRosterPreviousShowTrip(tripId)
  if (kcpAccess().isViewer) return

  queueMicrotask(async () => {
    const content = el('tripDialogContent')
    if (!content || content.querySelector('[data-operational-roster]')) return

    const { data, error } = await supabase.rpc('kcp_get_trip_operational_roster', {
      p_trip_id: tripId
    })
    if (error || !data?.length) return

    const scope = data[0].access_scope
    content.insertAdjacentHTML('beforeend', `
      <section class="card operational-roster" data-operational-roster data-access-scope="${escapeHTML(scope)}">
        <div class="group-card-head">
          <div><span class="eyebrow">OPERATIONAL ROSTER</span><h3>${scope === 'assigned_driver' ? 'Pickup and safety details' : scope === 'own_child' ? 'Your child details' : 'Group ride details'}</h3></div>
          <span class="status-pill info">${escapeHTML(humanize(scope))}</span>
        </div>
        <p class="meta">Sensitive roster access is logged. Details are provided only for this ride and should not be copied or shared.</p>
        <div class="operational-child-list">
          ${data.map(operationalChildCard).join('')}
        </div>
      </section>`)
  })
}

function operationalChildCard(child) {
  const pickupNavigation = child.pickup_address
    ? `https://maps.apple.com/?q=${encodeURIComponent(child.pickup_address)}`
    : null
  const dropoffNavigation = child.dropoff_address
    ? `https://maps.apple.com/?q=${encodeURIComponent(child.dropoff_address)}`
    : null
  const people = Array.isArray(child.authorized_pickup_people)
    ? child.authorized_pickup_people.map(person => person.name || person).filter(Boolean)
    : []

  return `<article class="operational-child-card">
    <div class="operational-child-head">
      <div><strong>${escapeHTML(child.child_name)}</strong><span>${escapeHTML(humanize(child.seat_requirement || 'none'))}</span></div>
      ${child.pickup_tag ? `<span class="badge">Tag ${escapeHTML(child.pickup_tag)}</span>` : ''}
    </div>
    ${child.critical_alert ? `<div class="critical-transport-alert"><strong>Critical</strong><span>${escapeHTML(child.critical_alert)}</span></div>` : ''}
    <dl class="operational-details">
      <div><dt>Pickup</dt><dd>${escapeHTML(child.pickup_address || 'Not provided')}</dd></div>
      <div><dt>Drop-off</dt><dd>${escapeHTML(child.dropoff_address || 'Group destination')}</dd></div>
      ${people.length ? `<div><dt>Authorized people</dt><dd>${people.map(escapeHTML).join(', ')}</dd></div>` : ''}
      ${child.pickup_instructions ? `<div><dt>Instructions</dt><dd>${escapeHTML(child.pickup_instructions)}</dd></div>` : ''}
      ${child.emergency_contact_name ? `<div><dt>Emergency contact</dt><dd>${escapeHTML(child.emergency_contact_name)}${child.emergency_contact_phone ? ` · ${escapeHTML(child.emergency_contact_phone)}` : ''}</dd></div>` : ''}
    </dl>
    <div class="button-row">
      ${pickupNavigation ? `<a class="action-button" href="${pickupNavigation}" target="_blank" rel="noopener">Navigate to pickup</a>` : ''}
      ${dropoffNavigation ? `<a class="action-button" href="${dropoffNavigation}" target="_blank" rel="noopener">Navigate to drop-off</a>` : ''}
      ${child.emergency_contact_phone ? `<a class="action-button orange" href="tel:${escapeHTML(child.emergency_contact_phone)}">Call emergency contact</a>` : ''}
    </div>
  </article>`
}
