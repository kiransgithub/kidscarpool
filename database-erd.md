# Kidscarpool Supabase database ER diagram

This diagram reflects the baseline schema in
`supabase/migrations/00000000000001_kcp_baseline.sql` (19 tables).

Supabase `auth.users` owns authentication identities. `kcp_profiles` is the
application profile keyed by the same UUID. `kcp_group_participants` is the
single per-group identity: it carries role, status and driving capability, and
is what schedules, trips and points reference. There is no separate membership
table, so no synchronisation triggers are needed.

```mermaid
erDiagram
    AUTH_USERS ||--o| KCP_PROFILES : "identity / profile"

    KCP_PROFILES |o--o{ KCP_GROUPS : creates
    KCP_GROUPS ||--o{ KCP_GROUP_PARTICIPANTS : has
    KCP_PROFILES |o--o{ KCP_GROUP_PARTICIPANTS : "currently links"
    KCP_GROUP_PARTICIPANTS ||--o{ KCP_CHILDREN : cares_for

    KCP_GROUPS ||--o{ KCP_INVITATIONS : issues
    KCP_GROUP_PARTICIPANTS |o--o{ KCP_INVITATIONS : "invites / reserves"

    KCP_GROUPS ||--o{ KCP_CONSTRAINTS : owns
    KCP_GROUP_PARTICIPANTS ||--o{ KCP_CONSTRAINTS : "submits / reviews"

    KCP_GROUPS ||--o{ KCP_SCHOOL_CALENDARS : optionally_has
    KCP_SCHOOL_CALENDARS ||--o{ KCP_CALENDAR_EVENTS : contains

    KCP_GROUPS ||--o{ KCP_SCHEDULE_PLANS : versions
    KCP_SCHEDULE_PLANS ||--o{ KCP_RECURRING_SESSIONS : defines_when
    KCP_SCHEDULE_PLANS ||--o{ KCP_ASSIGNMENT_POLICIES : defines_who
    KCP_ASSIGNMENT_POLICIES ||--o{ KCP_POLICY_SESSIONS : applies_to
    KCP_RECURRING_SESSIONS ||--o{ KCP_POLICY_SESSIONS : included_in
    KCP_ASSIGNMENT_POLICIES ||--o{ KCP_ASSIGNMENT_POLICY_MEMBERS : rotates
    KCP_GROUP_PARTICIPANTS ||--o{ KCP_ASSIGNMENT_POLICY_MEMBERS : participates
    KCP_SCHEDULE_PLANS ||--o{ KCP_SCHEDULE_EXCEPTIONS : overrides
    KCP_SCHEDULE_PLANS ||--o{ KCP_RESPONSIBILITY_BLOCKS : groups_rides
    KCP_GROUP_PARTICIPANTS |o--o{ KCP_RESPONSIBILITY_BLOCKS : owns_block

    KCP_GROUPS ||--o{ KCP_TRIPS : schedules
    KCP_SCHEDULE_PLANS ||--o{ KCP_TRIPS : generates
    KCP_RECURRING_SESSIONS |o--o{ KCP_TRIPS : instantiates
    KCP_RESPONSIBILITY_BLOCKS |o--o{ KCP_TRIPS : bundles
    KCP_GROUP_PARTICIPANTS |o--o{ KCP_TRIPS : "scheduled / actual"

    KCP_TRIPS ||--o{ KCP_COVER_REQUESTS : coverage
    KCP_GROUP_PARTICIPANTS ||--o{ KCP_COVER_REQUESTS : "requests / accepts"

    KCP_TRIPS ||--o| KCP_POINTS_LEDGER : awards
    KCP_GROUP_PARTICIPANTS ||--o{ KCP_POINTS_LEDGER : earns

    KCP_GROUPS ||--o{ KCP_AUDIT_EVENTS : records
    KCP_GROUP_PARTICIPANTS |o--o{ KCP_AUDIT_EVENTS : acts

    AUTH_USERS {
        uuid id PK
        text email
    }

    KCP_PROFILES {
        uuid id PK, FK
        text display_name
        text phone
    }

    KCP_GROUPS {
        uuid id PK
        text code UK
        text name
        text group_kind
        text school_name
        text academic_year
        text timezone
        uuid created_by FK
        uuid active_schedule_plan_id FK
        text status
    }

    KCP_GROUP_PARTICIPANTS {
        uuid id PK
        uuid group_id FK
        uuid user_id FK
        text display_name
        text role
        text status
        boolean can_drive
        text source
        uuid invited_by FK
        timestamptz joined_at
    }

    KCP_CHILDREN {
        uuid id PK
        uuid group_id FK
        uuid participant_id FK
        text name
        text grade_or_level
        text pickup_tag
        text status
    }

    KCP_INVITATIONS {
        uuid id PK
        uuid group_id FK
        text token UK
        text invited_name
        text role
        uuid participant_id FK
        text status
        uuid invited_by FK
        uuid accepted_by FK
        timestamptz expires_at
    }

    KCP_CONSTRAINTS {
        uuid id PK
        uuid group_id FK
        uuid participant_id FK
        smallint_array drop_weekdays
        smallint_array pickup_weekdays
        text status
        int version
        date effective_from
        uuid submitted_by FK
        uuid reviewed_by FK
    }

    KCP_SCHOOL_CALENDARS {
        uuid id PK
        uuid group_id FK
        text school_key
        text academic_year
        text storage_path
        uuid uploaded_by FK
    }

    KCP_CALENDAR_EVENTS {
        uuid id PK
        uuid calendar_id FK
        text event_type
        text title
        date start_date
        date end_date
    }

    KCP_SCHEDULE_PLANS {
        uuid id PK
        uuid group_id FK
        int version UK
        text name
        text status
        date starts_on
        date ends_on
        text timezone
        text outbound_label
        text return_label
        int auto_complete_after_minutes
        jsonb change_summary
        uuid created_by_participant_id FK
        uuid published_by_participant_id FK
    }

    KCP_RECURRING_SESSIONS {
        uuid id PK
        uuid schedule_plan_id FK
        text name
        smallint weekday
        int recurrence_interval_weeks
        date recurrence_anchor_date
        boolean outbound_enabled
        time outbound_time
        boolean return_enabled
        time return_time
        smallint return_day_offset
        int display_order
        text status
    }

    KCP_ASSIGNMENT_POLICIES {
        uuid id PK
        uuid schedule_plan_id FK
        text name
        text strategy
        text cycle_behavior
        date anchor_date
        uuid fixed_participant_id FK
        int priority
        text status
        jsonb config
    }

    KCP_POLICY_SESSIONS {
        uuid policy_id PK, FK
        uuid session_id PK, FK
    }

    KCP_ASSIGNMENT_POLICY_MEMBERS {
        uuid policy_id PK, FK
        uuid participant_id PK, FK
        int rotation_position UK
        int weight
        boolean active
    }

    KCP_SCHEDULE_EXCEPTIONS {
        uuid id PK
        uuid schedule_plan_id FK
        uuid session_id FK
        date exception_date
        text action
        time replacement_outbound_time
        time replacement_return_time
        uuid override_participant_id FK
    }

    KCP_RESPONSIBILITY_BLOCKS {
        uuid id PK
        uuid group_id FK
        uuid schedule_plan_id FK
        uuid policy_id FK
        text block_key UK
        date block_start
        date block_end
        uuid participant_id FK
        text status
    }

    KCP_TRIPS {
        uuid id PK
        uuid group_id FK
        uuid schedule_plan_id FK
        uuid recurring_session_id FK
        uuid responsibility_block_id FK
        date trip_date
        text leg_type
        text display_label
        uuid scheduled_participant_id FK
        uuid actual_participant_id FK
        text status
        timestamptz scheduled_time
        timestamptz started_at
        timestamptz completed_at
        text_array child_names
        boolean volunteer_assignment
    }

    KCP_COVER_REQUESTS {
        uuid id PK
        uuid group_id FK
        uuid trip_id FK
        uuid requested_by FK
        text status
        uuid accepted_by FK
        uuid cancelled_by FK
    }

    KCP_POINTS_LEDGER {
        uuid id PK
        uuid group_id FK
        uuid trip_id UK, FK
        uuid participant_id FK
        int points
        text reason
    }

    KCP_AUDIT_EVENTS {
        bigint id PK
        uuid group_id FK
        uuid actor_participant_id FK
        uuid actor_user_id
        text action
        text entity_type
        text entity_id
        jsonb details
        timestamptz occurred_at
    }
```

## Schedule generation flow

```mermaid
flowchart LR
    G[Carpool group] --> P[Draft schedule plan]
    P --> S[Recurring sessions: weekday and independent times]
    P --> A[Assignment policies]
    A --> M[Ordered participants]
    P --> E[Optional exceptions or calendar closures]
    S --> V[Preview occurrences]
    A --> V
    M --> V
    E --> V
    V --> B[Responsibility blocks]
    B --> T[Outbound and return trips]
    T --> H[Home, schedule, cover and points workflows]
```

## Integrity and security rules

- Every application table has Row-Level Security enabled. A person can read
  only groups in which they are an active participant.
- A group is created atomically with its creator as the single active owner and
  an initial draft schedule plan.
- **Exactly one active owner** per group with active participants is enforced by
  a *deferred* constraint trigger on `kcp_group_participants`, checked at
  `COMMIT`. It deliberately is **not** an immediate partial unique index: an
  immediate index rejects the transient two-owner state that an atomic owner
  transfer or account recovery must pass through. See
  `supabase/tests/regression_owner_invariant.sql`.
- `kcp_group_participants` is the stable per-group identity. An auth UUID can
  be repointed without disturbing schedule membership or trip history.
- Recurring sessions store times per weekday/session and support any clock
  time, outbound-only, return-only, both legs, multi-week intervals, and return
  legs up to two days later.
- Assignment strategies are data, not code branches: `fixed`,
  `round_robin_trip`, `round_robin_day`, `round_robin_week`, `balanced`,
  `manual`. No participant name appears in any function body; CI enforces this.
- A responsibility block keeps rides that must stay together on one participant.
- Calendars and exceptions are optional; a plan can generate from sessions alone.
- Publishing supersedes the previous plan and creates a new version. Older
  plans and their trips remain for audit and comparison.
- `kcp_audit_events` is append-only; a trigger rejects updates and deletes.
- One points-ledger row per trip prevents duplicate awards.
- One open cover request per trip.
- No credential material is stored by the application. Authentication is
  delegated entirely to Supabase Auth.

## The BASIS pilot

BASIS is seed **data**, not a code path: see `supabase/seeds/basis_pilot.sql`.
Monday–Thursday are four `fixed` policies scoped to one weekday session each;
Friday is one `round_robin_day` policy over the same four participants.
`supabase/tests/equivalence_basis_generic.sql` asserts this reproduces the
retired hardcoded generator exactly.
