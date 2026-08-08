// Generic one-time recovery. No group code or member identity is embedded in
// the client; an administrator supplies both through the database workflow.

const kcpGenericRecoveryDialog = el('recoverGroupDialog')
const kcpGenericRecoveryForm = el('recoverGroupForm')
const kcpGenericRecoveryClose = kcpGenericRecoveryDialog?.querySelector('.close-button')

if (kcpGenericRecoveryClose) {
  kcpGenericRecoveryClose.type = 'button'
  kcpGenericRecoveryClose.removeAttribute('formmethod')
  kcpGenericRecoveryClose.removeAttribute('value')
  kcpGenericRecoveryClose.addEventListener('click', () => kcpGenericRecoveryDialog.close('cancel'))
}

kcpGenericRecoveryDialog?.addEventListener('cancel', event => {
  event.preventDefault()
  kcpGenericRecoveryDialog.close('cancel')
})

kcpGenericRecoveryDialog?.addEventListener('click', event => {
  if (event.target === kcpGenericRecoveryDialog) kcpGenericRecoveryDialog.close('cancel')
})

if (kcpGenericRecoveryForm) {
  kcpGenericRecoveryForm.addEventListener('submit', async event => {
    event.preventDefault()
    event.stopImmediatePropagation()

    await runAction(async () => {
      const groupCode = el('recoverGroupCode').value.trim().toUpperCase()
      const memberName = el('recoverParentName').value.trim()
      const recoveryCode = el('recoverCode').value.trim().toUpperCase()
      if (!groupCode || !memberName || !recoveryCode) {
        throw new Error('Enter the group code, member name, and one-time recovery code.')
      }

      const { data, error } = await supabase.rpc('kcp_recover_seeded_roster', {
        p_group_code: groupCode,
        p_parent_name: memberName,
        p_recovery_code: recoveryCode
      })
      if (error) throw error

      const recovered = data?.[0]
      if (!recovered?.group_id) throw new Error('Recovery completed without returning the group.')
      localStorage.setItem(ACTIVE_GROUP_KEY, recovered.group_id)
      await rememberGroup(recovered.group_id, 'Recovered KCP group')
      kcpGenericRecoveryDialog.close('success')
      kcpGenericRecoveryForm.reset()
      await loadProfile()
      await refreshAll()
      navigate('groups')
    }, 'Group access recovered')
  }, { capture: true })
}

// Existing members can open recovery from Settings without any prefilled pilot
// identity. Normal parents can also restore with their original invitation.
const kcpDatabasePreviousRenderSettings = renderSettings
renderSettings = function () {
  kcpDatabasePreviousRenderSettings()
  const profileCard = el('profileCard')
  if (!profileCard || profileCard.querySelector('[data-action="open-generic-recovery"]')) return
  profileCard.insertAdjacentHTML('beforeend', `
    <button class="secondary-button" data-action="open-generic-recovery" type="button">Recover another group</button>`)
}

document.addEventListener('click', event => {
  const button = event.target.closest('[data-action="open-generic-recovery"]')
  if (!button) return
  event.preventDefault()
  el('recoverGroupCode').value = ''
  el('recoverParentName').value = state.profile?.display_name || ''
  el('recoverCode').value = ''
  kcpGenericRecoveryDialog?.showModal()
}, true)
