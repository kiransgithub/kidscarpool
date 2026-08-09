// Privacy-safe client heartbeat. It records build/platform and the currently
// selected group for issue triage; it does not record prompts, addresses or
// child information.

const KCP_CLIENT_BUILD = 'community-pilot-2026.08'
const KCP_CLIENT_INSTANCE_KEY = 'kcp.clientInstanceId'
const KCP_HEARTBEAT_KEY = 'kcp.lastHeartbeatAt'
const KCP_HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000

function kcpClientInstanceId() {
  let value = localStorage.getItem(KCP_CLIENT_INSTANCE_KEY)
  if (!value) {
    value = globalThis.crypto?.randomUUID?.() || `client-${Date.now()}-${Math.random().toString(16).slice(2)}`
    localStorage.setItem(KCP_CLIENT_INSTANCE_KEY, value)
  }
  return value
}

async function registerClientHeartbeat(force = false) {
  if (!state.session?.user?.id) return
  const last = Number(localStorage.getItem(KCP_HEARTBEAT_KEY) || 0)
  if (!force && Date.now() - last < KCP_HEARTBEAT_INTERVAL_MS) return

  const platform = navigator.standalone
    ? 'iOS Home Screen PWA'
    : `${navigator.platform || 'Web'} browser`
  const { error } = await supabase.rpc('kcp_register_client_heartbeat', {
    p_client_instance_id: kcpClientInstanceId(),
    p_build_version: KCP_CLIENT_BUILD,
    p_cache_version: null,
    p_platform: platform,
    p_user_agent: navigator.userAgent,
    p_active_group_id: state.activeGroup?.id || null
  })
  if (!error) localStorage.setItem(KCP_HEARTBEAT_KEY, String(Date.now()))
  else if (!/Could not find the function|schema cache/i.test(error.message || '')) {
    console.warn('KCP client heartbeat:', error.message || error)
  }
}

const kcpHeartbeatPreviousRenderAll = renderAll
renderAll = function () {
  kcpHeartbeatPreviousRenderAll()
  registerClientHeartbeat().catch(console.warn)
}

window.addEventListener('online', () => registerClientHeartbeat(true).catch(console.warn))
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') registerClientHeartbeat().catch(console.warn)
})
