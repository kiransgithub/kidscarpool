// User-safe connectivity and error handling.
// The family app never names infrastructure vendors, tables, constraints, RPCs
// or SQLSTATE values. Technical details are stored behind a support reference.

const KCP_CLIENT_VERSION = 'pwa-v12'
state.lastSupportReference = null

const kcpTechnicalConnection = showConnection
const kcpTechnicalToast = toast

showConnection = function (message = '', type = '') {
  const banner = el('connectionBanner')
  if (!banner) return

  let publicMessage = 'Online'
  let publicType = type
  const text = String(message || '')

  if (!navigator.onLine || /offline|network request failed|failed to fetch/i.test(text)) {
    publicMessage = 'Offline — changes will sync when connection returns'
    publicType = 'error'
  } else if (/working|connecting|loading|refreshing|recovering|checking|sending|sync/i.test(text)) {
    publicMessage = 'Syncing…'
    publicType = ''
  } else if (type === 'error') {
    publicMessage = isSafeUserMessage(text) ? text : 'Unable to sync. Try again.'
  } else if (type === 'success' || /connected|online|saved|published|accepted|completed/i.test(text)) {
    publicMessage = 'Online · synced just now'
    publicType = 'success'
  } else if (text) {
    publicMessage = sanitizeUserMessage(text)
  }

  banner.textContent = publicMessage
  banner.className = `connection-banner ${publicType}`
  banner.classList.remove('hidden')
}

toast = function (message, isError = false) {
  const publicMessage = isError ? sanitizeUserMessage(message) : message
  kcpTechnicalToast(publicMessage, isError)
}

runAction = async function (action, successMessage = '', options = {}) {
  if (state.loading) return null
  state.loading = true
  showConnection('Syncing…')

  try {
    const result = await action()
    if (successMessage) toast(successMessage)
    showConnection('Online', 'success')
    return result
  } catch (error) {
    const operation = options.operation || operationFromSuccessMessage(successMessage)
    const response = await presentKcpError(error, operation)
    showConnection(response.message, 'error')
    toast(response.message, true)
    return null
  } finally {
    state.loading = false
  }
}

async function presentKcpError(error, operation = 'app_action') {
  const classification = classifyKcpError(error)
  if (classification.safe) return { message: classification.message, reference: null }

  const reference = await reportKcpError(error, operation, classification.code)
  state.lastSupportReference = reference
  const suffix = reference ? ` Reference: ${reference}` : ''
  return {
    message: `We could not complete the request. Your data was not changed. Try again or contact the group owner.${suffix}`,
    reference
  }
}

async function reportKcpError(error, operation, messageCode = 'UNEXPECTED') {
  try {
    if (!state.session?.user?.id) return null
    const { data, error: reportError } = await supabase.rpc('kcp_report_client_error', {
      p_operation: String(operation || 'app_action').slice(0, 120),
      p_client_version: KCP_CLIENT_VERSION,
      p_group_id: state.activeGroup?.id || null,
      p_message_code: messageCode,
      p_safe_metadata: {
        view: state.currentView || 'unknown',
        role: typeof kcpAccess === 'function' ? kcpAccess().role : currentMembership()?.role || 'unknown',
        online: navigator.onLine
      },
      p_technical_message: String(error?.message || error || 'Unknown error').slice(0, 2000)
    })
    if (reportError) return null
    return data || null
  } catch {
    return null
  }
}

function classifyKcpError(error) {
  const raw = String(error?.message || error || '').trim()
  const rules = [
    [/offline|network request failed|failed to fetch/i, 'OFFLINE', 'You appear to be offline. Reconnect and try again.'],
    [/owner or admin role required|permission required|not authorized|active group membership required/i, 'PERMISSION', 'You do not have permission to perform this action.'],
    [/invitation.*not found|invitation code was not found/i, 'INVITE_NOT_FOUND', 'That invitation code was not found. Ask the group owner for a current invitation.'],
    [/invitation.*expired|this invitation has expired/i, 'INVITE_EXPIRED', 'That invitation has expired. Ask the group owner for a new invitation.'],
    [/invitation.*no longer|already accepted/i, 'INVITE_USED', 'That invitation is no longer available. Sign in with the account that accepted it or ask the group owner for help.'],
    [/recovery code.*invalid|expired|already used/i, 'RECOVERY_INVALID', 'That one-time access code is invalid, expired, or already used. Ask the group owner for a new code.'],
    [/cover request.*no longer open|this cover request is no longer open/i, 'COVER_CLOSED', 'That cover request has already changed. Refresh the group and review the current driver.'],
    [/too early|10 minutes before|start window/i, 'TRIP_EARLY', 'This ride can be started beginning 10 minutes before its scheduled time.'],
    [/enter |select |choose |required|must contain|must be between|add at least/i, 'VALIDATION', raw]
  ]

  for (const [pattern, code, message] of rules) {
    if (pattern.test(raw)) return { safe: true, code, message }
  }

  return { safe: false, code: technicalCode(raw), message: '' }
}

function technicalCode(raw) {
  if (/duplicate key|unique constraint/i.test(raw)) return 'DATA_CONFLICT'
  if (/violates.*constraint|sqlstate|postgres/i.test(raw)) return 'DATABASE_RULE'
  if (/schema cache|could not find the function|rpc/i.test(raw)) return 'API_SCHEMA'
  if (/jwt|token|session/i.test(raw)) return 'SESSION'
  return 'UNEXPECTED'
}

function sanitizeUserMessage(message) {
  const raw = String(message || '').trim()
  if (isSafeUserMessage(raw)) return raw
  if (/offline|failed to fetch|network request failed/i.test(raw)) {
    return 'You appear to be offline. Reconnect and try again.'
  }
  return 'Unable to complete the request. Try again.'
}

function isSafeUserMessage(message) {
  if (!message) return false
  if (/supabase|postgres|sqlstate|constraint|schema cache|rpc|jwt|auth\.users|kcp_[a-z_]+/i.test(message)) return false
  return message.length <= 240
}

function operationFromSuccessMessage(value = '') {
  return String(value || 'app_action')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_|_$/g, '')
    .slice(0, 120) || 'app_action'
}

window.addEventListener('online', () => showConnection('Online', 'success'))
window.addEventListener('offline', () => showConnection('Offline', 'error'))

window.addEventListener('unhandledrejection', event => {
  const error = event.reason instanceof Error ? event.reason : new Error(String(event.reason || 'Unhandled request failure'))
  reportKcpError(error, 'unhandled_promise', 'UNHANDLED_PROMISE')
})

window.addEventListener('error', event => {
  if (!event.error) return
  reportKcpError(event.error, 'unhandled_window_error', 'UNHANDLED_WINDOW_ERROR')
})
