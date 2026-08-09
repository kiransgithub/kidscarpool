// Persistent page controls and scroll restoration for the single-page app.
// The bottom navigation remains available, while Back returns to the previous
// screen and Close returns Home without rebuilding either screen's DOM state.

const KCP_VIEW_SCROLL_KEY = 'kcp.viewScroll'
const KCP_VIEW_HISTORY_KEY = 'kcp.viewHistory'
const KCP_PAGE_TITLES = {
  groups: 'Your groups',
  schedule: 'Schedule',
  volunteers: 'Volunteer rides',
  leaderboard: 'Driving summary',
  calendar: 'Calendar',
  settings: 'Settings',
  requests: 'Updates'
}

let kcpViewScroll = readNavigationState(KCP_VIEW_SCROLL_KEY, {})
let kcpViewHistory = readNavigationState(KCP_VIEW_HISTORY_KEY, [])

function readNavigationState(key, fallback) {
  try {
    const parsed = JSON.parse(sessionStorage.getItem(key) || '')
    return parsed && typeof parsed === 'object' ? parsed : fallback
  } catch {
    return fallback
  }
}

function writeNavigationState() {
  sessionStorage.setItem(KCP_VIEW_SCROLL_KEY, JSON.stringify(kcpViewScroll))
  sessionStorage.setItem(KCP_VIEW_HISTORY_KEY, JSON.stringify(kcpViewHistory.slice(-30)))
}

function renderPageNavigation() {
  const bar = el('pageNavigationBar')
  if (!bar) return
  const visible = Boolean(state.session && state.profile && state.currentView && state.currentView !== 'home')
  bar.classList.toggle('hidden', !visible)
  if (!visible) return

  el('pageNavigationTitle').textContent = KCP_PAGE_TITLES[state.currentView]
    || document.querySelector(`.view[data-view="${CSS.escape(state.currentView)}"] h1`)?.textContent
    || 'Kidscarpool'
  el('pageBackButton').disabled = false
  el('pageBackButton').title = kcpViewHistory.length ? 'Return to the previous screen' : 'Return Home'
}

navigate = function (view, options = {}) {
  const target = document.querySelector(`.view[data-view="${CSS.escape(view)}"]`)
  if (!target) return

  const current = state.currentView
  const changing = current && current !== view
  if (changing) {
    kcpViewScroll[current] = Math.max(0, Math.round(window.scrollY || 0))
    if (options.record !== false) {
      if (kcpViewHistory.at(-1) !== current) kcpViewHistory.push(current)
      window.history.pushState({ kcpView: view }, '', location.href)
    }
  } else if (!window.history.state?.kcpView) {
    window.history.replaceState({ ...window.history.state, kcpView: view }, '', location.href)
  }

  state.currentView = view
  localStorage.setItem(VIEW_KEY, view)
  qsa('.view[data-view]').forEach(section => section.classList.toggle('hidden', section.dataset.view !== view))
  qsa('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.nav === view))
  writeNavigationState()
  renderPageNavigation()

  const savedTop = options.restore === false ? 0 : Number(kcpViewScroll[view] || 0)
  requestAnimationFrame(() => window.scrollTo({ top: savedTop, behavior: 'auto' }))
}

function navigateBack() {
  const previous = kcpViewHistory.pop() || 'home'
  writeNavigationState()
  navigate(previous, { record: false })
}

function closeCurrentPage() {
  kcpViewHistory = []
  writeNavigationState()
  navigate('home', { record: false })
}

el('pageBackButton')?.addEventListener('click', navigateBack)
el('pageCloseButton')?.addEventListener('click', closeCurrentPage)

window.addEventListener('popstate', event => {
  const view = event.state?.kcpView
  if (view && view !== state.currentView) navigate(view, { record: false })
})

renderPageNavigation()
