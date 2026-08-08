// Schedule-builder usability layer.
//
// Keeps the complete generic schedule model intact, but presents one focused
// step at a time and moves rarely changed options behind progressive disclosure.
// It also fixes dialog close buttons that previously submitted their forms.

if (!document.querySelector('link[href="./schedule-builder-usability.css"]')) {
  const stylesheet = document.createElement('link')
  stylesheet.rel = 'stylesheet'
  stylesheet.href = './schedule-builder-usability.css'
  document.head.appendChild(stylesheet)
}

const kcpUsabilityScheduleDialog = el('scheduleBuilderDialog')
const kcpUsabilityScheduleForm = el('scheduleBuilderForm')
const kcpUsabilityGenericDialog = el('genericGroupDialog')
const kcpUsabilityGenericForm = el('genericGroupForm')

let kcpScheduleStep = 1
let kcpScheduleMaxUnlockedStep = 3
let kcpSchedulePreviewFresh = false

const KCP_SCHEDULE_STEPS = [
  { number: 1, label: 'Basics' },
  { number: 2, label: 'Rides' },
  { number: 3, label: 'Drivers' },
  { number: 4, label: 'Preview' }
]

prepareExplicitDialogClose(
  kcpUsabilityGenericDialog,
  kcpUsabilityGenericForm,
  'close-generic-group-dialog'
)
prepareExplicitDialogClose(
  kcpUsabilityScheduleDialog,
  kcpUsabilityScheduleForm,
  'close-schedule-builder-dialog'
)
prepareScheduleBuilderStructure()

const kcpPreviousRenderScheduleSessionCards = renderScheduleSessionCards
renderScheduleSessionCards = function () {
  kcpPreviousRenderScheduleSessionCards()
  simplifyRenderedSessionCards()
  updateScheduleStepSummaries()
}

const kcpPreviousRenderScheduleParticipantPicker = renderScheduleParticipantPicker
renderScheduleParticipantPicker = function () {
  kcpPreviousRenderScheduleParticipantPicker()
  simplifyAssignmentOptions()
  updateScheduleStepSummaries()
}

const kcpPreviousRenderScheduleStrategyHelp = renderScheduleStrategyHelp
renderScheduleStrategyHelp = function () {
  kcpPreviousRenderScheduleStrategyHelp()
  simplifyAssignmentOptions()
  updateScheduleStepSummaries()
}

const kcpPreviousRenderScheduleBuilder = renderScheduleBuilder
renderScheduleBuilder = function () {
  kcpPreviousRenderScheduleBuilder()
  prepareScheduleBuilderStructure()
  simplifyRenderedSessionCards()
  simplifyAssignmentOptions()
  kcpSchedulePreviewFresh = false
  kcpScheduleMaxUnlockedStep = 3
  setScheduleBuilderStep(1, { force: true })
  updateScheduleStepSummaries()
}

if (kcpUsabilityScheduleDialog) {
  kcpUsabilityScheduleDialog.addEventListener('input', event => {
    if (event.target.closest('input, select, textarea')) markSchedulePreviewStale()
  })
  kcpUsabilityScheduleDialog.addEventListener('change', event => {
    if (event.target.closest('input, select, textarea')) markSchedulePreviewStale()
  })

  kcpUsabilityScheduleDialog.addEventListener('click', async event => {
    const action = event.target.closest('[data-action]')?.dataset.action
    if (!action) return

    if (action === 'go-schedule-step') {
      event.preventDefault()
      event.stopImmediatePropagation()
      const requestedStep = Number(event.target.closest('[data-step]')?.dataset.step)
      if (requestedStep <= kcpScheduleMaxUnlockedStep) {
        setScheduleBuilderStep(requestedStep)
      }
      return
    }

    if (action === 'schedule-step-back') {
      event.preventDefault()
      event.stopImmediatePropagation()
      setScheduleBuilderStep(Math.max(1, kcpScheduleStep - 1))
      return
    }

    if (action === 'schedule-step-primary') {
      event.preventDefault()
      event.stopImmediatePropagation()
      await advanceScheduleBuilder()
    }
  }, { capture: true })
}

// Pressing Enter in a field follows the current step instead of submitting the
// entire long form or accidentally publishing it.
kcpUsabilityScheduleForm?.addEventListener('submit', async event => {
  event.preventDefault()
  event.stopImmediatePropagation()
  await advanceScheduleBuilder()
}, { capture: true })

// Publishing remains handled by the existing implementation. This capture
// guard only ensures the administrator has previewed the latest changes first.
el('publishSchedulePlan')?.addEventListener('click', event => {
  if (kcpSchedulePreviewFresh) return
  event.preventDefault()
  event.stopImmediatePropagation()
  toast('Preview the latest changes before publishing.', true)
  setScheduleBuilderStep(3)
}, { capture: true })

function prepareExplicitDialogClose(dialog, form, actionName) {
  if (!dialog || !form) return

  const closeButton = form.querySelector('.close-button')
  if (closeButton) {
    closeButton.type = 'button'
    closeButton.removeAttribute('value')
    closeButton.removeAttribute('formmethod')
    closeButton.dataset.action = actionName
    closeButton.addEventListener('click', event => {
      event.preventDefault()
      event.stopImmediatePropagation()
      dialog.close('cancel')
    }, { capture: true })
  }

  // Safari supports Escape through the native cancel event. Keeping the event
  // unblocked lets the browser close the modal normally.
  dialog.addEventListener('cancel', () => {
    if (dialog === kcpUsabilityScheduleDialog) resetScheduleBuilderNavigation()
  })

  // Tapping the dimmed backdrop is another predictable exit path.
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return
    dialog.close('cancel')
  })

  dialog.addEventListener('close', () => {
    if (dialog === kcpUsabilityScheduleDialog) resetScheduleBuilderNavigation()
  })
}

function prepareScheduleBuilderStructure() {
  if (!kcpUsabilityScheduleDialog || !kcpUsabilityScheduleForm) return

  const closeButton = kcpUsabilityScheduleForm.querySelector('.close-button')
  if (closeButton) closeButton.type = 'button'

  const cards = [...kcpUsabilityScheduleForm.querySelectorAll('.schedule-step-card')]
  cards.forEach((card, index) => {
    card.dataset.scheduleStepPanel = String(index + 1)
  })

  const intro = kcpUsabilityScheduleForm.querySelector('.schedule-builder-intro')
  if (intro && !kcpUsabilityScheduleForm.querySelector('.schedule-progress')) {
    intro.insertAdjacentHTML('afterend', `
      <nav class="schedule-progress" aria-label="Schedule setup progress">
        ${KCP_SCHEDULE_STEPS.map(step => `
          <button type="button" data-action="go-schedule-step" data-step="${step.number}" aria-label="Open ${step.label}">
            <span>${step.number}</span>
            <strong>${step.label}</strong>
            <small data-step-summary="${step.number}"></small>
          </button>`).join('')}
      </nav>`)
  }

  simplifyScheduleBasics()
  simplifyAssignmentOptions()
  prepareScheduleBuilderActions()
  setScheduleBuilderStep(kcpScheduleStep, { force: true })
}

function simplifyScheduleBasics() {
  const grid = kcpUsabilityScheduleForm?.querySelector('.schedule-basic-grid')
  if (!grid || kcpUsabilityScheduleForm.querySelector('#scheduleBasicsAdvanced')) return

  const advancedFieldIds = [
    'schedulePlanName',
    'scheduleOutboundLabel',
    'scheduleReturnLabel',
    'scheduleAutoComplete'
  ]
  const advancedLabels = advancedFieldIds
    .map(id => el(id)?.closest('label'))
    .filter(Boolean)

  if (!advancedLabels.length) return

  const details = document.createElement('details')
  details.id = 'scheduleBasicsAdvanced'
  details.className = 'schedule-advanced'
  details.innerHTML = '<summary>Names and automation <span>Optional settings</span></summary><div class="schedule-advanced-grid"></div>'
  const advancedGrid = details.querySelector('.schedule-advanced-grid')
  advancedLabels.forEach(label => advancedGrid.appendChild(label))
  grid.insertAdjacentElement('afterend', details)
}

function simplifyRenderedSessionCards() {
  kcpUsabilityScheduleForm?.querySelectorAll('.schedule-session-card').forEach(card => {
    const grid = card.querySelector('.schedule-session-grid')
    if (!grid || card.querySelector('.schedule-session-advanced')) return

    const nameLabel = card.querySelector('[data-session-field="name"]')?.closest('label')
    const repeatsLabel = card.querySelector('[data-session-field="intervalWeeks"]')?.closest('label')
    const returnDayLabel = card.querySelector('[data-session-field="returnDayOffset"]')?.closest('label')
    const anchorLabel = card.querySelector('[data-session-field="anchorDate"]')?.closest('label')
    const advancedLabels = [nameLabel, repeatsLabel, returnDayLabel, anchorLabel].filter(Boolean)

    if (!advancedLabels.length) return

    const details = document.createElement('details')
    details.className = 'schedule-session-advanced schedule-advanced'
    details.innerHTML = '<summary>More options <span>Name, repeat interval and overnight return</span></summary><div class="schedule-advanced-grid"></div>'
    const advancedGrid = details.querySelector('.schedule-advanced-grid')
    advancedLabels.forEach(label => advancedGrid.appendChild(label))
    grid.insertAdjacentElement('afterend', details)
  })
}

function simplifyAssignmentOptions() {
  const fixedRow = el('scheduleFixedParticipantRow')
  const assignmentCard = el('scheduleStrategy')?.closest('.schedule-step-card')
  const optionGrid = assignmentCard?.querySelector('.schedule-label-grid')
  if (!assignmentCard || !optionGrid) return

  if (fixedRow && !fixedRow.dataset.simplifiedPlacement) {
    fixedRow.dataset.simplifiedPlacement = 'true'
    const weeklyHint = el('scheduleWeeklyHint')
    weeklyHint?.insertAdjacentElement('afterend', fixedRow)
  }

  if (!assignmentCard.querySelector('#scheduleRotationAdvanced')) {
    const remainingLabels = [...optionGrid.querySelectorAll(':scope > label')]
    if (remainingLabels.length) {
      const details = document.createElement('details')
      details.id = 'scheduleRotationAdvanced'
      details.className = 'schedule-advanced'
      details.innerHTML = '<summary>Rotation options <span>Anchor date and skipped-week behavior</span></summary><div class="schedule-advanced-grid"></div>'
      const advancedGrid = details.querySelector('.schedule-advanced-grid')
      remainingLabels.forEach(label => advancedGrid.appendChild(label))
      fixedRow?.insertAdjacentElement('afterend', details)
    }
  }

  if (!optionGrid.children.length) optionGrid.remove()
}

function prepareScheduleBuilderActions() {
  const actions = kcpUsabilityScheduleForm?.querySelector('.schedule-builder-actions')
  if (!actions || actions.dataset.progressive === 'true') return
  actions.dataset.progressive = 'true'

  const originalPreview = actions.querySelector('button[type="submit"]')
  if (originalPreview) {
    originalPreview.type = 'button'
    originalPreview.id = 'scheduleStepPrimary'
    originalPreview.dataset.action = 'schedule-step-primary'
    originalPreview.className = 'primary-button'
  }

  if (!el('scheduleStepBack')) {
    actions.insertAdjacentHTML(
      'afterbegin',
      '<button id="scheduleStepBack" class="secondary-button" data-action="schedule-step-back" type="button">Back</button>'
    )
  }
}

async function advanceScheduleBuilder() {
  if (kcpScheduleStep === 1) {
    const error = validateScheduleBasicsStep()
    if (error) return toast(error, true)
    kcpScheduleMaxUnlockedStep = Math.max(kcpScheduleMaxUnlockedStep, 2)
    setScheduleBuilderStep(2)
    return
  }

  if (kcpScheduleStep === 2) {
    const error = validateScheduleRidesStep()
    if (error) return toast(error, true)
    kcpScheduleMaxUnlockedStep = Math.max(kcpScheduleMaxUnlockedStep, 3)
    setScheduleBuilderStep(3)
    return
  }

  if (kcpScheduleStep === 3 || kcpScheduleStep === 4) {
    try {
      await saveAndPreviewGenericSchedule()
      kcpSchedulePreviewFresh = true
      kcpScheduleMaxUnlockedStep = 4
      setScheduleBuilderStep(4)
      updateScheduleStepSummaries()
    } catch (error) {
      toast(error.message || String(error), true)
    }
  }
}

function validateScheduleBasicsStep() {
  const startsOn = el('scheduleStartsOn')?.value
  const endsOn = el('scheduleEndsOn')?.value
  if (!startsOn || !endsOn) return 'Choose the first and last date for this schedule.'
  if (startsOn > endsOn) return 'The schedule end date must be on or after the start date.'
  return ''
}

function validateScheduleRidesStep() {
  const errors = validateScheduleDraft({
    startsOn: el('scheduleStartsOn')?.value,
    endsOn: el('scheduleEndsOn')?.value,
    sessions: scheduleDraftSessions,
    strategy: 'manual',
    participantIds: [],
    fixedParticipantId: null
  })
  return errors[0] || ''
}

function setScheduleBuilderStep(step, { force = false } = {}) {
  if (!kcpUsabilityScheduleDialog) return
  const bounded = Math.max(1, Math.min(4, Number(step) || 1))
  if (!force && bounded > kcpScheduleMaxUnlockedStep) return

  kcpScheduleStep = bounded
  kcpUsabilityScheduleDialog.dataset.currentScheduleStep = String(bounded)

  kcpUsabilityScheduleDialog.querySelectorAll('[data-schedule-step-panel]').forEach(panel => {
    const selected = Number(panel.dataset.scheduleStepPanel) === bounded
    panel.classList.toggle('schedule-step-active', selected)
    panel.hidden = !selected
  })

  kcpUsabilityScheduleDialog.querySelectorAll('.schedule-progress button').forEach(button => {
    const buttonStep = Number(button.dataset.step)
    button.classList.toggle('active', buttonStep === bounded)
    button.classList.toggle('complete', buttonStep < bounded || buttonStep < kcpScheduleMaxUnlockedStep)
    button.disabled = buttonStep > kcpScheduleMaxUnlockedStep
    button.setAttribute('aria-current', buttonStep === bounded ? 'step' : 'false')
  })

  updateScheduleBuilderActions()
  updateScheduleStepSummaries()
  kcpUsabilityScheduleForm?.scrollTo({ top: 0, behavior: 'smooth' })
}

function updateScheduleBuilderActions() {
  const back = el('scheduleStepBack')
  const primary = el('scheduleStepPrimary')
  const publish = el('publishSchedulePlan')
  const actions = kcpUsabilityScheduleForm?.querySelector('.schedule-builder-actions')
  if (!back || !primary || !publish || !actions) return

  back.classList.toggle('hidden', kcpScheduleStep === 1)
  publish.classList.toggle('hidden', kcpScheduleStep !== 4)
  actions.classList.toggle('is-final-step', kcpScheduleStep === 4)

  if (kcpScheduleStep === 1 || kcpScheduleStep === 2) {
    primary.textContent = 'Continue'
    primary.className = 'primary-button'
  } else if (kcpScheduleStep === 3) {
    primary.textContent = 'Preview schedule'
    primary.className = 'primary-button'
  } else {
    primary.textContent = 'Refresh preview'
    primary.className = 'secondary-button'
  }
}

function updateScheduleStepSummaries() {
  if (!kcpUsabilityScheduleDialog) return

  const starts = el('scheduleStartsOn')?.value
  const ends = el('scheduleEndsOn')?.value
  const strategy = ASSIGNMENT_STRATEGIES.find(item => item.value === el('scheduleStrategy')?.value)
  const driverCount = scheduleParticipantOrder.filter(id => selectedScheduleParticipants.has(id)).length

  setStepSummary(1, starts && ends ? `${shortDate(starts)} – ${shortDate(ends)}` : 'Choose dates')
  setStepSummary(2, `${scheduleDraftSessions.length} recurring ride${scheduleDraftSessions.length === 1 ? '' : 's'}`)
  setStepSummary(3, `${strategy?.title || 'Assignment'}${driverCount ? ` · ${driverCount} driver${driverCount === 1 ? '' : 's'}` : ''}`)
  setStepSummary(4, kcpSchedulePreviewFresh ? 'Ready to publish' : 'Preview required')
}

function setStepSummary(step, text) {
  const target = kcpUsabilityScheduleDialog?.querySelector(`[data-step-summary="${step}"]`)
  if (target) target.textContent = text
}

function markSchedulePreviewStale() {
  if (!kcpSchedulePreviewFresh) {
    updateScheduleStepSummaries()
    return
  }
  kcpSchedulePreviewFresh = false
  kcpScheduleMaxUnlockedStep = Math.min(kcpScheduleMaxUnlockedStep, 3)
  updateScheduleStepSummaries()
  if (kcpScheduleStep === 4) {
    el('schedulePreview')?.insertAdjacentHTML(
      'afterbegin',
      '<p class="schedule-preview-stale">The rules changed. Refresh the preview before publishing.</p>'
    )
  }
  updateScheduleBuilderActions()
}

function resetScheduleBuilderNavigation() {
  kcpScheduleStep = 1
  kcpScheduleMaxUnlockedStep = 3
  kcpSchedulePreviewFresh = false
}

function shortDate(value) {
  if (!value) return ''
  const parsed = new Date(`${value}T12:00:00`)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}
