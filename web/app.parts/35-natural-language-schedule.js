import {
  parseNaturalSchedule,
  formatNaturalUnderstanding
} from './natural-schedule.js'

let naturalScheduleResult = null

function ensureNaturalScheduleUI() {
  const templatePanel = el('scheduleTemplatePanel')
  if (templatePanel && !el('naturalSchedulePanel')) {
    templatePanel.insertAdjacentHTML('afterend', `
      <section id="naturalSchedulePanel" class="natural-schedule-panel">
        <div class="natural-schedule-heading">
          <div><span class="eyebrow">PLAIN-LANGUAGE SETUP · MVP2</span><h4>Describe the schedule instead</h4></div>
          <span class="status-pill info">Confirmation required</span>
        </div>
        <p>Use ordinary language for recurring days, times and driver rotation. KCP converts it into the same weekly matrix and never saves or publishes without your confirmation.</p>
        <label class="natural-schedule-input">Schedule description
          <textarea id="naturalScheduleText" rows="5" placeholder="Example: Thursday 6:30 PM to 7 PM and Friday 5 PM to 6 PM. Driver A and Driver B alternate weekly."></textarea>
        </label>
        <div class="button-row"><button class="secondary-button" data-action="analyze-natural-schedule" type="button">Check my description</button></div>
      </section>`)
  }

  if (!el('naturalScheduleDialog')) {
    document.body.insertAdjacentHTML('beforeend', `
      <dialog id="naturalScheduleDialog" class="modal natural-schedule-dialog">
        <div class="dialog-form">
          <div class="dialog-title">
            <div><span class="eyebrow">CONFIRM THE UNDERSTANDING</span><h2>What KCP understood</h2></div>
            <button id="naturalScheduleClose" class="close-button" type="button" aria-label="Close">×</button>
          </div>
          <div id="naturalScheduleUnderstanding"></div>
          <div class="natural-schedule-actions">
            <button id="naturalScheduleEdit" class="secondary-button" type="button">Back to edit</button>
            <button id="naturalScheduleApply" class="primary-button" type="button">Apply to weekly matrix</button>
          </div>
        </div>
      </dialog>`)

    const close = () => {
      if (el('naturalScheduleDialog')?.open) el('naturalScheduleDialog').close('cancel')
    }
    el('naturalScheduleClose')?.addEventListener('click', close)
    el('naturalScheduleEdit')?.addEventListener('click', close)
    el('naturalScheduleDialog')?.addEventListener('cancel', event => {
      event.preventDefault()
      close()
    })
    el('naturalScheduleDialog')?.addEventListener('click', event => {
      if (event.target === el('naturalScheduleDialog')) close()
    })
    el('naturalScheduleApply')?.addEventListener('click', applyNaturalSchedule)
  }
}

ensureNaturalScheduleUI()

const kcpNaturalPreviousOpenScheduleBuilder = openGenericScheduleBuilder
openGenericScheduleBuilder = async function (...args) {
  await kcpNaturalPreviousOpenScheduleBuilder(...args)
  ensureNaturalScheduleUI()
  naturalScheduleResult = null
}

document.addEventListener('click', event => {
  const analyze = event.target.closest('[data-action="analyze-natural-schedule"]')
  if (!analyze) return
  event.preventDefault()
  event.stopImmediatePropagation()
  analyzeNaturalSchedule()
}, { capture: true })

function analyzeNaturalSchedule() {
  const text = el('naturalScheduleText')?.value.trim() || ''
  const participants = (state.scheduleBuilder?.participants || [])
    .filter(participant => participant.status === 'active' && participant.can_drive)
  naturalScheduleResult = parseNaturalSchedule(text, {
    participants,
    startsOn: el('scheduleStartsOn')?.value || '',
    defaultStrategy: 'manual'
  })
  renderNaturalScheduleUnderstanding(naturalScheduleResult)
  el('naturalScheduleDialog').showModal()
}

function renderNaturalScheduleUnderstanding(result) {
  const target = el('naturalScheduleUnderstanding')
  const questions = result.questions || []
  const warnings = result.warnings || []
  const apply = el('naturalScheduleApply')
  apply.disabled = !result.canApply
  apply.textContent = result.canApply ? 'Apply to weekly matrix' : 'Clarification required'

  target.innerHTML = `
    <section class="natural-understanding-summary">
      <h3>Recurring rides</h3>
      ${result.summaryLines?.length
        ? `<div class="natural-ride-list">${result.summaryLines.map(line => `<div><span aria-hidden="true">▦</span><strong>${escapeHTML(line)}</strong></div>`).join('')}</div>`
        : '<p class="meta">No complete recurring ride was understood.</p>'}
    </section>
    <section class="natural-understanding-summary">
      <h3>Driving responsibility</h3>
      <p>${escapeHTML(result.assignmentSummary || 'Drivers will be selected in Step 3.')}</p>
      ${result.participantNames?.length ? `<div class="natural-driver-list">${result.participantNames.map(name => `<span>${escapeHTML(name)}</span>`).join('')}</div>` : ''}
    </section>
    ${questions.length ? `<section class="natural-questions" role="alert"><h3>Clarify before applying</h3><ul>${questions.map(question => `<li>${escapeHTML(question)}</li>`).join('')}</ul><p>Edit the description, include AM/PM or correct the driver name, then check it again.</p></section>` : ''}
    ${warnings.length ? `<section class="natural-warnings"><h3>Please verify</h3><ul>${warnings.map(warning => `<li>${escapeHTML(warning)}</li>`).join('')}</ul></section>` : ''}
    <details class="natural-technical-summary"><summary>Plain-language summary</summary><p>${escapeHTML(formatNaturalUnderstanding(result))}</p></details>
    <p class="natural-no-save-note"><strong>Nothing has been saved.</strong> Applying only fills the schedule form. The normal driver confirmation, preview, impact review and Publish steps still apply.</p>`
}

function applyNaturalSchedule() {
  const result = naturalScheduleResult
  if (!result?.canApply) {
    toast('Clarify the highlighted details before applying the schedule.', true)
    return
  }

  scheduleDraftSessions = result.sessions.map((session, index) => createSessionDraft({
    ...session,
    clientId: undefined,
    displayOrder: index + 1,
    anchorDate: session.anchorDate || el('scheduleStartsOn')?.value || ''
  }))

  if (el('scheduleStrategy')) el('scheduleStrategy').value = result.strategy
  const activeDriverIds = (state.scheduleBuilder?.participants || [])
    .filter(participant => participant.status === 'active' && participant.can_drive)
    .map(participant => participant.id)
  scheduleParticipantOrder = [
    ...result.participantIds,
    ...activeDriverIds.filter(id => !result.participantIds.includes(id))
  ]
  selectedScheduleParticipants = new Set(result.participantIds)

  if (typeof invalidateScheduleImpact === 'function') invalidateScheduleImpact()
  if (typeof markSchedulePreviewStale === 'function') markSchedulePreviewStale()
  renderScheduleBuilder()
  ensureNaturalScheduleUI()
  if (result.strategy === 'fixed' && result.participantIds.length === 1 && el('scheduleFixedParticipant')) {
    el('scheduleFixedParticipant').value = result.participantIds[0]
  }

  el('naturalScheduleDialog').close('applied')
  toast('Schedule understanding applied. Review the weekly matrix and drivers before previewing.')
}
