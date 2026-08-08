# KCP simplification plan

## Why this shape

Native iOS is the MVP; Android is possible; the PWA is a temporary vehicle
until an Apple Developer account exists. That makes the **database the durable
asset and every client disposable**. So:

- Business rules live in PostgreSQL `security definer` RPCs. Clients render and
  call. A rule implemented in Swift is a rule that must be reimplemented in
  Kotlin and JavaScript, and the three will drift.
- The BASIS pilot is **data**, not a code path. Nothing about BASIS appears in
  a function body.
- Authentication is delegated entirely to Supabase Auth. KCP stores no secrets.

## What replaces what

| Removed | Replaced by |
|---|---|
| `kcp_memberships` | `kcp_group_participants` (gains `role`, `invited_by`) |
| `kcp_constraint_requests` | `kcp_constraints` with a `status` column |
| `kcp_roster_slots` | `kcp_assignment_policies` + `..._members` (seed data) |
| `kcp_schedule_versions` | `kcp_schedule_plans` (a published plan *is* a version) |
| `kcp_group_snapshots` | nothing — it bridged the FastAPI/Swift JSON blob |
| `kcp_device_links` | Supabase Auth sessions |
| `kcp_recovery_challenges` | Supabase Auth email OTP + passkeys |

Measured against the current `main`:

| | before | after |
|---|---|---|
| tables | 26 | 19 |
| functions | 68 | 25 |
| RLS policies | 29 (+29 matching `DROP POLICY`) | 16 |
| SQL lines | 8,343 across 27 migrations | 1,798 baseline + 166 seed |

### Functions deleted

`kcp_generate_schedule` (defined 4×), `kcp_generate_fixed_schedule`,
`kcp_generate_balanced_schedule`, `kcp_sync_participant_from_membership`,
`kcp_reconcile_participant_after_membership_transfer`,
`kcp_transfer_group_membership`, `kcp_sync_trip_driver_from_participant`,
`kcp_save_snapshot`, `kcp_get_snapshot`, `kcp_create_device_link`,
`kcp_restore_device_link`, `kcp_reactivate_transferred_device_link`,
`kcp_revoke_device_links_after_membership_removal`,
`kcp_issue_roster_recovery_code`, `kcp_recover_seeded_roster`,
`kcp_bind_seeded_roster`, `kcp_claim_basis_pilot`, `kcp_seeded_pilot_status`,
`kcp_set_pilot_time_override`, and the rest of the BASIS-specific surface.

The four duplicate definitions of `kcp_generate_schedule` are the clearest
symptom of the old approach: each new requirement redefined the generator
rather than adding a row.

### The hardcoded-names problem

`kcp_generate_fixed_schedule` contained the pilot families' names in its body:

```sql
case weekday_num
    when 1 then 'Kiran'
    when 2 then 'Santhosh'
    ...
```

Onboarding a second school meant editing SQL. In the baseline the same rule is
four `fixed` policies plus one `round_robin_day` policy — rows an admin can
create from the app.

## Proving the deletion is safe

`supabase/tests/equivalence_basis_generic.sql` restates the legacy rule
independently (straight from migration `202608060008`) and asserts the generic
engine produces an identical set of `(date, leg, driver)` rows. It does **not**
call the old function, so it keeps passing after the deletion.

Current result: **354 legs, zero differences.**

### One intentional divergence

The legacy generator emitted a `NULL` pickup time on early-release and
project-week days, which surfaced as "time unknown". The seed models those days
as explicit `change_time` exceptions so every trip stays actionable. The
placeholder is `12:00` — replace it with the school's published early-release
times.

## Authentication decision

**Supabase Auth with email OTP as the account anchor and passkeys for
day-to-day sign-in. No passwords, no SMS, no anonymous accounts.**

Reasoning against your constraints (free, secure, open source, simple):

- **Supabase Auth (GoTrue)** is MIT-licensed and already provisioned. Adding a
  third-party identity provider would mean a second user store to reconcile.
- **Email OTP** is free and universal. Supabase's built-in SMTP is rate-limited
  to a handful of messages per hour, so point it at a free-tier transactional
  provider before the pilot widens.
- **Passkeys** entered Supabase Auth beta on 28 May 2026 (supabase/discussions
  #46458), with SDK floors of `supabase-js` 2.105.0, `supabase-swift` 2.48.0
  and `supabase_flutter` 2.15.0 per the Passkey authentication docs. Note that
  many third-party guides still say Supabase has no native passkey support —
  those predate this release. Face ID sign-in with no
  shared secret is a better fit for a parent-facing app than any password flow,
  and it is phishing-resistant by construction. Treat it as the fast path with
  email OTP always available as the fallback, since the API is still marked
  experimental.
- **Not SMS**: Twilio costs money per message, which breaks the free
  constraint.
- **Not passwords**: a password store is a liability with no upside here.
- **Sign in with Apple** is worth adding at TestFlight time. It needs a paid
  Apple Developer account for the Service ID, so it cannot be part of the PWA
  pilot. Note that once you offer *any* third-party sign-in on iOS, App Store
  guideline 4.8 requires offering Sign in with Apple alongside it.

### Why this deletes code

`kcp_device_links` and `kcp_recovery_challenges` exist only because anonymous
accounts have no recovery path, so the app grew its own credential system:
SHA-256 secret hashes, one-time codes, device revocation, ~1,000 lines across
migrations `016` and `021`. Real auth makes all of it redundant. Hand-rolled
credential handling is exactly what a small community app should not be
maintaining.

**Migration note:** anonymous pilot accounts should be linked to an email
before the old tables are dropped, or those testers lose access. With no live
data today, the simplest path is to require email OTP from the first pilot
session.

## Sequence

1. Apply the baseline to a scratch Supabase project; run `run_all.sh`. ✅ green
2. Enable email OTP + passkeys in the Supabase dashboard; wire custom SMTP.
3. Point the PWA at the new RPC names; fix the `app.parts` build (below).
4. Archive `backend/`, `SchoolCarpool/Services/GroupAPI.swift` and
   `CarpoolStore.swift`'s HTTP layer.
5. Rewrite the Swift client thin against `supabase-swift`.
6. Delete the old migrations once the pilot has run a full week on the baseline.

## PWA build fix (half a day, then stop)

`deploy-pages.yml` runs `cat web/app.parts/*.js > app.js`. The parts split
mid-expression — `00.js` ends on `p_drop_weekdays: [1, 2, 3, 4, 5],` and `01.js`
opens with the next key — so nothing runs locally without CI, and local and
production behaviour differ.

Minimum fix: make each part a real ES module with explicit exports, import them
from `app.js`, drop the `cat` step. Consolidate the six competing
`document.addEventListener('click', …)` handlers into one delegated dispatcher,
and remove the duplicate `openCreateGroup` binding in `00.js` and `10.js`.

Do not invest further. The PWA is scaffolding.

## Free-tier headroom

At 354 trips per group per year, the 1 GB Supabase allowance is not a
constraint on trip data. `kcp_audit_events` is the only unbounded table; add a
retention job if a group exceeds a few hundred thousand rows.
