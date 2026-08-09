// Role-adaptive invitations. Viewer and non-driving Admin invitations do not
// require fake child data, and shared links open a focused acceptance dialog.

const adaptiveInviteForm = el('inviteForm')
const adaptiveInviteRole = el('inviteRole')
const adaptiveInviteChild = el('inviteChild')
const adaptiveInviteGrade = el('inviteGrade')

function installAdaptiveInvitationFields() {
  if (!adaptiveInviteForm || el('inviteEmail')) return

  const roleLabel = adaptiveInviteRole?.closest('label')
  const nameLabel = el('inviteName')?.closest('label')
  roleLabel?.classList.add('invite-role-first')
  nameLabel?.insertAdjacentHTML('afterend', `
    <label>Email <span class="optional">optional but recommended</span>
      <input id="inviteEmail" type="email" autocomplete="email" placeholder="member@example.com">
    </label>`)

  const childLabel = adaptiveInviteChild?.closest('label')
  childLabel?.classList.add('invite-child-field')
  adaptiveInviteGrade?.closest('label')?.classList.add('invite-child-field')
  adaptiveInviteGrade?.setAttribute('placeholder', 'Optional grade')

  roleLabel?.insertAdjacentHTML('afterend', `
    <div id="inviteRoleHelp" class="role-help"></div>
    <label id="inviteCanDriveRow" class="checkbox-row">
      <input id="inviteCanDrive" type="checkbox" checked>
      <span><strong>May be given rides to drive</strong><small>Turn this off for a family member or group manager who will not drive.</small></span>
    </label>
    <label>Invitation expires
      <select id="inviteExpiresDays">
        <option value="7">7 days</option>
        <option value="14" selected>14 days</option>
        <option value="30">30 days</option>
        <option value="90">90 days</option>
      </select>
    </label>`)

  if (roleLabel && adaptiveInviteForm.querySelector('.dialog-title')) {
    adaptiveInviteForm.querySelector('.dialog-title').insertAdjacentElement('afterend', roleLabel)
  }
  updateAdaptiveInvitationFields()
}

function updateAdaptiveInvitationFields() {
  const role = adaptiveInviteRole?.value || 'parent'
  const childRequired = role === 'parent'
  const childVisible = role !== 'viewer'
  const canDrive = el('inviteCanDrive')

  adaptiveInviteForm?.querySelectorAll('.invite-child-field')
    .forEach(field => field.classList.toggle('hidden', !childVisible))
  if (adaptiveInviteChild) {
    adaptiveInviteChild.required = childRequired
    if (!childVisible) adaptiveInviteChild.value = ''
  }
  if (adaptiveInviteGrade && !childVisible) adaptiveInviteGrade.value = ''

  if (canDrive) {
    canDrive.disabled = role === 'viewer'
    if (role === 'viewer') canDrive.checked = false
    if (role === 'parent' && !canDrive.dataset.touched) canDrive.checked = true
  }

  const help = el('inviteRoleHelp')
  if (help) {
    help.innerHTML = ({
      viewer: '<strong>View-only member</strong><span>Can see the schedule but cannot change it. Child and driving information are not required.</span>',
      admin: '<strong>Group manager</strong><span>Can manage invitations and schedules. Child and driving information are optional.</span>',
      parent: '<strong>Parent</strong><span>Participates in the carpool. Add the child or rider and choose whether this member can drive.</span>'
    })[role]
  }
}

installAdaptiveInvitationFields()
adaptiveInviteRole?.addEventListener('change', updateAdaptiveInvitationFields)
el('inviteCanDrive')?.addEventListener('change', event => { event.target.dataset.touched = 'true' })

adaptiveInviteForm?.addEventListener('submit', async event => {
  event.preventDefault()
  event.stopImmediatePropagation()
  if (!state.activeGroup) return

  await runAction(async () => {
    const role = adaptiveInviteRole.value
    const { data, error } = await supabase.rpc('kcp_create_invitation_v2', {
      p_group_id: state.activeGroup.id,
      p_member_name: el('inviteName').value.trim(),
      p_role: role,
      p_email: el('inviteEmail').value.trim() || null,
      p_phone: el('invitePhone').value.trim() || null,
      p_child_name: role === 'viewer' ? null : el('inviteChild').value.trim() || null,
      p_grade: role === 'viewer' || !el('inviteGrade').value ? null : Number(el('inviteGrade').value),
      p_can_drive: role !== 'viewer' && el('inviteCanDrive').checked,
      p_expires_in_days: Number(el('inviteExpiresDays').value)
    }).single()
    if (error) throw error

    el('inviteDialog').close()
    adaptiveInviteForm.reset()
    adaptiveInviteRole.value = 'parent'
    updateAdaptiveInvitationFields()
    await loadWorkspace()
    renderAll()
    await shareInvitation(data)
  }, 'Invitation created', { operation: 'create_invitation' })
}, { capture: true })

const adaptivePreviousInvitationRow = invitationRow
invitationRow = function (invitation) {
  const role = invitation.role || 'parent'
  const child = invitation.child_name
    ? `${escapeHTML(invitation.child_name)}${invitation.grade == null ? '' : ` · Grade ${invitation.grade}`}`
    : 'No child attached'
  const pending = invitation.status === 'pending'
  return `<div class="timeline-row adaptive-invitation-row">
    <div>
      <strong>${escapeHTML(invitation.invited_parent_name)}</strong>
      <span class="meta">${escapeHTML(capitalize(role))} · ${child} · expires ${formatDateTime(invitation.expires_at)}</span>
      <span class="meta">${invitation.can_drive && role !== 'viewer' ? 'May drive' : 'Will not be given rides'} · ${escapeHTML(capitalize(invitation.status))}</span>
    </div>
    ${pending ? `<div class="button-row">
      <button class="action-button" data-action="share-invite" data-invite-id="${invitation.id}" type="button">Share</button>
      <button class="action-button" data-action="resend-invite" data-invite-id="${invitation.id}" type="button">New code</button>
      <button class="action-button orange" data-action="revoke-invite" data-invite-id="${invitation.id}" type="button">Cancel invitation</button>
    </div>` : `<span class="status-pill ${invitation.status === 'accepted' ? 'complete' : 'warning'}">${escapeHTML(capitalize(invitation.status))}</span>`}
  </div>`
}

shareInvitation = async function (invitation) {
  if (!invitation) return
  const url = new URL(location.origin + location.pathname)
  url.searchParams.set('invite', invitation.token)
  const childText = invitation.child_name ? `\nChild or rider: ${invitation.child_name}` : ''
  const text = `Join ${state.activeGroup?.name || 'this Kidscarpool group'}\nRole: ${capitalize(invitation.role || 'member')}\nInvited name: ${invitation.invited_parent_name}${childText}\nOpen the secure invitation link:`

  if (invitation.email) {
    const { error } = await supabase.auth.signInWithOtp({
      email: invitation.email,
      options: { emailRedirectTo: url.toString(), shouldCreateUser: true }
    })
    if (!error) {
      toast(`Invitation emailed to ${invitation.email}`)
      return
    }
    toast('The invitation was created, but email delivery is unavailable or rate-limited. Share the private link instead.', true)
  }

  if (navigator.share) {
    await navigator.share({ title: 'Kidscarpool invitation', text, url: url.toString() })
  } else {
    await navigator.clipboard.writeText(`${text}\n${url}`)
    toast('Invitation link copied')
  }
}

document.addEventListener('click', async event => {
  const resend = event.target.closest('[data-action="resend-invite"]')
  if (resend) {
    event.preventDefault()
    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_resend_invitation', {
        p_invitation_id: resend.dataset.inviteId,
        p_expires_in_days: 14
      }).single()
      if (error) throw error
      await loadWorkspace()
      renderAll()
      await shareInvitation(data)
    }, 'A new invitation code was created', { operation: 'resend_invitation' })
    return
  }

  const revoke = event.target.closest('[data-action="revoke-invite"]')
  if (revoke) {
    event.preventDefault()
    if (!confirm('Cancel this invitation? Its current link and code will stop working.')) return
    await runAction(async () => {
      const { error } = await supabase.rpc('kcp_revoke_invitation', {
        p_invitation_id: revoke.dataset.inviteId
      })
      if (error) throw error
      await loadWorkspace()
      renderAll()
    }, 'Invitation revoked', { operation: 'revoke_invitation' })
  }
}, { capture: true })

if (!el('invitationAcceptDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="invitationAcceptDialog" class="modal invitation-accept-dialog">
      <form id="invitationAcceptForm" class="dialog-form">
        <div class="dialog-title">
          <div><span class="eyebrow">PRIVATE INVITATION</span><h2>Join carpool group</h2></div>
          <button id="invitationAcceptClose" class="close-button" type="button" aria-label="Close">×</button>
        </div>
        <div id="invitationAcceptPreview" class="invitation-preview">Checking invitation…</div>
        <input id="invitationAcceptToken" type="hidden">
        <label>Invited member name<input id="invitationAcceptName" required autocomplete="name"></label>
        <label>Phone <span class="optional">only when requested by the group</span><input id="invitationAcceptPhone" autocomplete="tel" inputmode="tel"></label>
        <div class="button-row">
          <button id="invitationDecline" class="secondary-button" type="button">Decline</button>
          <button id="invitationAcceptSubmit" class="primary-button" type="submit">Accept invitation</button>
        </div>
      </form>
    </dialog>`)
}

function closeInvitationAcceptDialog() {
  const dialog = el('invitationAcceptDialog')
  if (dialog?.open) dialog.close('cancel')
}

el('invitationAcceptClose')?.addEventListener('click', closeInvitationAcceptDialog)
el('invitationAcceptDialog')?.addEventListener('cancel', event => {
  event.preventDefault()
  closeInvitationAcceptDialog()
})
el('invitationAcceptDialog')?.addEventListener('click', event => {
  if (event.target === el('invitationAcceptDialog')) closeInvitationAcceptDialog()
})

async function openInvitationLink(token) {
  const normalized = String(token || '').trim().toUpperCase()
  if (!normalized) return
  el('invitationAcceptToken').value = normalized
  el('invitationAcceptPreview').innerHTML = 'Checking invitation…'
  el('invitationAcceptDialog').showModal()

  const { data, error } = await supabase.rpc('kcp_invitation_preview', { p_token: normalized })
  if (error || !data?.[0]) {
    el('invitationAcceptPreview').innerHTML = '<strong>Invitation unavailable</strong><span>Ask the group manager for a current link.</span>'
    el('invitationAcceptSubmit').disabled = true
    return
  }

  const preview = data[0]
  el('invitationAcceptName').value = preview.member_name || state.profile?.display_name || ''
  el('invitationAcceptSubmit').disabled = preview.status !== 'pending'
  el('invitationDecline').disabled = preview.status !== 'pending'
  el('invitationAcceptPreview').innerHTML = `
    <strong>${escapeHTML(preview.group_name)}</strong>
    <span>${escapeHTML(capitalize(preview.role))}${preview.child_name ? ` · ${escapeHTML(preview.child_name)}` : ''}</span>
    <span>${preview.can_drive ? 'You may be given rides to drive' : 'You will not be given rides to drive'}</span>
    ${preview.email_bound ? '<span class="status-pill info">Verified invited email required</span>' : ''}`
}

el('invitationAcceptForm')?.addEventListener('submit', async event => {
  event.preventDefault()
  const accepted = await runAction(async () => {
    const { data, error } = await supabase.rpc('kcp_accept_invitation', {
      p_token: el('invitationAcceptToken').value,
      p_parent_name: el('invitationAcceptName').value.trim(),
      p_phone: el('invitationAcceptPhone').value.trim() || null
    })
    if (error) throw error
    const group = data?.[0]
    if (!group?.group_id) throw new Error('The invitation was accepted but the group was not returned')

    localStorage.setItem(ACTIVE_GROUP_KEY, group.group_id)
    await rememberGroup(group.group_id)
    await loadProfile()
    await refreshAll()
    closeInvitationAcceptDialog()
    history.replaceState({}, '', location.pathname)
    navigate('home')
    return true
  }, 'Invitation accepted', { operation: 'accept_invitation' })
  return accepted
})

el('invitationDecline')?.addEventListener('click', async () => {
  if (!confirm('Decline this carpool invitation? The group owner will see your response.')) return
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_decline_invitation', {
      p_token: el('invitationAcceptToken').value
    })
    if (error) throw error
    closeInvitationAcceptDialog()
    history.replaceState({}, '', location.pathname)
  }, 'Invitation declined', { operation: 'decline_invitation' })
})

queueMicrotask(() => {
  const token = new URLSearchParams(location.search).get('invite')
  if (token) openInvitationLink(token)
})
