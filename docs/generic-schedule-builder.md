# Generic schedule builder

KCP schedules are configured as data. The scheduling engine does not contain parent names, school names, activity names, weekdays, or clock times.

## Administrator workflow

The mobile setup is intentionally limited to four steps:

1. **Schedule basics** — name, start/end dates, friendly outbound/return labels, and automatic completion duration.
2. **Recurring rides** — one card per weekday/time combination. Each card can contain outbound only, return only, or both.
3. **Driving responsibility** — select a generic assignment strategy and arrange participating drivers.
4. **Preview and publish** — inspect the generated weeks before creating a new published schedule version.

A group calendar is optional. Admins can add date exceptions or import closures later without blocking the initial schedule.

## Recurring session examples

The same model represents morning, afternoon, evening, overnight, and one-way carpools.

```text
Thursday activity
  Drop-off: 6:30 PM
  Pickup:   7:00 PM

Friday activity
  Drop-off: 5:00 PM
  Pickup:   6:00 PM
```

The two weekdays retain independent times because each is a separate `kcp_recurring_sessions` row.

A session may also be configured as:

```text
Monday pickup only at 3:30 PM
Saturday outbound only at 8:00 AM
Friday return at 12:15 AM the following day
Every second Tuesday
```

## Assignment strategies

| Strategy | Responsibility unit | Typical use |
|---|---|---|
| Fixed | Whole plan | One regular driver |
| Rotate every ride | Individual outbound/return leg | Every trip advances to the next driver |
| Rotate every day | All rides on one date | One parent handles drop and pickup that day |
| Rotate by week | All configured rides in the calendar week | One parent handles multiple activity days that week |
| Balance automatically | Individual trip | Even distribution across selected drivers in the generated plan |
| Assign later | No automatic driver | Admin or volunteers fill coverage later |

### Weekly bundled rotation

For a two-person weekly rotation, the admin selects **Rotate by week**, chooses the first rotation date, and orders the drivers:

```text
1. Driver A
2. Driver B
```

The engine creates one responsibility block per policy/week. Every configured session and both ride legs in that week point to the same block and participant.

```text
Week 1: Driver A — Thursday drop/pickup + Friday drop/pickup
Week 2: Driver B — Thursday drop/pickup + Friday drop/pickup
Week 3: Driver A — repeats
```

The admin also chooses what happens when a week has no rides:

- **Keep calendar-week rotation** — the calendar week determines the driver even when an occurrence is skipped.
- **Advance only when rides occur** — only weeks containing generated rides advance the rotation.

## Ownership

`kcp_create_group_v3` performs group creation in one database transaction:

1. Creates the group.
2. Creates the creator's active membership with role `owner`.
3. Creates the stable group participant.
4. Creates the child/rider record.
5. Creates schedule-plan version 1 as a draft.
6. Writes the audit event.

A deferred constraint trigger validates that every group with active members finishes the transaction with exactly one active Owner. Deferring the check permits an atomic account-recovery transaction to insert the replacement Owner and remove the former Owner without exposing an invalid committed state. The Owner can immediately open the schedule builder and publish even when no other parent has joined. Multiple Admins are supported.

## Stable identity

Schedules reference `kcp_group_participants.id`, not only Supabase Auth UUIDs. A participant remains stable if a parent changes devices or recovers an anonymous pilot account.

```text
Stable participant P1
  old Auth identity U1
  recovered Auth identity U2
```

Only the participant-to-user link changes. Schedule policies, responsibility blocks, and generated trips retain participant P1.

## Versioning

Opening an already published schedule creates a new draft by copying:

- schedule dates and labels
- recurring sessions
- assignment policies
- driver order
- applicable exceptions

Previewing does not modify the published schedule. Publishing:

1. supersedes the prior published plan and schedule-version metadata
2. creates a new schedule version
3. creates new responsibility blocks and trips
4. updates the group's active plan/version pointer
5. preserves all earlier versions for audit

Completed and historical versions are never deleted by the builder.

## Genericity guard

CI scans the generic schema and engine migrations. It fails if domain-specific participant, school, or activity names are introduced into scheduling code. Seed and test fixtures may contain scenario names; production scheduling functions may not.

## Regression coverage

The suite verifies:

- creator becomes the single active Owner
- Owner can configure and publish without a calendar
- ownership transfer remains atomic during account recovery
- independent evening times per weekday
- outbound-only, return-only, and both-leg validation
- weekly responsibility bundles
- two-person weekly rotation and repeat cycle
- stable participant IDs on generated trips
- generic labels instead of morning/afternoon assumptions
- responsibility-block creation
- draft cloning and schedule version preservation
- immutable publication audit history
- existing KCP visual theme and navigation contracts
