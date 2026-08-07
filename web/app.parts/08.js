// Account recovery, remembered-device UX and open cover withdrawal.
// The wrappers below preserve the existing visual components and add only the
// controls required by the regression fixes.

const recoverGroupForm = el('recoverGroupForm')
if (recoverGroupForm) {
  recoverGroupForm.addEventListener('submit', async event => {
    event.preventDefault()

    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_recover_seeded_roster', {
        p_group_code: el('recoverGroupCode').value.trim().toUpperCase(),
        p_parent_name: el('recoverParentName').value.trim(),
        p_recovery_code: el('recoverCode').value.trim().toUpperCase()
      })
      if (error) throw error

      const recovered = data?.[0]
      if (recovered?.group_id) {
        localStorage.setItem(ACTIVE_GROUP_KEY, recovered.group_id)
        await rememberGroup(recovered.group_id, 'Recovered installed KCP app')
      }

      el('recoverGroupDialog').close()
      recoverGroupForm.reset()
      await refreshAll()
      navigate('groups')
    }, 'Group access recovered and remembered on this device')
  })
}

async function withdrawCoverRequest(requestId) {
  const request = state.coverRequests.find(item => item.id === requestId)
  if (!request || request.status !== 'open') {
    throw new Error('This cover request is no longer open.')
  }

  if (!confirm('Withdraw this cover request and continue as the assigned driver?')) return

  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_withdraw_cover', {
      p_request_id: requestId,
      p_reason: 'Driver is available again'
    })
    if (error) throw error

    await loadWorkspace()
    renderAll()
    if (el('tripDialog')?.open) el('tripDialog').close()
  }, 'Cover request withdrawn; the original driver is assigned again')
}

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-action="withdraw-cover"]')
  if (!button) return
  event.preventDefault()

  try {
    await withdrawCoverRequest(button.dataset.requestId)
  } catch (error) {
    toast(error.message || String(error), true)
  }
})

function ownOpenCoverRequest(tripId) {
  return state.coverRequests.find(request =>
    request.trip_id === tripId
    && request.status === 'open'
    && request.requested_by === state.session?.user?.id
  ) || null
}

function withdrawButtonHTML(request, compact = false) {
  if (!request) return ''
  return `<button class="action-button red" data-action="withdraw-cover" data-request-id="${request.id}" type="button">${compact ? 'Withdraw' : 'Withdraw cover request'}</button>`
}

const kcpWithdrawalTripRow = tripRow
tripRow = function (trip) {
  const html = kcpWithdrawalTripRow(trip)
  const request = ownOpenCoverRequest(trip.id)
  if (!request) return html

  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const row = template.content.firstElementChild
  const buttonRow = row?.querySelector('.button-row')
  if (buttonRow && !buttonRow.querySelector('[data-action="withdraw-cover"]')) {
    buttonRow.insertAdjacentHTML('beforeend', withdrawButtonHTML(request, true))
  }
  return row?.outerHTML || html
}

const kcpWithdrawalRenderVolunteers = renderVolunteers
renderVolunteers = function () {
  kcpWithdrawalRenderVolunteers()

  const openRequests = state.coverRequests.filter(request => request.status === 'open')
  const rows = [...el('volunteerList').querySelectorAll('.trip-row')]
  openRequests.forEach((request, index) => {
    if (request.requested_by !== state.session?.user?.id) return
    const buttonRow = rows[index]?.querySelector('.button-row')
    if (buttonRow && !buttonRow.querySelector('[data-action="withdraw-cover"]')) {
      buttonRow.insertAdjacentHTML('beforeend', withdrawButtonHTML(request))
    }
  })
}

const kcpWithdrawalShowTrip = showTrip
showTrip = function (tripId) {
  kcpWithdrawalShowTrip(tripId)

  const request = ownOpenCoverRequest(tripId)
  if (!request) return

  const actionStack = el('tripDialogContent')?.querySelector('.trip-action-stack')
  if (actionStack && !actionStack.querySelector('[data-action="withdraw-cover"]')) {
    actionStack.insertAdjacentHTML('afterbegin', withdrawButtonHTML(request))
  }
}

const kcpRememberedRenderSettings = renderSettings
renderSettings = function () {
  kcpRememberedRenderSettings()

  const rememberedCount = state.deviceLinks?.length || 0
  const card = document.createElement('div')
  card.className = 'card'
  card.id = 'rememberedAccessCard'
  card.innerHTML = `
    <h2>Remembered access</h2>
    <p><strong>${rememberedCount} group${rememberedCount === 1 ? '' : 's'}</strong> remembered on this installed app.</p>
    <p class="meta">KCP stores the Supabase session in IndexedDB with a local-storage fallback and keeps a revocable group-specific recovery credential. Normal app restarts should not ask for the profile or invitation again.</p>
    <p class="meta" style="margin-bottom:0">Clearing all website data or changing devices removes local credentials. Parents can reuse the original invitation code; the seeded owner can use a project-issued one-time recovery code.</p>`

  const profileCard = el('profileCard')
  profileCard?.insertAdjacentElement('afterend', card)
}

supabase.auth.onAuthStateChange((_event, session) => {
  if (session) state.session = session
})
