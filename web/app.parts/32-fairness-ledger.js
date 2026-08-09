// Workload fairness is operational and transparent. Points remain optional
// group gamification and never influence assignment eligibility or safety.

state.fairnessRows = []
state.myFairnessSummary = []

const kcpFairnessPreviousLoadWorkspace = loadWorkspace
loadWorkspace = async function () {
  await kcpFairnessPreviousLoadWorkspace()
  if (!state.activeGroup) {
    state.fairnessRows = []
    return
  }
  const { data, error } = await supabase.rpc('kcp_group_fairness', {
    p_group_id: state.activeGroup.id
  })
  if (error && !/Could not find the function|schema cache/i.test(error.message || '')) throw error
  state.fairnessRows = data || []
}

const kcpFairnessPreviousLoadAllGroupFeeds = loadAllGroupFeeds
loadAllGroupFeeds = async function () {
  await kcpFairnessPreviousLoadAllGroupFeeds()
  if (!state.session?.user?.id) {
    state.myFairnessSummary = []
    return
  }
  const { data, error } = await supabase.rpc('kcp_my_fairness_summary')
  if (error && !/Could find the function|schema cache/i.test(error.message || '')) throw error
  state.myFairnessSummary = data || []
}

renderLeaderboard = function () {
  const list = el('leaderboardList')
  if (!list) return
  const heading = el('leaderboardView')?.querySelector('.section-heading h1')
  if (heading) heading.textContent = 'Driving summary'

  if (!state.activeGroup) {
    list.innerHTML = empty('Choose a group to review participation.')
    return
  }
  if (kcpAccess().isViewer) {
    list.innerHTML = empty('The driving summary is available to drivers and group managers.')
    return
  }

  const rows = state.fairnessRows || []
  if (!rows.length) {
    list.innerHTML = empty('Completed rides will appear in the driving history.')
    return
  }

  const maxUnits = Math.max(...rows.map(row => Number(row.fairness_units || 0)), 1)
  list.innerHTML = `
    <section class="card fairness-explainer">
      <span class="eyebrow">HOW DRIVING IS SHARED</span>
      <h2>How contributions are counted</h2>
      <p>Each completed ride counts. Longer rides and rides with more children count a little more. Recognition points are separate and never decide who is allowed to drive.</p>
    </section>
    <section class="fairness-list">
      ${rows.map((row, index) => fairnessRow(row, index, maxUnits)).join('')}
    </section>`
}

function fairnessRow(row, index, maxUnits) {
  const isCurrent = row.user_id === state.session?.user?.id
  const width = Math.max(3, Math.round(Number(row.fairness_units || 0) / maxUnits * 100))
  const balance = Number(row.balance_delta || 0)
  const balanceText = Math.abs(balance) < 0.15
    ? 'About the same as the group'
    : balance > 0
      ? 'More driving than the group average'
      : 'Less driving than the group average'

  return `<article class="fairness-row ${isCurrent ? 'current-user' : ''}">
    <div class="fairness-rank">${index + 1}</div>
    <div class="fairness-main">
      <div class="fairness-name"><strong>${escapeHTML(row.parent_name)}</strong>${isCurrent ? '<span class="badge">You</span>' : ''}<span class="role-pill">${escapeHTML(capitalize(row.membership_role))}</span></div>
      <div class="fairness-bar"><span style="width:${width}%"></span></div>
      <div class="fairness-metrics">
        <span><strong>${row.completed_rides}</strong> completed</span>
        <span><strong>${row.volunteer_rides}</strong> volunteer</span>
        <span><strong>${row.upcoming_assigned}</strong> upcoming</span>
        <span><strong>${formatFairnessMinutes(row.estimated_minutes)}</strong> estimated</span>
        <span><strong>${row.children_transported}</strong> children carried</span>
      </div>
      <p class="fairness-balance">${escapeHTML(balanceText)} · ${Number(row.participation_share || 0).toFixed(1)}% of the group's completed driving</p>
    </div>
    <div class="fairness-score"><strong>${Number(row.fairness_units || 0).toFixed(2)}</strong><small>contribution</small>${row.points_visible ? `<span>${row.points} pts</span>` : ''}</div>
  </article>`
}

function formatFairnessMinutes(minutes) {
  const value = Number(minutes || 0)
  if (value < 60) return `${value}m`
  const hours = Math.floor(value / 60)
  const rest = value % 60
  return rest ? `${hours}h ${rest}m` : `${hours}h`
}

const kcpFairnessPreviousRenderHome = renderHome
renderHome = function () {
  kcpFairnessPreviousRenderHome()
  renderPersonalParticipationSummary()
}

function renderPersonalParticipationSummary() {
  el('personalParticipationSummary')?.remove()
  if (!state.myFairnessSummary?.length || kcpRolePortfolio().viewerOnly) return
  const completed = state.myFairnessSummary.reduce((sum, row) => sum + Number(row.completed_rides || 0), 0)
  const volunteer = state.myFairnessSummary.reduce((sum, row) => sum + Number(row.volunteer_rides || 0), 0)
  const upcoming = state.myFairnessSummary.reduce((sum, row) => sum + Number(row.upcoming_assigned || 0), 0)
  const minutes = state.myFairnessSummary.reduce((sum, row) => sum + Number(row.estimated_minutes || 0), 0)

  el('homeAlerts')?.insertAdjacentHTML('afterend', `
    <section id="personalParticipationSummary" class="card personal-participation-summary">
      <div class="group-card-head"><div><span class="eyebrow">YOUR PARTICIPATION</span><h2>Across all groups</h2></div><button class="link-button" data-nav="leaderboard" type="button">Details</button></div>
      <div class="metric-row"><div class="metric"><strong>${completed}</strong><small>Completed</small></div><div class="metric"><strong>${volunteer}</strong><small>Volunteer</small></div><div class="metric"><strong>${upcoming}</strong><small>Upcoming</small></div><div class="metric"><strong>${formatFairnessMinutes(minutes)}</strong><small>Estimated time</small></div></div>
    </section>`)
}

const kcpFairnessPreviousRenderGroupAdminPanel = renderGroupAdminPanel
renderGroupAdminPanel = function () {
  kcpFairnessPreviousRenderGroupAdminPanel()
  if (!state.activeGroup || !isAdmin()) return
  const panel = el('groupAdminPanel')
  if (panel?.querySelector('[data-participation-settings]')) return

  panel?.insertAdjacentHTML('beforeend', `
    <section class="card" data-participation-settings>
      <span class="eyebrow">PARTICIPATION</span>
      <h2>Driving contributions</h2>
      <p class="meta">KCP keeps a private driving history. Recognition points and group comparisons are optional.</p>
      <label class="checkbox-row"><input id="groupPointsEnabled" type="checkbox" ${state.activeGroup.points_enabled !== false ? 'checked' : ''}><span><strong>Give recognition points for completed rides</strong><small>10 scheduled · 20 volunteer</small></span></label>
      <label class="checkbox-row"><input id="groupPublicLeaderboard" type="checkbox" ${state.activeGroup.public_leaderboard_enabled !== false ? 'checked' : ''}><span><strong>Let drivers see the group driving summary</strong><small>When off, each driver sees only their own summary; group managers can still see the full history.</small></span></label>
      <details class="fairness-advanced"><summary>Advanced: how driving is counted</summary><div class="two-column-form"><label>Extra credit for longer rides<input id="groupFairnessTimeWeight" type="number" min="0" max="10" step="0.05" value="${Number(state.activeGroup.fairness_time_weight ?? 0.25)}"></label><label>Extra credit for carrying more children<input id="groupFairnessChildWeight" type="number" min="0" max="10" step="0.01" value="${Number(state.activeGroup.fairness_child_weight ?? 0.05)}"></label></div><p class="meta">Every completed ride starts equally. These settings add a small amount for time and number of children. They do not change recognition points or who may drive.</p></details>
      <button class="primary-small" data-action="save-participation-settings" type="button">Save driving-summary settings</button>
    </section>`)
}

document.addEventListener('click', async event => {
  const save = event.target.closest('[data-action="save-participation-settings"]')
  if (!save) return
  event.preventDefault()
  await runAction(async () => {
    const { error } = await supabase.rpc('kcp_set_participation_settings', {
      p_group_id: state.activeGroup.id,
      p_points_enabled: el('groupPointsEnabled').checked,
      p_public_leaderboard_enabled: el('groupPublicLeaderboard').checked,
      p_fairness_time_weight: Number(el('groupFairnessTimeWeight').value),
      p_fairness_child_weight: Number(el('groupFairnessChildWeight').value)
    })
    if (error) throw error
    state.activeGroup.points_enabled = el('groupPointsEnabled').checked
    state.activeGroup.public_leaderboard_enabled = el('groupPublicLeaderboard').checked
    state.activeGroup.fairness_time_weight = Number(el('groupFairnessTimeWeight').value)
    state.activeGroup.fairness_child_weight = Number(el('groupFairnessChildWeight').value)
    await loadWorkspace()
    renderAll()
  }, 'Participation settings saved', { operation: 'save_participation_settings' })
}, { capture: true })
