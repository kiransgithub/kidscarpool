const ACTIVE_STATUSES = new Set([
  'scheduled',
  'coverage_needed',
  'cover_requested',
  'cover_accepted',
  'confirmation_due',
  'ready',
  'in_progress',
  'completion_due',
  'unconfirmed'
])

export function tripMoment(trip) {
  if (trip?.scheduled_time) {
    const parsed = new Date(trip.scheduled_time)
    if (!Number.isNaN(parsed.getTime())) return parsed
  }

  const date = String(trip?.trip_date || '').slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return new Date(8640000000000000)
  return new Date(`${date}T12:00:00`)
}

export function orderTripsByProximity(trips, now = new Date()) {
  const nowMs = now.getTime()

  return [...(trips || [])].sort((left, right) => {
    const leftMoment = tripMoment(left).getTime()
    const rightMoment = tripMoment(right).getTime()
    const leftBucket = tripBucket(left, leftMoment, nowMs)
    const rightBucket = tripBucket(right, rightMoment, nowMs)

    if (leftBucket !== rightBucket) return leftBucket - rightBucket

    if (leftBucket === 0 || leftBucket === 1) {
      return leftMoment - rightMoment || kindOrder(left.kind) - kindOrder(right.kind)
    }

    return rightMoment - leftMoment || kindOrder(left.kind) - kindOrder(right.kind)
  })
}

export function upcomingActionableTrips(trips, now = new Date()) {
  const nowMs = now.getTime()
  return orderTripsByProximity(trips, now).filter(trip => {
    const moment = tripMoment(trip).getTime()
    return ACTIVE_STATUSES.has(trip.status)
      && (['in_progress', 'completion_due', 'unconfirmed'].includes(trip.status) || moment >= nowMs)
  })
}

export function tripStartGate(trip, now = new Date(), leadMinutes = 10, lateMinutes = 90) {
  if (!trip || trip.status !== 'ready') {
    return { allowed: false, reason: 'Confirm the ride before starting it.' }
  }
  if (!trip.scheduled_time) {
    return { allowed: false, reason: 'Confirm the ride time before starting.' }
  }

  const scheduled = tripMoment(trip)
  const diffMs = scheduled.getTime() - now.getTime()
  const earliestMs = leadMinutes * 60 * 1000
  const latestMs = -lateMinutes * 60 * 1000

  if (diffMs > earliestMs) {
    const minutes = Math.max(1, Math.ceil((diffMs - earliestMs) / 60000))
    return {
      allowed: false,
      reason: `Start opens in ${minutes} minute${minutes === 1 ? '' : 's'} (10 minutes before the ride).`
    }
  }
  if (diffMs < latestMs) {
    return { allowed: false, reason: 'The manual start window has closed.' }
  }
  return { allowed: true, reason: 'Ready to start.' }
}

export function acceptedCoverForTrip(coverRequests, tripId) {
  return (coverRequests || []).find(request => request.trip_id === tripId && request.status === 'accepted') || null
}

export function coverAcceptedLabel(request, memberships) {
  if (!request?.accepted_by) return ''
  const member = (memberships || []).find(item => item.user_id === request.accepted_by)
  return member?.parent_name ? `Accepted by ${member.parent_name}` : 'Accepted by another approved driver'
}

export function normalizeRecoveryCode(value) {
  return String(value || '').trim().toUpperCase()
}

export function recoveryErrorMessage(error) {
  const raw = typeof error === 'string'
    ? error
    : String(error?.message || error || '').trim()

  if (/invalid, expired, or already used/i.test(raw)) {
    return 'This recovery code is invalid, expired, or already used. Ask the platform administrator for a new one-time code.'
  }
  if (/current account already has an active membership/i.test(raw)) {
    return 'This device already has active access to the group. Close this window and refresh Groups.'
  }
  if (/current parent profile does not match/i.test(raw)) {
    return 'The member name does not match the roster entry. Use the exact invited or roster name.'
  }
  if (/authentication required|complete the parent profile/i.test(raw)) {
    return 'The account session is not ready. Reload the app once, then retry recovery.'
  }
  if (/failed to fetch|network|load failed/i.test(raw)) {
    return 'KCP could not reach the service. Check the connection and retry; the recovery code is not consumed unless the server accepts it.'
  }
  return raw || 'Group recovery did not complete. Retry with a new one-time code.'
}

export function resolveRecoveryAttempt({ rpcData = null, rpcError = null, status = null } = {}) {
  const recovered = Array.isArray(rpcData) ? rpcData[0] : rpcData

  if (recovered?.group_id) {
    return {
      ok: true,
      groupId: recovered.group_id,
      groupCode: recovered.group_code || status?.group_code || '',
      alreadyRecovered: false
    }
  }

  if (status?.claim_state === 'current_user' && status?.group_id) {
    return {
      ok: true,
      groupId: status.group_id,
      groupCode: status.group_code || '',
      alreadyRecovered: true
    }
  }

  return {
    ok: false,
    groupId: null,
    groupCode: '',
    alreadyRecovered: false,
    message: recoveryErrorMessage(rpcError || 'Recovery did not return a group.')
  }
}

function tripBucket(trip, momentMs, nowMs) {
  if (['in_progress', 'completion_due'].includes(trip?.status)) return 0
  if (momentMs >= nowMs && !['completed', 'cancelled'].includes(trip?.status)) return 1
  if (!['completed', 'cancelled'].includes(trip?.status)) return 2
  return 3
}

function kindOrder(kind) {
  return kind === 'morning_drop' ? 0 : 1
}
