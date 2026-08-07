# Kidscarpool Supabase database ER diagram

This diagram reflects the normalized KCP pilot schema after migration `202608060016`. Supabase `auth.users` owns authentication identities; `kcp_profiles` is the application profile keyed by the same UUID.

```mermaid
erDiagram
    AUTH_USERS ||--|| KCP_PROFILES : "identity / profile"

    KCP_PROFILES ||--o{ KCP_GROUPS : creates
    KCP_GROUPS ||--o{ KCP_MEMBERSHIPS : contains
    KCP_PROFILES ||--o{ KCP_MEMBERSHIPS : joins

    KCP_GROUPS ||--o{ KCP_INVITATIONS : issues
    KCP_PROFILES ||--o{ KCP_INVITATIONS : "invites / accepts"

    KCP_GROUPS ||--o{ KCP_CONSTRAINTS : owns
    KCP_PROFILES ||--o{ KCP_CONSTRAINTS : configures
    KCP_GROUPS ||--o{ KCP_CONSTRAINT_REQUESTS : reviews
    KCP_PROFILES ||--o{ KCP_CONSTRAINT_REQUESTS : submits

    KCP_GROUPS ||--o{ KCP_ROSTER_SLOTS : preloads
    KCP_PROFILES o|--o| KCP_ROSTER_SLOTS : claims

    KCP_GROUPS ||--o{ KCP_SCHOOL_CALENDARS : optionally_has
    KCP_SCHOOL_CALENDARS ||--o{ KCP_CALENDAR_EVENTS : contains

    KCP_GROUPS ||--o{ KCP_SCHEDULE_VERSIONS : publishes
    KCP_GROUPS ||--o{ KCP_TRIPS : schedules
    KCP_PROFILES o|--o{ KCP_TRIPS : "scheduled / actual driver"

    KCP_TRIPS ||--o{ KCP_COVER_REQUESTS : coverage
    KCP_PROFILES ||--o{ KCP_COVER_REQUESTS : "requests / accepts / cancels"

    KCP_TRIPS ||--o| KCP_POINTS_LEDGER : awards
    KCP_PROFILES ||--o{ KCP_POINTS_LEDGER : earns

    KCP_GROUPS ||--o{ KCP_AUDIT_EVENTS : records
    KCP_PROFILES o|--o{ KCP_AUDIT_EVENTS : acts

    KCP_GROUPS ||--o| KCP_GROUP_SNAPSHOTS : legacy_bridge
    KCP_GROUPS ||--o{ KCP_DEVICE_LINKS : remembers
    KCP_PROFILES ||--o{ KCP_DEVICE_LINKS : owns

    KCP_GROUPS ||--o{ KCP_RECOVERY_CHALLENGES : secures
    KCP_PROFILES ||--o{ KCP_RECOVERY_CHALLENGES : "claimed / used"

    AUTH_USERS {
        uuid id PK
        text email
        boolean is_anonymous
    }

    KCP_PROFILES {
        uuid id PK_FK
        text display_name
        text phone
        timestamptz created_at
        timestamptz updated_at
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
        int current_schedule_version
        date schedule_start_date
        date schedule_end_date
        smallint_array service_weekdays
        time drop_time
        time pickup_time
        boolean auto_lifecycle_enabled
        int auto_complete_after_minutes
        text schedule_policy
        text status
    }

    KCP_MEMBERSHIPS {
        uuid group_id PK_FK
        uuid user_id PK_FK
        text parent_name
        text child_name
        int grade
        text role
        text status
        uuid invited_by FK
        timestamptz joined_at
    }

    KCP_INVITATIONS {
        uuid id PK
        uuid group_id FK
        text token UK
        text invited_parent_name
        text child_name
        int grade
        text role
        text status
        uuid invited_by FK
        uuid accepted_by FK
        timestamptz expires_at
        timestamptz accepted_at
    }

    KCP_CONSTRAINTS {
        uuid group_id PK_FK
        uuid user_id PK_FK
        smallint_array drop_weekdays
        smallint_array pickup_weekdays
        text notes
        int version
        date effective_from
        uuid updated_by FK
    }

    KCP_CONSTRAINT_REQUESTS {
        uuid id PK
        uuid group_id FK
        uuid user_id FK
        smallint_array requested_drop_weekdays
        smallint_array requested_pickup_weekdays
        text status
        uuid reviewed_by FK
        int base_version
    }

    KCP_ROSTER_SLOTS {
        uuid id PK
        uuid group_id FK
        text parent_name
        text child_name
        int grade
        text pickup_tag
        smallint fixed_weekday
        smallint friday_rotation_order
        uuid claimed_user_id FK
    }

    KCP_SCHOOL_CALENDARS {
        uuid id PK
        uuid group_id FK
        text school_key
        text academic_year
        text source_sha256
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
        text notes
    }

    KCP_SCHEDULE_VERSIONS {
        uuid id PK
        uuid group_id FK
        int version UK
        text status
        text reason
        uuid generated_by FK
        uuid published_by FK
        jsonb change_summary
    }

    KCP_TRIPS {
        uuid id PK
        uuid group_id FK
        int schedule_version
        date trip_date
        text kind
        uuid scheduled_driver_id FK
        uuid actual_driver_id FK
        text scheduled_driver_name
        text actual_driver_name
        text status
        timestamptz scheduled_time
        text_array child_names
        boolean volunteer_assignment
        text started_source
        text completed_source
    }

    KCP_COVER_REQUESTS {
        uuid id PK
        uuid group_id FK
        uuid trip_id FK
        uuid requested_by FK
        text status
        uuid accepted_by FK
        uuid cancelled_by FK
        text cancellation_reason
        timestamptz accepted_at
        timestamptz cancelled_at
    }

    KCP_POINTS_LEDGER {
        uuid id PK
        uuid group_id FK
        uuid trip_id UK_FK
        uuid user_id FK
        int points
        text reason
    }

    KCP_AUDIT_EVENTS {
        bigint id PK
        uuid group_id FK
        uuid actor_id FK
        text action
        text entity_type
        text entity_id
        jsonb details
        timestamptz occurred_at
    }

    KCP_GROUP_SNAPSHOTS {
        uuid group_id PK_FK
        jsonb snapshot
        uuid updated_by FK
    }

    KCP_DEVICE_LINKS {
        uuid id PK
        uuid group_id FK
        uuid user_id FK
        text secret_hash UK
        text label
        timestamptz last_used_at
        timestamptz revoked_at
    }

    KCP_RECOVERY_CHALLENGES {
        uuid id PK
        uuid group_id FK
        text roster_parent_name
        uuid claimed_user_id FK
        text secret_hash UK
        timestamptz expires_at
        timestamptz used_at
        uuid used_by FK
    }
```

## Integrity and security rules

- Every user-facing application table has Row-Level Security enabled. Parents can read only groups in which they have an active membership.
- Cross-table mutations—group creation, invitation acceptance, schedule generation, trip lifecycle, recovery and cover withdrawal—run through `SECURITY DEFINER` functions that validate `auth.uid()` and group role.
- `kcp_audit_events` is append-only. A database trigger rejects updates and deletes.
- Only one points-ledger row is allowed per trip, preventing duplicate automatic or manual awards.
- Only one open cover request is allowed per trip.
- Device and one-time recovery secrets are never stored in plaintext. PostgreSQL stores SHA-256 hashes; plaintext is returned only once to the authorized client or Supabase project operator.
- A membership recovery moves the active group membership and operational references to the replacement Auth UUID. The former membership is retained as `removed`, while historical audit actor IDs remain unchanged.

## Schedule lineage

`kcp_groups.current_schedule_version` points to the current published version. Older `kcp_schedule_versions` and their `kcp_trips` remain in PostgreSQL for audit and comparison. The application normally reads trips matching the active version.
