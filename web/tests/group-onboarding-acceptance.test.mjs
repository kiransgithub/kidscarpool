import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const dialogs = fs.readFileSync('web/app.parts/09a-generic-dialogs.js', 'utf8')
const builder = fs.readFileSync('web/app.parts/10.js', 'utf8')
const invitations = fs.readFileSync('web/app.parts/23-adaptive-invitations.js', 'utf8')
const impact = fs.readFileSync('web/app.parts/31-schedule-templates-impact.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608090001_kcp_group_onboarding_acceptance.sql', 'utf8')
const multiGroup = fs.readFileSync('supabase/tests/integration_multiple_group_onboarding.sql', 'utf8')
const inviteStyles = fs.readFileSync('web/adaptive-invitations.css', 'utf8')

test('group creation collects known drivers and rider details', () => {
  assert.match(dialogs, /Invite drivers and add known riders/)
  assert.match(builder, /addGroupDriverInvite/)
  assert.match(builder, /kcp_create_driver_invitation/)
  assert.match(migration, /p_child_name text default null/)
})

test('real-world multi-group scenario covers accepted, declined and pending drivers', () => {
  assert.match(multiGroup, /School rotation/)
  assert.match(multiGroup, /Music rotation/)
  assert.match(multiGroup, /Sports rotation/)
  assert.match(multiGroup, /Owner expected 3 isolated groups/)
  assert.match(multiGroup, /Owner cannot view pending-driver schedule draft/)
})

test('checkbox controls preserve readable labels on narrow screens', () => {
  assert.match(inviteStyles, /flex:\s*0 0 22px/)
  assert.match(inviteStyles, /overflow-wrap:\s*anywhere/)
})

test('email-bound invitations are delivered with the private invite redirect', () => {
  assert.match(invitations, /signInWithOtp/)
  assert.match(invitations, /emailRedirectTo: url\.toString\(\)/)
  assert.match(invitations, /shouldCreateUser: true/)
})

test('invited drivers can accept or decline', () => {
  assert.match(invitations, /invitationDecline/)
  assert.match(invitations, /kcp_decline_invitation/)
  assert.match(migration, /status = 'declined'/)
})

test('pending driver decisions block publish but never draft preview', () => {
  assert.match(impact, /kcp_publish_schedule_plan_v3/)
  assert.match(migration, /All invited drivers must accept or decline before the schedule can be published/)
  assert.match(migration, /return public\.kcp_publish_schedule_plan_v2/)
})
