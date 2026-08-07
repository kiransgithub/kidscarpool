import {
  normalizeRecoveryCode,
  recoveryErrorMessage,
  resolveRecoveryAttempt
} from './logic.js'

// Canonical seeded-owner recovery. A profile may be named "Kiran Kumar" while
// the roster key is simply "Kiran"; the one-time recovery code authenticates
// the transfer, and this layer normalizes only that pilot profile before it.

const kcpRecoveryDialog = el('recoverGroupDialog')
const kcpRecoveryForm = el('recoverGroupForm')
const kcpRecoveryCloseButton = kcpRecoveryDialog?.querySelector('.close-button') || null
const kcpRecoverySubmitButton = kcpRecoveryForm?.querySelector('button[type="submit"], .primary-button') || null
let kcpRecoveryStatus = el('recoverGroupStatus')

// `formmethod="dialog"` turns the X button into a form submission. The capture
// submit handler below then intercepts it as a recovery attempt, which is why
// the popup could not be closed. Convert it to an explicit non-submit button.
if (kcpRecoveryCloseButton) {
  kcpRecoveryCloseButton.type = 'button'
  kcpRecoveryCloseButton.removeAttribute('formmethod')
  kcpRecoveryCloseButton.removeAttribute('value')
  kcpRecoveryCloseButton.dataset.action = 'close-recovery-dialog'
}

if (kcpRecoveryForm && !kcpRecoveryStatus) {
  kcpRecoveryStatus = document.createElement('div')
  kcpRecoveryStatus.id = 'recoverGroupStatus'
  kcpRecoveryStatus.className = 'recovery-dialog-status hidden'
  kcpRecoveryStatus.setAttribute('role', 'status')
  kcpRecoveryStatus.setAttribute('aria-live', 'polite')

  const recoveryNote = kcpRecoveryForm.querySelector('.optional-calendar-note')
  if (recoveryNote) recoveryNote.insertAdjacentElement('afterend', kcpRecoveryStatus)
  else kcpRecoveryForm.prepend(kcpRecoveryStatus)
}

function setRecoveryStatus(message = '', tone = 'info') {
  if (!kcpRecoveryStatus) return
  kcpRecoveryStatus.textContent = message
  kcpRecoveryStatus.className = `recovery-dialog-status ${tone}`
  kcpRecoveryStatus.classList.toggle('hidden', !message)
}

function setRecoveryBusy(busy) {
  if (!kcpRecoverySubmitButton) return
  kcpRecoverySubmitButton.disabled = busy
  kcpRecoverySubmitButton.textContent = busy
    ? 'Recovering group access…'
    : 'Recover and remember this device'
}

function closeRecoveryDialog({ reset = true } = {}) {
  if (kcpRecoveryDialog?.open) kcpRecoveryDialog.close('cancel')
  if (reset) kcpRecoveryForm?.reset()
  setRecoveryStatus('')
}

async function loadSeededPilotStatus() {
  const { data, error } = await supabase.rpc('kcp_seeded_pilot_status')
  if (error) return null
  return data?.[0] || null
}

document.addEventListener('click', event => {
  const openButton = event.target.closest('[data-action="open-basis-recovery"]')
  if (!openButton) return

  event.preventDefault()
  event.stopImmediatePropagation()
  el('recoverGroupCode').value = state.seededPilotStatus?.group_code || 'KCP-BASIS-2026-27'
  el('recoverParentName').value = state.seededPilotStatus?.roster_parent_name || 'Kiran'
  el('recoverCode').value = ''
  setRecoveryStatus('Enter a current one-time code. KCP will show the exact outcome here.', 'info')
  setRecoveryBusy(false)
  kcpRecoveryDialog?.showModal()
  setTimeout(() => el('recoverCode')?.focus(), 0)
}, true)

document.addEventListener('click', event => {
  const closeButton = event.target.closest('[data-action="close-recovery-dialog"]')
  if (!closeButton) return
  event.preventDefault()
  event.stopImmediatePropagation()
  closeRecoveryDialog()
}, true)

kcpRecoveryDialog?.addEventListener('cancel', event => {
  event.preventDefault()
  closeRecoveryDialog()
})

kcpRecoveryDialog?.addEventListener('click', event => {
  if (event.target === kcpRecoveryDialog) closeRecoveryDialog()
})

if (kcpRecoveryForm) {
  kcpRecoveryForm.addEventListener('submit', async event => {
    event.preventDefault()
    event.stopImmediatePropagation()

    if (state.loading) {
      setRecoveryStatus('Another KCP request is still finishing. Wait a moment and retry.', 'error')
      return
    }

    state.loading = true
    setRecoveryBusy(true)
    setRecoveryStatus('Checking the roster and one-time recovery code…', 'info')
    showConnection('Recovering group access…')

    let resolution = null

    try {
      // If an earlier click already committed the transfer but the browser did
      // not refresh, recover idempotently without requiring the consumed code.
      const currentStatus = await loadSeededPilotStatus()
      resolution = resolveRecoveryAttempt({ status: currentStatus })

      if (!resolution.ok) {
        const canonicalParentName = el('recoverParentName').value.trim()
        const { data: profile, error: profileError } = await supabase.rpc('kcp_upsert_profile', {
          p_display_name: canonicalParentName,
          p_phone: state.profile?.phone || null
        }).single()
        if (profileError) throw profileError
        state.profile = profile

        const { data, error } = await supabase.rpc('kcp_recover_seeded_roster', {
          p_group_code: el('recoverGroupCode').value.trim().toUpperCase(),
          p_parent_name: canonicalParentName,
          p_recovery_code: normalizeRecoveryCode(el('recoverCode').value)
        })

        const statusAfterAttempt = error ? await loadSeededPilotStatus() : null
        resolution = resolveRecoveryAttempt({
          rpcData: data,
          rpcError: error,
          status: statusAfterAttempt
        })
      }

      if (!resolution.ok) throw new Error(resolution.message)

      localStorage.setItem(ACTIVE_GROUP_KEY, resolution.groupId)
      setRecoveryStatus(
        resolution.alreadyRecovered
          ? 'Access was already transferred to this device. Refreshing the group now…'
          : 'Access recovered successfully. Loading the group…',
        'success'
      )
      showConnection('Group access recovered. Loading cloud data…', 'success')

      // Close immediately after the database confirms recovery. Remembering the
      // device and refreshing are follow-up steps and must never trap the user.
      if (kcpRecoveryDialog?.open) kcpRecoveryDialog.close('success')
      kcpRecoveryForm.reset()
      toast('Group access recovered on this device')

      try {
        await rememberGroup(resolution.groupId, 'Recovered installed KCP app')
        await loadProfile()
        await refreshAll()
        navigate('groups')
      } catch (refreshError) {
        const message = 'Access was recovered, but the screen could not refresh. Reload KCP once; do not reuse the recovery code.'
        console.warn('KCP recovery refresh:', refreshError)
        showConnection(message, 'error')
        toast(message, true)
      }
    } catch (error) {
      const message = recoveryErrorMessage(error)
      setRecoveryStatus(message, 'error')
      showConnection(message, 'error')
      toast(message, true)
    } finally {
      state.loading = false
      setRecoveryBusy(false)
    }
  }, { capture: true })
}
