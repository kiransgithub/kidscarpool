const ACTIVE_STATUSES = new Set([
  'scheduled',
  'coverage_needed',
  'cover_requested',
  'cover_accepted',
  'in_progress'
])

export function tripMoment(trip) {
  if (trip?.scheduled_time) {
    const parsed = new Date(trip.scheduled_time)
    if (!Number.isNaN(parsed.getTime())) return parsed
  }

  const date = String(trip?.trip_date || '').slice(0, 10)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return new Date(8640000000000000)

  const fallback = trip?.kind === 'morning_drop' ? '07:00:00' : '15:35:00'
  return new Date(`${date}T${fallback}`)
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
    return ACTIVE_STATUSES.has(trip.status) && (trip.status === 'in_progress' || moment >= nowMs)
  })
}

export function tripStartGate(trip, now = new Date(), leadMinutes = 10, lateMinutes = 90) {
  if (!trip || !['scheduled', 'cover_accepted'].includes(trip.status)) {
    return { allowed: false, reason: 'Trip is not ready to start.' }
  }
  if (!trip.scheduled_time) {
    return { allowed: false, reason: 'Confirm the trip time before starting.' }
  }

  const scheduled = tripMoment(trip)
  const diffMs = scheduled.getTime() - now.getTime()
  const earliestMs = leadMinutes * 60 * 1000
  const latestMs = -lateMinutes * 60 * 1000

  if (diffMs > earliestMs) {
    const minutes = Math.max(1, Math.ceil((diffMs - earliestMs) / 60000))
    return {
      allowed: false,
      reason: `Start opens in ${minutes} minute${minutes === 1 ? '' : 's'} (10 minutes before the trip).`
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

function tripBucket(trip, momentMs, nowMs) {
  if (trip?.status === 'in_progress') return 0
  if (momentMs >= nowMs && !['completed', 'cancelled'].includes(trip?.status)) return 1
  if (!['completed', 'cancelled'].includes(trip?.status)) return 2
  return 3
}

function kindOrder(kind) {
  return kind === 'morning_drop' ? 0 : 1
}
