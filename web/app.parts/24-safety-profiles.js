// Family, driver and vehicle safety setup. Sensitive details are loaded only
// through role-aware RPCs; trip-scoped driver access is added in the next layer.

state.safetyProfile = null
let activeSafetyChildId = null
let activeVehicleId = null

const kcpSafetyPreviousLoadWorkspace = loadWorkspace
loadWorkspace = async function () {
  await kcpSafetyPreviousLoadWorkspace()
  if (!state.activeGroup) {
    state.safetyProfile = null
    return
  }

  try {
    const { data, error } = await supabase.rpc('kcp_my_safety_profile', {
      p_group_id: state.activeGroup.id
    })
    if (error) throw error
    state.safetyProfile = data || null
  } catch (error) {
    if (!/Could not find the function|schema cache/i.test(error.message || '')) {
      console.warn('KCP safety profile:', error.message || error)
    }
    state.safetyProfile = null
  }
}

if (!el('childSafetyDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="childSafetyDialog" class="modal safety-dialog">
      <form id="childSafetyForm" class="dialog-form">
        <div class="dialog-title"><div><span class="eyebrow">CHILD SAFETY</span><h2 id="childSafetyTitle">Transportation details</h2></div><button id="childSafetyClose" class="close-button" type="button" aria-label="Close">×</button></div>
        <label>Pickup address<input id="childPickupAddress" autocomplete="street-address"></label>
        <label>Drop-off address<input id="childDropoffAddress" autocomplete="street-address"></label>
        <label>Seat requirement<select id="childSeatRequirement"><option value="none">None</option><option value="booster">Booster seat</option><option value="car_seat">Car seat</option><option value="front_seat_restricted">Must not use front seat</option><option value="other">Other</option></select></label>
        <div class="two-column-form">
          <label>Emergency contact name<input id="childEmergencyName" autocomplete="name"></label>
          <label>Emergency contact phone<input id="childEmergencyPhone" inputmode="tel" autocomplete="tel"></label>
        </div>
        <label>Authorized pickup people <span class="optional">one name per line</span><textarea id="childAuthorizedPeople" rows="3"></textarea></label>
        <label>Important information for the driver <span class="optional">only what a driver must know</span><textarea id="childCriticalAlert" rows="2"></textarea></label>
        <label>Pickup instructions<textarea id="childPickupInstructions" rows="3"></textarea></label>
        <label class="checkbox-row"><input id="childSafetyConsent" type="checkbox"><span><strong>Confirm these details may be shown to an assigned driver during the ride window</strong></span></label>
        <button class="primary-button" type="submit">Save child safety details</button>
      </form>
    </dialog>

    <dialog id="driverSafetyDialog" class="modal safety-dialog">
      <form id="driverSafetyForm" class="dialog-form">
        <div class="dialog-title"><div><span class="eyebrow">DRIVER + VEHICLE</span><h2>Driver and vehicle details</h2></div><button id="driverSafetyClose" class="close-button" type="button" aria-label="Close">×</button></div>
        <div class="two-column-form">
          <label>Emergency contact name<input id="driverEmergencyName"></label>
          <label>Emergency contact phone<input id="driverEmergencyPhone" inputmode="tel"></label>
        </div>
        <label class="checkbox-row"><input id="driverLicenseAcknowledged" type="checkbox"><span><strong>I confirm that I hold a valid license for this vehicle</strong></span></label>
        <label class="checkbox-row"><input id="driverInsuranceAcknowledged" type="checkbox"><span><strong>I confirm that required vehicle insurance is active</strong></span></label>
        <label class="checkbox-row"><input id="driverSafetyAcknowledged" type="checkbox"><span><strong>I agree to follow group safety and legal seating requirements</strong></span></label>
        <label>Driver notes <span class="optional">optional</span><textarea id="driverSafetyNotes" rows="2"></textarea></label>
        <hr>
        <h3>Vehicle</h3>
        <label>Description<input id="vehicleDescription" placeholder="SUV, minivan, sedan or model"></label>
        <div class="three-column-form">
          <label>Child seats<input id="vehicleSeatCapacity" type="number" min="1" max="12" value="4"></label>
          <label>Boosters<input id="vehicleBoosterCapacity" type="number" min="0" max="12" value="0"></label>
          <label>Car seats<input id="vehicleCarSeatCapacity" type="number" min="0" max="12" value="0"></label>
        </div>
        <label class="checkbox-row"><input id="vehicleActive" type="checkbox" checked><span><strong>This vehicle may be used for rides</strong></span></label>
        <button class="primary-button" type="submit">Save driver and vehicle details</button>
      </form>
    </dialog>`)
}

function closeSafetyDialog(id) {
  const dialog = el(id)
  if (dialog?.open) dialog.close('cancel')
}

for (const [buttonId, dialogId] of [
  ['childSafetyClose','childSafetyDialog'],
  ['driverSafetyClose','driverSafetyDialog']
]) {
  el(buttonId)?.addEventListener('click', () => closeSafetyDialog(dialogId))
  el(dialogId)?.addEventListener('cancel', event => {
    event.preventDefault()
    closeSafetyDialog(dialogId)
  })
  el(dialogId)?.addEventListener('click', event => {
    if (event.target === el(dialogId)) closeSafetyDialog(dialogId)
  })
}

const kcpSafetyPreviousRenderSettings = renderSettings
renderSettings = function () {
  kcpSafetyPreviousRenderSettings()
  renderSafetySettingsCard()
}

function renderSafetySettingsCard() {
  const settings = el('settingsView')
  settings?.querySelector('[data-safety-card]')?.remove()
  if (!state.activeGroup || !state.safetyProfile) return

  const access = kcpAccess()
  if (access.isViewer) return
  const profile = state.safetyProfile
  const participant = profile.participant
  const children = profile.children || []
  const vehicles = profile.vehicles || []
  const driver = profile.driverProfile
  const driverReady = Boolean(
    driver?.license_acknowledged_at
      && driver?.insurance_acknowledged_at
      && driver?.safety_terms_acknowledged_at
      && vehicles.some(vehicle => vehicle.active)
  )

  settings.insertAdjacentHTML('beforeend', `
    <div class="card" data-safety-card>
      <div class="group-card-head">
        <div><span class="eyebrow">FAMILY + VEHICLE SAFETY</span><h2>Transportation readiness</h2></div>
        <span class="status-pill ${profile.required && !driverReady && participant?.can_drive ? 'warning' : 'complete'}">${profile.required ? 'Required' : 'Recommended'}</span>
      </div>
      <p class="meta">Private details are hidden from view-only members and shown to an assigned driver only while they are handling the ride.</p>
      <h3>Children or riders</h3>
      ${children.map(child => {
        const safety = child.safetyProfile || {}
        const complete = Boolean(safety.pickup_address && safety.emergency_contact_name && safety.consent_confirmed_at)
        return `<div class="timeline-row safety-row"><div><strong>${escapeHTML(child.name)}</strong><span class="meta">${escapeHTML(humanize(safety.seat_requirement || 'none'))} · ${complete ? 'Safety details ready' : 'Details incomplete'}</span></div><button class="action-button" data-action="edit-child-safety" data-child-id="${child.id}" type="button">${complete ? 'Edit' : 'Complete'}</button></div>`
      }).join('') || '<p class="meta">No child is attached to this membership.</p>'}
      ${participant?.can_drive ? `
        <h3 style="margin-top:18px">Driver and vehicles</h3>
        <div class="timeline-row safety-row"><div><strong>${driverReady ? 'Ready for capacity checks' : 'Driving details incomplete'}</strong><span class="meta">${vehicles.filter(vehicle => vehicle.active).length} active vehicle${vehicles.filter(vehicle => vehicle.active).length === 1 ? '' : 's'}</span></div><button class="action-button" data-action="edit-driver-safety" type="button">${driverReady ? 'Edit' : 'Complete'}</button></div>
        ${vehicles.map(vehicle => `<div class="vehicle-summary"><strong>${escapeHTML(vehicle.description)}</strong><span>${vehicle.seat_capacity} child seats · ${vehicle.booster_capacity} boosters · ${vehicle.car_seat_capacity} car seats${vehicle.active ? '' : ' · inactive'}</span></div>`).join('')}` : ''}
    </div>`)
}

const kcpSafetyPreviousRenderGroupAdminPanel = renderGroupAdminPanel
renderGroupAdminPanel = function () {
  kcpSafetyPreviousRenderGroupAdminPanel()
  if (!state.activeGroup || !isAdmin()) return
  const panel = el('groupAdminPanel')
  if (panel?.querySelector('[data-group-safety-requirement]')) return
  panel?.insertAdjacentHTML('beforeend', `
    <div class="card" data-group-safety-requirement>
      <span class="eyebrow">SAFETY</span>
      <h2>Required driver and vehicle details</h2>
      <p class="meta">Before giving someone a ride, KCP checks that the driver has confirmed their license and insurance and that the vehicle has suitable seats.</p>
      <label class="checkbox-row"><input id="groupSafetyRequired" type="checkbox" ${state.activeGroup.safety_profiles_required ? 'checked' : ''}><span><strong>Require completed safety details</strong></span></label>
    </div>`)
}

document.addEventListener('click', async event => {
  const childButton = event.target.closest('[data-action="edit-child-safety"]')
  if (childButton) {
    event.preventDefault()
    openChildSafety(childButton.dataset.childId)
    return
  }

  const driverButton = event.target.closest('[data-action="edit-driver-safety"]')
  if (driverButton) {
    event.preventDefault()
    openDriverSafety()
  }
})

document.addEventListener('change', async event => {
  if (event.target.id !== 'groupSafetyRequired') return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_set_group_safety_requirement', {
      p_group_id: state.activeGroup.id,
      p_required: event.target.checked
    })
    if (error) throw error
    state.activeGroup.safety_profiles_required = event.target.checked
  }, 'Safety requirement updated', { operation: 'set_group_safety_requirement' })
})

function openChildSafety(childId) {
  const child = (state.safetyProfile?.children || []).find(item => item.id === childId)
  if (!child) return
  activeSafetyChildId = childId
  const safety = child.safetyProfile || {}
  el('childSafetyTitle').textContent = child.name
  el('childPickupAddress').value = safety.pickup_address || ''
  el('childDropoffAddress').value = safety.dropoff_address || ''
  el('childSeatRequirement').value = safety.seat_requirement || 'none'
  el('childEmergencyName').value = safety.emergency_contact_name || ''
  el('childEmergencyPhone').value = safety.emergency_contact_phone || ''
  el('childAuthorizedPeople').value = (safety.authorized_pickup_people || []).map(person => person.name || person).join('\n')
  el('childCriticalAlert').value = safety.critical_alert || ''
  el('childPickupInstructions').value = safety.pickup_instructions || ''
  el('childSafetyConsent').checked = Boolean(safety.consent_confirmed_at)
  el('childSafetyDialog').showModal()
}

el('childSafetyForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  if (!activeSafetyChildId) return
  await runAction(async () => {
    const people = el('childAuthorizedPeople').value.split('\n').map(value => value.trim()).filter(Boolean).map(name => ({ name }))
    const { error } = await supabase.rpc('kcp_upsert_child_safety_profile', {
      p_child_id: activeSafetyChildId,
      p_pickup_address: el('childPickupAddress').value.trim() || null,
      p_dropoff_address: el('childDropoffAddress').value.trim() || null,
      p_authorized_pickup_people: people,
      p_emergency_contact_name: el('childEmergencyName').value.trim() || null,
      p_emergency_contact_phone: el('childEmergencyPhone').value.trim() || null,
      p_seat_requirement: el('childSeatRequirement').value,
      p_critical_alert: el('childCriticalAlert').value.trim() || null,
      p_pickup_instructions: el('childPickupInstructions').value.trim() || null,
      p_confirm_consent: el('childSafetyConsent').checked
    })
    if (error) throw error
    closeSafetyDialog('childSafetyDialog')
    await loadWorkspace()
    renderAll()
  }, 'Child safety details saved', { operation: 'save_child_safety' })
})

function openDriverSafety() {
  const profile = state.safetyProfile || {}
  const driver = profile.driverProfile || {}
  const vehicle = (profile.vehicles || []).find(item => item.active) || profile.vehicles?.[0] || {}
  activeVehicleId = vehicle.id || null
  el('driverEmergencyName').value = driver.emergency_contact_name || ''
  el('driverEmergencyPhone').value = driver.emergency_contact_phone || ''
  el('driverLicenseAcknowledged').checked = Boolean(driver.license_acknowledged_at)
  el('driverInsuranceAcknowledged').checked = Boolean(driver.insurance_acknowledged_at)
  el('driverSafetyAcknowledged').checked = Boolean(driver.safety_terms_acknowledged_at)
  el('driverSafetyNotes').value = driver.notes || ''
  el('vehicleDescription').value = vehicle.description || ''
  el('vehicleSeatCapacity').value = vehicle.seat_capacity || 4
  el('vehicleBoosterCapacity').value = vehicle.booster_capacity || 0
  el('vehicleCarSeatCapacity').value = vehicle.car_seat_capacity || 0
  el('vehicleActive').checked = vehicle.active ?? true
  el('driverSafetyDialog').showModal()
}

el('driverSafetyForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  const participantId = state.safetyProfile?.participant?.id
  if (!participantId) return

  await runAction(async () => {
    const { error: driverError } = await supabase.rpc('kcp_upsert_driver_safety_profile', {
      p_participant_id: participantId,
      p_emergency_contact_name: el('driverEmergencyName').value.trim() || null,
      p_emergency_contact_phone: el('driverEmergencyPhone').value.trim() || null,
      p_license_acknowledged: el('driverLicenseAcknowledged').checked,
      p_insurance_acknowledged: el('driverInsuranceAcknowledged').checked,
      p_safety_terms_acknowledged: el('driverSafetyAcknowledged').checked,
      p_notes: el('driverSafetyNotes').value.trim() || null
    })
    if (driverError) throw driverError

    const { error: vehicleError } = await supabase.rpc('kcp_upsert_vehicle', {
      p_participant_id: participantId,
      p_vehicle_id: activeVehicleId,
      p_description: el('vehicleDescription').value.trim(),
      p_seat_capacity: Number(el('vehicleSeatCapacity').value),
      p_booster_capacity: Number(el('vehicleBoosterCapacity').value),
      p_car_seat_capacity: Number(el('vehicleCarSeatCapacity').value),
      p_active: el('vehicleActive').checked
    })
    if (vehicleError) throw vehicleError

    closeSafetyDialog('driverSafetyDialog')
    await loadWorkspace()
    renderAll()
  }, 'Driver and vehicle details saved', { operation: 'save_driver_vehicle_safety' })
})

const kcpSafetyPreviousShowTrip = showTrip
showTrip = function (tripId) {
  kcpSafetyPreviousShowTrip(tripId)
  const participantId = state.safetyProfile?.participant?.id
  if (!participantId || !kcpAccess().canDrive) return

  queueMicrotask(async () => {
    const { data, error } = await supabase.rpc('kcp_trip_capacity_status', {
      p_trip_id: tripId,
      p_participant_id: participantId
    })
    if (error || !data?.[0]) return
    const status = data[0]
    el('tripDialogContent')?.insertAdjacentHTML('beforeend', `
      <div class="card capacity-status ${status.eligible ? 'eligible' : 'blocked'}">
        <h3>${status.eligible ? 'Vehicle capacity compatible' : 'Driving readiness needs attention'}</h3>
        <p>${escapeHTML(status.message)}</p>
        <div class="metric-row"><div class="metric"><strong>${status.available_seats}/${status.required_seats}</strong><small>Seats</small></div><div class="metric"><strong>${status.available_boosters}/${status.required_boosters}</strong><small>Boosters</small></div><div class="metric"><strong>${status.available_car_seats}/${status.required_car_seats}</strong><small>Car seats</small></div></div>
      </div>`)
  })
}
