// Final database-state synchronization for role-aware rendering and neutral
// schedule creation.

state.currentParticipant = null
state.children = []

const kcpDatabaseStatePreviousLoadWorkspace = loadWorkspace
loadWorkspace = async function () {
  await kcpDatabaseStatePreviousLoadWorkspace()

  const groupId = state.activeGroup?.id
  const userId = state.session?.user?.id
  if (!groupId || !userId) {
    state.currentParticipant = null
    state.children = []
    return
  }

  try {
    const [participants, children] = await Promise.all([
      selectRows(
        'kcp_group_participants',
        query => query.eq('group_id', groupId).eq('user_id', userId).eq('status', 'active').limit(1)
      ),
      selectRows(
        'kcp_children',
        query => query.eq('group_id', groupId).eq('status', 'active').order('name')
      )
    ])
    state.currentParticipant = participants[0] || null
    state.children = children
  } catch (error) {
    console.warn('KCP participant/child lookup:', error.message || error)
    state.currentParticipant = null
    state.children = []
  }
}

const kcpDatabaseStatePreviousClearWorkspace = clearWorkspace
clearWorkspace = function () {
  kcpDatabaseStatePreviousClearWorkspace()
  state.currentParticipant = null
  state.children = []
}

const kcpDatabaseStatePreviousCurrentParticipant = kcpCurrentParticipant
kcpCurrentParticipant = function () {
  return state.currentParticipant || kcpDatabaseStatePreviousCurrentParticipant()
}

// Add private pickup tags from the child records returned under group RLS. No
// child name or tag is embedded in the client.
const kcpDatabaseStatePreviousShowTrip = showTrip
showTrip = function (tripId) {
  kcpDatabaseStatePreviousShowTrip(tripId)
  const content = el('tripDialogContent')
  content?.querySelectorAll('.trip-child-row').forEach(row => {
    const name = row.querySelector('strong')?.textContent?.trim()
    const child = state.children.find(item => item.name === name)
    if (!child?.pickup_tag || row.querySelector('[data-db-pickup-tag]')) return
    row.insertAdjacentHTML(
      'beforeend',
      `<span class="badge" data-db-pickup-tag>Tag ${escapeHTML(child.pickup_tag)}</span>`
    )
  })
}

// The create-group dialog always defaults to the current device timezone. It
// must not inherit the active group's location when creating an unrelated group.
if (genericGroupDialog) {
  const timezoneObserver = new MutationObserver(() => {
    if (!genericGroupDialog.open) return
    const select = el('genericTimezone')
    if (!select) return
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
    if (![...select.options].some(option => option.value === timezone)) {
      select.add(new Option(timezone, timezone))
    }
    select.value = timezone
  })
  timezoneObserver.observe(genericGroupDialog, { attributes: true, attributeFilter: ['open'] })
}

// Advanced "add another ride" uses a prior user/DB time when available and
// otherwise starts blank. No school-style time is invented by the client.
scheduleBuilderDialog?.addEventListener('click', event => {
  const button = event.target.closest('[data-action="add-schedule-session"]')
  if (!button) return

  event.preventDefault()
  event.stopImmediatePropagation()
  const previous = scheduleDraftSessions.at(-1)
  const weekday = previous ? ((Number(previous.weekday) % 7) + 1) : 1
  scheduleDraftSessions.push(createSessionDraft({
    name: `${weekdayLabel(weekday, true)} ride`,
    weekday,
    outboundTime: previous?.outboundTime ?? '',
    returnTime: previous?.returnTime ?? '',
    anchorDate: el('scheduleStartsOn')?.value || '',
    displayOrder: scheduleDraftSessions.length + 1
  }))
  markSchedulePreviewStale()
  renderScheduleSessionCards()
}, { capture: true })
