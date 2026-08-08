// Platform support role is separate from group Owner/Admin membership.
state.platformRole = null

async function loadPlatformRole() {
  if (!state.session?.user?.id) {
    state.platformRole = null
    return
  }

  const { data, error } = await supabase.rpc('kcp_platform_role')
  if (error) {
    if (!/Could not find the function|schema cache/i.test(error.message || '')) {
      console.warn('KCP platform-role lookup:', error.message || error)
    }
    state.platformRole = null
    return
  }
  state.platformRole = data?.[0] || null
}

const kcpPlatformPreviousLoadProfile = loadProfile
loadProfile = async function () {
  await kcpPlatformPreviousLoadProfile()
  await loadPlatformRole()
}

const kcpPlatformPreviousRenderSettings = renderSettings
renderSettings = function () {
  kcpPlatformPreviousRenderSettings()
  if (!state.platformRole || el('platformSupportCard')) return

  const role = String(state.platformRole.role || 'support').replaceAll('_', ' ')
  el('settingsView')?.insertAdjacentHTML('beforeend', `
    <div id="platformSupportCard" class="card">
      <span class="eyebrow">PLATFORM SUPPORT</span>
      <h2>Super Admin console</h2>
      <p class="meta">Platform role: ${escapeHTML(role)}. Review groups, support cases and client error references without exposing diagnostics to normal members.</p>
      <a class="primary-button support-console-link" href="./support/">Open support console</a>
    </div>`)
}
