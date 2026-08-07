// Canonical seeded-owner recovery. A profile may be named "Kiran Kumar" while
// the roster key is simply "Kiran"; the one-time recovery code authenticates
// the transfer, and this layer normalizes only that pilot profile before it.

const kcpRecoveryForm = el('recoverGroupForm')

document.addEventListener('click', event => {
  const button = event.target.closest('[data-action="open-basis-recovery"]')
  if (!button) return

  event.preventDefault()
  event.stopImmediatePropagation()
  el('recoverGroupCode').value = state.seededPilotStatus?.group_code || 'KCP-BASIS-2026-27'
  el('recoverParentName').value = state.seededPilotStatus?.roster_parent_name || 'Kiran'
  el('recoverCode').value = ''
  el('recoverGroupDialog').showModal()
}, true)

if (kcpRecoveryForm) {
  kcpRecoveryForm.addEventListener('submit', async event => {
    event.preventDefault()
    event.stopImmediatePropagation()

    await runAction(async () => {
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
        p_recovery_code: el('recoverCode').value.trim().toUpperCase()
      })
      if (error) throw error

      const recovered = data?.[0]
      if (recovered?.group_id) {
        localStorage.setItem(ACTIVE_GROUP_KEY, recovered.group_id)
        await rememberGroup(recovered.group_id, 'Recovered installed KCP app')
      }

      el('recoverGroupDialog').close()
      kcpRecoveryForm.reset()
      await refreshAll()
      navigate('groups')
    }, 'Group access recovered and remembered on this device')
  }, { capture: true })
}
