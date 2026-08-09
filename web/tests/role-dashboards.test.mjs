import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/22-role-specific-dashboards.js', 'utf8')
const styles = fs.readFileSync('web/role-dashboards.css', 'utf8')
const worker = fs.readFileSync('web/service-worker-v24.js', 'utf8')

test('viewer Home is read-only and omits internal change and version metrics', () => {
  assert.match(source, /READ-ONLY VIEW/)
  assert.match(source, /Group-management settings are hidden/)
  assert.match(source, /requestsButton\.classList\.toggle\('hidden', portfolio\.viewerOnly\)/)
  const viewerStart = source.indexOf("if (portfolio.viewerOnly)", source.indexOf('renderHome = function'))
  const viewerBlock = source.slice(viewerStart, source.indexOf("if (portfolio.managedGroups.length)", viewerStart))
  assert.doesNotMatch(viewerBlock, /pendingChanges|current_schedule_version/)
})

test('Owner and Admin Home shows only operational management metrics', () => {
  assert.match(source, /OWNER \+ ADMIN OVERVIEW/)
  assert.match(source, /Open covers/)
  assert.match(source, /Unassigned rides/)
  assert.match(source, /Pending changes/)
  assert.match(source, /Pending invites/)
})

test('Parent Home focuses on assignments and personal requests', () => {
  assert.match(source, /YOUR RIDES/)
  assert.match(source, /YOUR NEXT ASSIGNMENT/)
  assert.match(source, /requested_by === state\.session/)
  assert.match(source, /accepted_by === state\.session/)
})

test('group cards and group detail adapt to the membership role', () => {
  assert.match(source, /data-group-role/)
  assert.match(source, /role === 'viewer'.*Read only/s)
  assert.match(source, /if \(\['owner','admin'\]\.includes\(role\)\) return/)
  assert.match(source, /READ-ONLY GROUP/)
})

test('installed app refreshes role-specific dashboards', () => {
  assert.match(styles, /manager-metrics/)
  assert.match(worker, /v24-offline-accessibility/)
  assert.match(worker, /\.\/role-dashboards\.css/)
})
