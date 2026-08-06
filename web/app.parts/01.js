        p_pickup_weekdays: [1, 2, 3, 4, 5],
        p_notes: ''
      })
      if (error) throw error
      const created = data?.[0]
      if (created?.group_id) localStorage.setItem(ACTIVE_GROUP_KEY, created.group_id)
      el('createGroupDialog').close()
      el('createGroupForm').reset()
      el('newSchoolName').value = 'BASIS Phoenix Primary'
      el('newAcademicYear').value = '2026-27'
      await refreshAll()
      navigate('groups')
    }, 'Private group created')
  })

  el('inviteForm').addEventListener('submit', async event => {
    event.preventDefault()
    if (!state.activeGroup) return
    await runAction(async () => {
      const { data, error } = await supabase.rpc('kcp_create_invitation', {
        p_group_id: state.activeGroup.id,
        p_parent_name: el('inviteName').value.trim(),
        p_phone: el('invitePhone').value.trim() || null,
        p_child_name: el('inviteChild').value.trim(),
        p_grade: Number(el('inviteGrade').value),
        p_role: el('inviteRole').value
      }).single()
      if (error) throw error
      el('inviteDialog').close()
      el('inviteForm').reset()
      await loadWorkspace()
      await shareInvitation(data)
    }, 'Invitation created')
  })

  document.addEventListener('click', handleDelegatedClick)
}

async function enterApp() {
  hide('onboardingView')
  show('bottomNav')
  showConnection('Connected securely to Supabase.', 'success')
  await refreshAll()
  navigate(state.currentView)
}

async function loadProfile() {
  const userId = state.session?.user?.id
  if (!userId) return
  const { data, error } = await supabase
    .from('kcp_profiles')
    .select('*')
    .eq('id', userId)
    .maybeSingle()
  if (error) throw error
  state.profile = data
}

async function refreshAll() {
  await loadGroups()
  if (state.activeGroup) await loadWorkspace()
  renderAll()
}

async function loadGroups() {
  const { data, error } = await supabase.rpc('kcp_list_my_groups')
  if (error) throw error
  state.groups = data || []

  const savedId = localStorage.getItem(ACTIVE_GROUP_KEY)
  const selected = state.groups.find(group => group.group_id === savedId) || state.groups[0] || null
  if (selected) {
    localStorage.setItem(ACTIVE_GROUP_KEY, selected.group_id)
    state.activeGroup = await fetchGroup(selected.group_id)
  } else {
    localStorage.removeItem(ACTIVE_GROUP_KEY)
    state.activeGroup = null
    clearWorkspace()
  }
}

async function fetchGroup(groupId) {
  const { data, error } = await supabase.from('kcp_groups').select('*').eq('id', groupId).single()
  if (error) throw error
  return data
}

async function loadWorkspace() {
  if (!state.activeGroup) return
  const groupId = state.activeGroup.id

  const [members, invitations, constraints, requests, calendars, versions, trips, covers, points, audits] = await Promise.all([
    selectRows('kcp_memberships', query => query.eq('group_id', groupId).order('parent_name')),
    selectRows('kcp_invitations', query => query.eq('group_id', groupId).order('created_at', { ascending: false })),
    selectRows('kcp_constraints', query => query.eq('group_id', groupId)),
    selectRows('kcp_constraint_requests', query => query.eq('group_id', groupId).order('submitted_at', { ascending: false })),
    selectRows('kcp_school_calendars', query => query.eq('group_id', groupId).order('uploaded_at', { ascending: false })),
    selectRows('kcp_schedule_versions', query => query.eq('group_id', groupId).order('version', { ascending: false })),
    selectRows('kcp_trips', query => query.eq('group_id', groupId).eq('schedule_version', state.activeGroup.current_schedule_version).order('trip_date').order('kind')),
    selectRows('kcp_cover_requests', query => query.eq('group_id', groupId).order('created_at', { ascending: false })),
    selectRows('kcp_points_ledger', query => query.eq('group_id', groupId).order('created_at', { ascending: false })),
    selectRows('kcp_audit_events', query => query.eq('group_id', groupId).order('occurred_at', { ascending: false }).limit(100))
  ])

  state.memberships = members
  state.invitations = invitations
  state.constraints = constraints
  state.constraintRequests = requests
  state.calendar = calendars[0] || null
  state.scheduleVersions = versions
  state.trips = trips
  state.coverRequests = covers
  state.points = points
  state.auditEvents = audits

  if (state.calendar) {
    state.calendarEvents = await selectRows('kcp_calendar_events', query => query.eq('calendar_id', state.calendar.id).order('start_date').order('event_type'))
    const { data, error } = await supabase.rpc('kcp_calendar_analytics', { p_group_id: groupId })
    if (error) throw error
    state.analytics = data?.[0] || null
  } else {
    state.calendarEvents = []
    state.analytics = null
  }

  const own = state.constraints.find(item => item.user_id === state.session.user.id)
  state.constraintDraft = {
    drop: [...(own?.drop_weekdays || [1, 2, 3, 4, 5])],
    pickup: [...(own?.pickup_weekdays || [1, 2, 3, 4, 5])],
    notes: own?.notes || ''
  }
}

async function selectRows(table, configure) {
  let query = supabase.from(table).select('*')
  query = configure(query)
  const { data, error } = await query
  if (error) throw error
  return data || []
}

function clearWorkspace() {
  state.memberships = []
  state.invitations = []
  state.constraints = []
  state.constraintRequests = []
  state.calendar = null
  state.calendarEvents = []
  state.analytics = null
  state.scheduleVersions = []
  state.trips = []
  state.coverRequests = []
  state.points = []
  state.auditEvents = []
}

function renderAll() {
  el('welcomeName').textContent = state.profile?.display_name || 'Parent'
  const hasGroup = Boolean(state.activeGroup)
  el('activeGroupBar').classList.toggle('hidden', !hasGroup)
  el('activeGroupName').textContent = state.activeGroup?.name || '—'
  el('noGroupHome').classList.toggle('hidden', hasGroup)
  el('nextTripsGrid').classList.toggle('hidden', !hasGroup)

  renderHome()
  renderGroups()
  renderSchedule()
  renderVolunteers()
  renderLeaderboard()
  renderCalendar()
  renderSettings()
}

function navigate(view) {
  state.currentView = view
  localStorage.setItem(VIEW_KEY, view)
  qsa('.view[data-view]').forEach(section => section.classList.toggle('hidden', section.dataset.view !== view))
  qsa('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.nav === view))
  window.scrollTo({ top: 0, behavior: 'smooth' })
}
