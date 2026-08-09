import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

async function text(relative) {
  return readFile(path.join(repoRoot, relative), 'utf8')
}

test('generic group and schedule dialogs expose the simple four-step workflow', async () => {
  const dialogs = await text('web/app.parts/09a-generic-dialogs.js')

  for (const id of [
    'genericGroupDialog',
    'genericGroupForm',
    'scheduleBuilderDialog',
    'scheduleBuilderForm',
    'scheduleSessionsList',
    'scheduleStrategy',
    'scheduleParticipantsList',
    'schedulePreview',
    'publishSchedulePlan'
  ]) {
    assert.match(dialogs, new RegExp(`id="${id}"`))
  }

  assert.match(dialogs, /You become the group owner/)
  assert.match(dialogs, /Days and ride times/)
  assert.match(dialogs, /Choose drivers/)
  assert.match(dialogs, /Check rides before sharing/)
  assert.match(dialogs, /Take turns by week/)
  assert.match(dialogs, /make the schedule live/)
})

test('schedule-builder styles are additive and reuse the KCP design tokens', async () => {
  const [styles, builderStyles] = await Promise.all([
    text('web/styles.css'),
    text('web/generic-schedule.css')
  ])

  assert.match(styles, /--navy:\s*#071a3d/)
  assert.match(styles, /--blue:\s*#155eef/)
  assert.match(builderStyles, /var\(--blue\)/)
  assert.match(builderStyles, /var\(--purple\)/)
  assert.match(builderStyles, /var\(--surface\)/)

  for (const selector of [
    '.schedule-builder-modal',
    '.schedule-session-card',
    '.rotation-person',
    '.schedule-preview-week',
    '.schedule-builder-actions'
  ]) {
    assert.ok(builderStyles.includes(selector), `${selector} visual contract is missing`)
  }

  assert.match(builderStyles, /@media \(max-width: 560px\)/)
  assert.match(builderStyles, /height:\s*100dvh/)
})

test('builder enhancement preserves generic labels and does not hard-code a scenario', async () => {
  const enhancement = await text('web/app.parts/10.js')

  assert.match(enhancement, /kcp_create_group_v3/)
  assert.match(enhancement, /kcp_save_schedule_plan/)
  assert.match(enhancement, /kcp_plan_occurrences/)
  assert.match(enhancement, /kcp_publish_schedule_plan/)
  assert.match(enhancement, /display_label/)
  assert.match(enhancement, /leg_type/)

  for (const forbidden of ['DRMA', 'Kiran', 'Mohan', 'BASIS Phoenix']) {
    assert.doesNotMatch(enhancement, new RegExp(`\\b${forbidden}\\b`, 'i'))
  }
})
