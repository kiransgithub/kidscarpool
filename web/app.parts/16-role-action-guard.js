// Role-aware client guard. Supabase RLS/RPC checks remain authoritative, but
// stale cached controls must not offer actions that the current DB role cannot
// perform.

const KCP_DRIVING_ACTIONS = new Set([
  'request-cover',
  'accept-cover',
  'withdraw-cover',
  'start-trip',
  'complete-trip',
  'toggle-weekday',
  'submit-constraints'
])

const KCP_ADMIN_ACTIONS = new Set([
  'open-invite',
  'open-generic-schedule-builder',
  'generate-schedule',
  'upload-calendar',
  'review-constraint'
])

document.addEventListener('click', event => {
  const control = event.target.closest('[data-action]')
  if (!control) return

  const action = control.dataset.action
  const access = kcpAccess()
  if (KCP_DRIVING_ACTIONS.has(action) && !access.canDrive) {
    event.preventDefault()
    event.stopImmediatePropagation()
    toast('This membership is read-only and cannot perform driving actions.', true)
    return
  }
  if (KCP_ADMIN_ACTIONS.has(action) && !access.isAdmin) {
    event.preventDefault()
    event.stopImmediatePropagation()
    toast('Owner or Admin role required.', true)
  }
}, { capture: true })

const kcpRoleGuardPreviousShowTrip = showTrip
showTrip = function (tripId) {
  kcpRoleGuardPreviousShowTrip(tripId)
  if (kcpAccess().canDrive) return

  const content = el('tripDialogContent')
  content?.querySelectorAll([
    '[data-action="request-cover"]',
    '[data-action="accept-cover"]',
    '[data-action="withdraw-cover"]',
    '[data-action="start-trip"]',
    '[data-action="complete-trip"]'
  ].join(','))
    .forEach(control => control.remove())
}

document.addEventListener('change', event => {
  const roleControl = event.target.closest('[data-action="change-role"]')
  if (!roleControl || kcpAccess().isAdmin) return
  event.preventDefault()
  event.stopImmediatePropagation()
  toast('Owner or Admin role required.', true)
}, { capture: true })
