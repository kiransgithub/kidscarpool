-- ===========================================================================
-- Kidscarpool (KCP) — baseline schema
--
-- Squashes migrations 202608060001..202608070001 into one settled schema.
--
-- Design rules this baseline enforces:
--   1. ONE scheduling engine. A group owns versioned schedule plans; plans own
--      recurring sessions and data-driven assignment policies. There is no
--      second "fixed weekday" code path and no hardcoded participant names.
--      The BASIS pilot is expressed as seed DATA (see supabase/seeds/).
--   2. ONE identity per person per group: kcp_group_participants. It carries
--      role and status directly, so no membership/participant sync triggers.
--   3. ONE version registry: kcp_schedule_plans. Publishing supersedes the
--      previous plan and creates a new one.
--   4. Business rules live in SECURITY DEFINER functions, not in clients.
--      iOS, Android and the PWA all call the same RPCs.
--   5. Authentication is delegated entirely to Supabase Auth (email OTP +
--      passkeys). No bespoke device-secret or recovery-code tables.
-- ===========================================================================

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text not null default 'Parent'
        check (length(trim(display_name)) between 1 and 80),
    phone text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_groups (
    id uuid primary key default gen_random_uuid(),
    code text not null unique
        check (code ~ '^[A-Z0-9]{6}$'),
    name text not null
        check (length(trim(name)) between 1 and 120),
    group_kind text not null default 'school'
        check (group_kind in ('school','activity','sport','other')),
    -- School metadata is optional: a group need not be tied to a school.
    school_name text,
    academic_year text,
    timezone text not null default 'America/Phoenix',
    created_by uuid references public.kcp_profiles(id) on delete set null,
    active_schedule_plan_id uuid,
    status text not null default 'active'
        check (status in ('active','archived')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Participants — the single identity for a person inside a group.
--
-- Replaces the old kcp_memberships + kcp_group_participants pair. Because
-- role and status live on the same row as the operational identity, there is
-- nothing to keep in sync: recovering an account is one UPDATE of user_id,
-- and every schedule/trip/points reference stays valid.
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_group_participants (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    user_id uuid references public.kcp_profiles(id) on delete set null,
    display_name text not null
        check (length(trim(display_name)) between 1 and 80),
    role text not null default 'parent'
        check (role in ('owner','admin','parent','viewer')),
    status text not null default 'active'
        check (status in ('invited','active','inactive','removed')),
    can_drive boolean not null default true,
    source text not null default 'invitation'
        check (source in ('creator','invitation','seed','admin')),
    invited_by uuid references public.kcp_group_participants(id) on delete set null,
    joined_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- One auth identity may hold at most one participant row per group.
create unique index if not exists kcp_participant_user_per_group
    on public.kcp_group_participants(group_id, user_id)
    where user_id is not null;

-- NOTE: deliberately NO immediate partial unique index on
-- (group_id) where role='owner' and status='active'.
-- An immediate index rejects the intermediate two-owner state that an atomic
-- owner transfer or account recovery must pass through, which is exactly the
-- bug fixed by migration 202608070001. The deferred constraint trigger below
-- enforces "exactly one active owner" at COMMIT instead, catching both the
-- zero-owner and multi-owner cases without blocking transfer.

create index if not exists kcp_participants_group_status_idx
    on public.kcp_group_participants(group_id, status, can_drive);

-- (kcp_groups.active_schedule_plan_id gains its FK once plans exist, below.)

-- ---------------------------------------------------------------------------
-- Children
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_children (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    participant_id uuid not null
        references public.kcp_group_participants(id) on delete cascade,
    name text not null check (length(trim(name)) between 1 and 80),
    grade_or_level text,
    pickup_tag text,
    status text not null default 'active'
        check (status in ('active','inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (group_id, participant_id, name)
);

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_invitations (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    token text not null unique,
    invited_name text not null check (length(trim(invited_name)) between 1 and 80),
    role text not null default 'parent'
        check (role in ('admin','parent','viewer')),
    -- An invitation may be bound to a pre-seeded participant row, which is how
    -- a roster (e.g. the BASIS pilot) is claimed without duplicating people.
    participant_id uuid references public.kcp_group_participants(id) on delete set null,
    status text not null default 'pending'
        check (status in ('pending','accepted','revoked','expired')),
    invited_by uuid references public.kcp_group_participants(id) on delete set null,
    accepted_by uuid references public.kcp_profiles(id) on delete set null,
    expires_at timestamptz not null default now() + interval '30 days',
    accepted_at timestamptz,
    created_at timestamptz not null default now()
);

create index if not exists kcp_invitations_group_status_idx
    on public.kcp_invitations(group_id, status);

-- ---------------------------------------------------------------------------
-- Availability constraints
--
-- Replaces the old kcp_constraints + kcp_constraint_requests pair. A pending
-- row IS the request; approving it flips status and supersedes the previous
-- approved row. The admin queue is a filtered read, not a second table.
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_constraints (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    participant_id uuid not null
        references public.kcp_group_participants(id) on delete cascade,
    drop_weekdays smallint[] not null default '{1,2,3,4,5}',
    pickup_weekdays smallint[] not null default '{1,2,3,4,5}',
    notes text,
    status text not null default 'pending'
        check (status in ('pending','approved','rejected','superseded')),
    version integer not null default 1,
    effective_from date not null default current_date,
    submitted_by uuid references public.kcp_group_participants(id) on delete set null,
    reviewed_by uuid references public.kcp_group_participants(id) on delete set null,
    review_note text,
    reviewed_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (drop_weekdays <@ '{1,2,3,4,5,6,7}'::smallint[]),
    check (pickup_weekdays <@ '{1,2,3,4,5,6,7}'::smallint[])
);

-- At most one approved (current) row per participant, and at most one
-- outstanding request per participant.
create unique index if not exists kcp_constraints_one_approved
    on public.kcp_constraints(group_id, participant_id)
    where status = 'approved';

create unique index if not exists kcp_constraints_one_pending
    on public.kcp_constraints(group_id, participant_id)
    where status = 'pending';

-- ---------------------------------------------------------------------------
-- School calendars (optional)
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_school_calendars (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    school_key text not null,
    academic_year text not null,
    source_sha256 text,
    storage_path text,
    uploaded_by uuid references public.kcp_group_participants(id) on delete set null,
    created_at timestamptz not null default now(),
    unique (group_id, school_key, academic_year)
);

create table if not exists public.kcp_calendar_events (
    id uuid primary key default gen_random_uuid(),
    calendar_id uuid not null
        references public.kcp_school_calendars(id) on delete cascade,
    event_type text not null
        check (event_type in (
            'first_day','last_day','no_school','early_release',
            'late_start','no_late_bird','project_week','other'
        )),
    title text not null,
    start_date date not null,
    end_date date not null,
    notes text,
    created_at timestamptz not null default now(),
    check (end_date >= start_date),
    unique (calendar_id, event_type, start_date, end_date)
);

create index if not exists kcp_calendar_events_range_idx
    on public.kcp_calendar_events(calendar_id, event_type, start_date, end_date);

commit;

begin;

-- ===========================================================================
-- Scheduling engine
--
-- kcp_schedule_plans is the single version registry. The old
-- kcp_schedule_versions table is gone: a published plan IS a version.
-- ===========================================================================

create table if not exists public.kcp_schedule_plans (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    version integer not null,
    name text not null default 'Recurring schedule',
    status text not null default 'draft'
        check (status in ('draft','published','superseded','archived')),
    starts_on date,
    ends_on date,
    timezone text,
    outbound_label text not null default 'Drop-off',
    return_label text not null default 'Pickup',
    auto_complete_after_minutes integer not null default 60
        check (auto_complete_after_minutes between 5 and 480),
    reason text,
    change_summary jsonb not null default '{}'::jsonb,
    created_by_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    published_by_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    published_at timestamptz,
    check (starts_on is null or ends_on is null or ends_on >= starts_on),
    unique (group_id, version)
);

-- Only one draft and one published plan may exist per group at a time.
create unique index if not exists kcp_plans_one_draft
    on public.kcp_schedule_plans(group_id) where status = 'draft';
create unique index if not exists kcp_plans_one_published
    on public.kcp_schedule_plans(group_id) where status = 'published';

alter table public.kcp_groups
    drop constraint if exists kcp_groups_active_plan_fk;
alter table public.kcp_groups
    add constraint kcp_groups_active_plan_fk
    foreign key (active_schedule_plan_id)
    references public.kcp_schedule_plans(id) on delete set null;

-- ---------------------------------------------------------------------------
-- Recurring sessions: when the group travels.
-- Independent outbound/return times, multi-week intervals, and return legs
-- up to two days later are all expressible.
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_recurring_sessions (
    id uuid primary key default gen_random_uuid(),
    schedule_plan_id uuid not null
        references public.kcp_schedule_plans(id) on delete cascade,
    name text not null check (length(trim(name)) between 1 and 120),
    weekday smallint not null check (weekday between 1 and 7),
    recurrence_interval_weeks integer not null default 1
        check (recurrence_interval_weeks between 1 and 52),
    recurrence_anchor_date date,
    outbound_enabled boolean not null default true,
    outbound_time time without time zone,
    return_enabled boolean not null default true,
    return_time time without time zone,
    return_day_offset smallint not null default 0
        check (return_day_offset between 0 and 2),
    destination_override text,
    display_order integer not null default 0,
    status text not null default 'active'
        check (status in ('active','inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (outbound_enabled or return_enabled),
    check (not outbound_enabled or outbound_time is not null),
    check (not return_enabled or return_time is not null)
);

create index if not exists kcp_sessions_plan_order_idx
    on public.kcp_recurring_sessions(schedule_plan_id, weekday, display_order);

-- ---------------------------------------------------------------------------
-- Assignment policies: who drives. Strategies are data, not branches.
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_assignment_policies (
    id uuid primary key default gen_random_uuid(),
    schedule_plan_id uuid not null
        references public.kcp_schedule_plans(id) on delete cascade,
    name text not null default 'Driving assignment',
    strategy text not null
        check (strategy in (
            'fixed',
            'round_robin_trip',
            'round_robin_day',
            'round_robin_week',
            'balanced',
            'manual'
        )),
    cycle_behavior text not null default 'calendar'
        check (cycle_behavior in ('calendar','occurrence')),
    anchor_date date,
    fixed_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    priority integer not null default 100,
    status text not null default 'active'
        check (status in ('active','inactive')),
    config jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (strategy <> 'fixed' or fixed_participant_id is not null)
);

create index if not exists kcp_policies_plan_priority_idx
    on public.kcp_assignment_policies(schedule_plan_id, priority desc, id);

-- A policy with no rows here applies to every session in the plan.
create table if not exists public.kcp_policy_sessions (
    policy_id uuid not null
        references public.kcp_assignment_policies(id) on delete cascade,
    session_id uuid not null
        references public.kcp_recurring_sessions(id) on delete cascade,
    primary key (policy_id, session_id)
);

create table if not exists public.kcp_assignment_policy_members (
    policy_id uuid not null
        references public.kcp_assignment_policies(id) on delete cascade,
    participant_id uuid not null
        references public.kcp_group_participants(id) on delete cascade,
    rotation_position integer not null check (rotation_position >= 1),
    weight integer not null default 1 check (weight between 1 and 10),
    active boolean not null default true,
    primary key (policy_id, participant_id),
    unique (policy_id, rotation_position)
);

create table if not exists public.kcp_schedule_exceptions (
    id uuid primary key default gen_random_uuid(),
    schedule_plan_id uuid not null
        references public.kcp_schedule_plans(id) on delete cascade,
    session_id uuid references public.kcp_recurring_sessions(id) on delete cascade,
    exception_date date not null,
    action text not null
        check (action in (
            'skip','change_time','change_driver','outbound_only','return_only'
        )),
    replacement_outbound_time time without time zone,
    replacement_return_time time without time zone,
    override_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (action <> 'change_driver' or override_participant_id is not null)
);

create index if not exists kcp_exceptions_plan_date_idx
    on public.kcp_schedule_exceptions(schedule_plan_id, exception_date);

-- ---------------------------------------------------------------------------
-- Responsibility blocks: rides that must stay with the same person.
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_responsibility_blocks (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    schedule_plan_id uuid not null
        references public.kcp_schedule_plans(id) on delete cascade,
    policy_id uuid references public.kcp_assignment_policies(id) on delete set null,
    block_key text not null,
    block_start date not null,
    block_end date not null,
    participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    status text not null default 'active'
        check (status in ('active','superseded')),
    created_at timestamptz not null default now(),
    check (block_end >= block_start),
    unique (schedule_plan_id, block_key)
);

-- ---------------------------------------------------------------------------
-- Trips
--
-- The legacy compatibility columns are gone: no `kind`, no
-- scheduled_driver_id/actual_driver_id, no driver-name denormalisation and no
-- sync trigger. A trip points at participants; participants point at users.
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_trips (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    schedule_plan_id uuid not null
        references public.kcp_schedule_plans(id) on delete cascade,
    recurring_session_id uuid
        references public.kcp_recurring_sessions(id) on delete set null,
    responsibility_block_id uuid
        references public.kcp_responsibility_blocks(id) on delete set null,
    trip_date date not null,
    leg_type text not null check (leg_type in ('outbound','return')),
    display_label text not null,
    scheduled_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    actual_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    status text not null default 'scheduled'
        check (status in ('scheduled','in_progress','completed','cancelled','missed')),
    scheduled_time timestamptz,
    started_at timestamptz,
    completed_at timestamptz,
    started_source text check (started_source in ('manual','auto')),
    completed_source text check (completed_source in ('manual','auto')),
    child_names text[] not null default '{}',
    volunteer_assignment boolean not null default false,
    notes text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (schedule_plan_id, trip_date, recurring_session_id, leg_type)
);

create index if not exists kcp_trips_group_date_idx
    on public.kcp_trips(group_id, trip_date, scheduled_time);
create index if not exists kcp_trips_participant_idx
    on public.kcp_trips(group_id, scheduled_participant_id, trip_date);

-- ---------------------------------------------------------------------------
-- Cover requests, points, audit
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_cover_requests (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    requested_by uuid not null
        references public.kcp_group_participants(id) on delete cascade,
    status text not null default 'open'
        check (status in ('open','accepted','cancelled','withdrawn','expired')),
    accepted_by uuid references public.kcp_group_participants(id) on delete set null,
    cancelled_by uuid references public.kcp_group_participants(id) on delete set null,
    note text,
    cancellation_reason text,
    created_at timestamptz not null default now(),
    accepted_at timestamptz,
    cancelled_at timestamptz
);

-- At most one open request per trip.
create unique index if not exists kcp_cover_one_open_per_trip
    on public.kcp_cover_requests(trip_id) where status = 'open';

create table if not exists public.kcp_points_ledger (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    trip_id uuid references public.kcp_trips(id) on delete cascade,
    participant_id uuid not null
        references public.kcp_group_participants(id) on delete cascade,
    points integer not null,
    reason text not null,
    created_at timestamptz not null default now()
);

-- One automatic award per trip; manual adjustments carry a null trip_id.
create unique index if not exists kcp_points_one_per_trip
    on public.kcp_points_ledger(trip_id) where trip_id is not null;

create table if not exists public.kcp_audit_events (
    id bigint generated always as identity primary key,
    group_id uuid references public.kcp_groups(id) on delete cascade,
    actor_participant_id uuid
        references public.kcp_group_participants(id) on delete set null,
    actor_user_id uuid,
    action text not null,
    entity_type text,
    entity_id text,
    details jsonb not null default '{}'::jsonb,
    occurred_at timestamptz not null default now()
);

create index if not exists kcp_audit_group_time_idx
    on public.kcp_audit_events(group_id, occurred_at desc);

commit;

begin;

-- ===========================================================================
-- Helpers
-- ===========================================================================

create or replace function public.kcp_touch_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

do $$
declare t text;
begin
    foreach t in array array[
        'kcp_profiles','kcp_groups','kcp_group_participants','kcp_children',
        'kcp_constraints','kcp_schedule_plans','kcp_recurring_sessions',
        'kcp_assignment_policies','kcp_schedule_exceptions','kcp_trips'
    ] loop
        execute format(
            'drop trigger if exists %I on public.%I', t || '_touch', t);
        execute format(
            'create trigger %I before update on public.%I
             for each row execute function public.kcp_touch_updated_at()',
            t || '_touch', t);
    end loop;
end;
$$;

-- Current participant row for the calling user in a group.
create or replace function public.kcp_current_participant_id(p_group_id uuid)
returns uuid
language sql stable security definer
set search_path = public, pg_catalog
as $$
    select p.id
    from public.kcp_group_participants p
    where p.group_id = p_group_id
      and p.user_id = auth.uid()
      and p.status = 'active'
    limit 1;
$$;

create or replace function public.kcp_is_member(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1 from public.kcp_group_participants p
        where p.group_id = p_group_id
          and p.user_id = auth.uid()
          and p.status = 'active'
    );
$$;

create or replace function public.kcp_is_admin(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1 from public.kcp_group_participants p
        where p.group_id = p_group_id
          and p.user_id = auth.uid()
          and p.status = 'active'
          and p.role in ('owner','admin')
    );
$$;

create or replace function public.kcp_write_audit(
    p_group_id uuid,
    p_action text,
    p_entity_type text default null,
    p_entity_id text default null,
    p_details jsonb default '{}'::jsonb
) returns void
language sql security definer
set search_path = public, pg_catalog
as $$
    insert into public.kcp_audit_events(
        group_id, actor_participant_id, actor_user_id,
        action, entity_type, entity_id, details)
    values (
        p_group_id, public.kcp_current_participant_id(p_group_id), auth.uid(),
        p_action, p_entity_type, p_entity_id, coalesce(p_details,'{}'::jsonb));
$$;

-- The audit log is append-only.
create or replace function public.kcp_forbid_audit_mutation()
returns trigger language plpgsql as $$
begin
    raise exception 'kcp_audit_events is append-only';
end;
$$;

drop trigger if exists kcp_audit_immutable on public.kcp_audit_events;
create trigger kcp_audit_immutable
    before update or delete on public.kcp_audit_events
    for each row execute function public.kcp_forbid_audit_mutation();

-- Exactly one active owner per group with any active participants.
-- Deferred so owner transfer can be one atomic transaction.
create or replace function public.kcp_check_single_active_owner()
returns trigger language plpgsql
set search_path = public, pg_catalog
as $$
declare
    v_group_id uuid := coalesce(new.group_id, old.group_id);
    v_active integer;
    v_owners integer;
begin
    select count(*) filter (where status = 'active'),
           count(*) filter (where status = 'active' and role = 'owner')
      into v_active, v_owners
      from public.kcp_group_participants
     where group_id = v_group_id;

    if v_active > 0 and v_owners <> 1 then
        raise exception
            'Group % must have exactly one active owner (found %)',
            v_group_id, v_owners;
    end if;
    return null;
end;
$$;

drop trigger if exists kcp_participants_owner_invariant
    on public.kcp_group_participants;
create constraint trigger kcp_participants_owner_invariant
    after insert or update or delete on public.kcp_group_participants
    deferrable initially deferred
    for each row execute function public.kcp_check_single_active_owner();

create or replace function public.kcp_random_code()
returns text language sql volatile as $$
    select string_agg(
        substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
               1 + floor(random() * 32)::integer, 1), '')
    from generate_series(1, 6);
$$;

commit;

begin;

-- ===========================================================================
-- kcp_plan_occurrences — the single source of truth for "who drives when".
--
-- Both the client preview and the publisher call this, so a previewed
-- schedule and a published schedule can never disagree.
-- ===========================================================================

create or replace function public.kcp_plan_occurrences(
    p_plan_id uuid,
    p_from date default null,
    p_to date default null,
    p_limit integer default 2000
)
returns table(
    service_date date,
    session_id uuid,
    session_name text,
    leg_type text,
    local_time time without time zone,
    day_offset smallint,
    scheduled_at timestamptz,
    display_label text,
    policy_id uuid,
    strategy text,
    block_key text,
    participant_id uuid,
    participant_name text,
    participant_user_id uuid
)
language plpgsql stable security definer
set search_path = public, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_plan public.kcp_schedule_plans;
    v_range_start date;
    v_range_end date;
begin
    select plan.* into v_plan
      from public.kcp_schedule_plans plan where plan.id = p_plan_id;
    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_member(v_plan.group_id) then
        raise exception 'Active group membership required';
    end if;

    v_range_start := coalesce(p_from, v_plan.starts_on);
    v_range_end   := coalesce(p_to,   v_plan.ends_on);
    if v_range_start is null or v_range_end is null
       or v_range_end < v_range_start then
        raise exception 'The plan needs a valid start and end date';
    end if;

    return query
    with plan_context as (
        select plan.*, grp.timezone as group_timezone
        from public.kcp_schedule_plans plan
        join public.kcp_groups grp on grp.id = plan.group_id
        where plan.id = p_plan_id
    ), service_dates as (
        select day::date as service_date
        from generate_series(v_range_start, v_range_end, interval '1 day') day
    ), matching_sessions as (
        select
            dates.service_date,
            session.id as session_id,
            session.name as session_name,
            session.outbound_enabled, session.outbound_time,
            session.return_enabled,   session.return_time,
            session.return_day_offset, session.display_order,
            coalesce(session.recurrence_anchor_date, context.starts_on)
                as recurrence_anchor_date,
            context.id as schedule_plan_id,
            context.group_id,
            coalesce(context.timezone, context.group_timezone, 'UTC') as tz,
            context.outbound_label, context.return_label
        from service_dates dates
        cross join plan_context context
        join public.kcp_recurring_sessions session
          on session.schedule_plan_id = context.id
         and session.status = 'active'
         and session.weekday = extract(isodow from dates.service_date)::integer
        where dates.service_date
              >= coalesce(session.recurrence_anchor_date, context.starts_on)
          and mod(
                floor((dates.service_date
                       - coalesce(session.recurrence_anchor_date,
                                  context.starts_on)) / 7.0)::integer,
                session.recurrence_interval_weeks) = 0
          -- Optional calendar closures remove service days entirely.
          and not exists (
              select 1
              from public.kcp_school_calendars cal
              join public.kcp_calendar_events ev on ev.calendar_id = cal.id
              where cal.group_id = context.group_id
                and ev.event_type = 'no_school'
                and dates.service_date between ev.start_date and ev.end_date)
          and not exists (
              select 1 from public.kcp_schedule_exceptions ex
              where ex.schedule_plan_id = context.id
                and ex.exception_date = dates.service_date
                and ex.action = 'skip'
                and (ex.session_id is null or ex.session_id = session.id))
    ), configured as (
        select
            s.*,
            policy.id as policy_id,
            coalesce(policy.strategy, 'manual') as strategy,
            coalesce(policy.cycle_behavior, 'calendar') as cycle_behavior,
            coalesce(policy.anchor_date, s.recurrence_anchor_date,
                     v_plan.starts_on) as policy_anchor_date,
            policy.fixed_participant_id,
            members.member_ids,
            times.replacement_outbound_time,
            times.replacement_return_time,
            driver.override_participant_id,
            exists (select 1 from public.kcp_schedule_exceptions ex
                    where ex.schedule_plan_id = s.schedule_plan_id
                      and ex.exception_date = s.service_date
                      and ex.action = 'outbound_only'
                      and (ex.session_id is null
                           or ex.session_id = s.session_id)) as outbound_only,
            exists (select 1 from public.kcp_schedule_exceptions ex
                    where ex.schedule_plan_id = s.schedule_plan_id
                      and ex.exception_date = s.service_date
                      and ex.action = 'return_only'
                      and (ex.session_id is null
                           or ex.session_id = s.session_id)) as return_only
        from matching_sessions s
        left join lateral (
            select cand.*
            from public.kcp_assignment_policies cand
            where cand.schedule_plan_id = s.schedule_plan_id
              and cand.status = 'active'
              and (not exists (select 1 from public.kcp_policy_sessions ps
                               where ps.policy_id = cand.id)
                   or exists (select 1 from public.kcp_policy_sessions ps
                              where ps.policy_id = cand.id
                                and ps.session_id = s.session_id))
            order by cand.priority desc, cand.id
            limit 1) policy on true
        left join lateral (
            select array_agg(m.participant_id order by m.rotation_position)
                     as member_ids
            from public.kcp_assignment_policy_members m
            where m.policy_id = policy.id and m.active) members on true
        left join lateral (
            select ex.replacement_outbound_time, ex.replacement_return_time
            from public.kcp_schedule_exceptions ex
            where ex.schedule_plan_id = s.schedule_plan_id
              and ex.exception_date = s.service_date
              and ex.action = 'change_time'
              and (ex.session_id is null or ex.session_id = s.session_id)
            order by ex.updated_at desc, ex.id desc limit 1) times on true
        left join lateral (
            select ex.override_participant_id
            from public.kcp_schedule_exceptions ex
            where ex.schedule_plan_id = s.schedule_plan_id
              and ex.exception_date = s.service_date
              and ex.action = 'change_driver'
              and ex.override_participant_id is not null
              and (ex.session_id is null or ex.session_id = s.session_id)
            order by ex.updated_at desc, ex.id desc limit 1) driver on true
    ), legs as (
        select c.service_date, c.session_id, c.session_name,
               'outbound'::text as leg_type,
               coalesce(c.replacement_outbound_time, c.outbound_time) as local_time,
               0::smallint as day_offset,
               c.outbound_label as display_label,
               c.display_order, 0 as leg_order, c.tz,
               c.policy_id, c.strategy, c.cycle_behavior, c.policy_anchor_date,
               c.fixed_participant_id, c.member_ids, c.override_participant_id
        from configured c
        where c.outbound_enabled and not c.return_only
        union all
        select c.service_date, c.session_id, c.session_name,
               'return'::text,
               coalesce(c.replacement_return_time, c.return_time),
               c.return_day_offset::smallint,
               c.return_label,
               c.display_order, 1, c.tz,
               c.policy_id, c.strategy, c.cycle_behavior, c.policy_anchor_date,
               c.fixed_participant_id, c.member_ids, c.override_participant_id
        from configured c
        where c.return_enabled and not c.outbound_only
    ), sequenced as (
        select leg.*,
            row_number() over (partition by leg.policy_id
                order by leg.service_date, leg.display_order,
                         leg.local_time, leg.leg_order, leg.session_id) - 1
                as trip_sequence,
            dense_rank() over (partition by leg.policy_id
                order by leg.service_date) - 1 as day_sequence,
            dense_rank() over (partition by leg.policy_id
                order by date_trunc('week', leg.service_date::timestamp)::date) - 1
                as occurrence_week_sequence,
            date_trunc('week', leg.service_date::timestamp)::date
                as service_week_start,
            date_trunc('week', leg.policy_anchor_date::timestamp)::date
                as anchor_week_start
        from legs leg
    ), assigned as (
        select q.*,
            case
                when q.override_participant_id is not null
                    then q.override_participant_id
                when q.strategy = 'manual' then null
                when q.strategy = 'fixed'
                    then coalesce(q.fixed_participant_id, q.member_ids[1])
                when coalesce(cardinality(q.member_ids), 0) = 0 then null
                when q.strategy = 'round_robin_week'
                    then q.member_ids[1 + ((
                        (case when q.cycle_behavior = 'occurrence'
                              then q.occurrence_week_sequence::integer
                              else floor((q.service_week_start
                                          - q.anchor_week_start) / 7.0)::integer
                         end % cardinality(q.member_ids))
                        + cardinality(q.member_ids)
                    ) % cardinality(q.member_ids))]
                when q.strategy = 'round_robin_day'
                    then q.member_ids[
                        1 + (q.day_sequence::integer
                             % cardinality(q.member_ids))]
                else q.member_ids[
                    1 + (q.trip_sequence::integer
                         % cardinality(q.member_ids))]
            end as assigned_participant_id,
            case
                when q.strategy = 'round_robin_week'
                    then concat('week:', q.policy_id, ':', q.service_week_start)
                when q.strategy = 'round_robin_day'
                    then concat('day:', q.policy_id, ':', q.service_date)
                when q.strategy = 'fixed'
                    then concat('fixed-day:', q.policy_id, ':', q.service_date)
                else concat('trip:', coalesce(q.policy_id::text, 'manual'), ':',
                            q.service_date, ':', q.session_id, ':', q.leg_type)
            end as responsibility_key
        from sequenced q
    )
    select
        a.service_date, a.session_id, a.session_name, a.leg_type,
        a.local_time, a.day_offset,
        make_timestamptz(
            extract(year  from (a.service_date + a.day_offset))::integer,
            extract(month from (a.service_date + a.day_offset))::integer,
            extract(day   from (a.service_date + a.day_offset))::integer,
            extract(hour  from a.local_time)::integer,
            extract(minute from a.local_time)::integer,
            extract(second from a.local_time)::double precision,
            a.tz) as scheduled_at,
        a.display_label, a.policy_id, a.strategy, a.responsibility_key,
        a.assigned_participant_id, participant.display_name, participant.user_id
    from assigned a
    left join public.kcp_group_participants participant
      on participant.id = a.assigned_participant_id
    order by scheduled_at, a.display_order, a.leg_order
    limit greatest(1, least(coalesce(p_limit, 2000), 5000));
end;
$$;

commit;

begin;

-- ===========================================================================
-- Publishing
-- ===========================================================================

create or replace function public.kcp_publish_schedule_plan(
    p_plan_id uuid,
    p_reason text default 'Schedule published'
) returns integer
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_plan public.kcp_schedule_plans;
    v_actor uuid;
    v_trip_count integer := 0;
begin
    select * into v_plan
      from public.kcp_schedule_plans where id = p_plan_id for update;
    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_admin(v_plan.group_id) then
        raise exception 'Owner or admin role required';
    end if;
    if v_plan.status <> 'draft' then
        raise exception 'Only a draft plan can be published';
    end if;
    if v_plan.starts_on is null or v_plan.ends_on is null then
        raise exception 'Set a start and end date before publishing';
    end if;
    if not exists (select 1 from public.kcp_recurring_sessions
                   where schedule_plan_id = p_plan_id and status = 'active') then
        raise exception 'Add at least one active session before publishing';
    end if;

    v_actor := public.kcp_current_participant_id(v_plan.group_id);

    -- Supersede the previous published plan. Its trips are retained for audit.
    update public.kcp_schedule_plans
       set status = 'superseded'
     where group_id = v_plan.group_id
       and status = 'published'
       and id <> p_plan_id;

    -- Materialise responsibility blocks from the occurrence engine.
    insert into public.kcp_responsibility_blocks(
        group_id, schedule_plan_id, policy_id, block_key,
        block_start, block_end, participant_id)
    select v_plan.group_id, p_plan_id, occ.policy_id, occ.block_key,
           min(occ.service_date), max(occ.service_date),
           -- Every leg in a block resolves to the same participant by
           -- construction; take the first deterministically.
           (array_agg(occ.participant_id
                      order by occ.service_date, occ.leg_type))[1]
    from public.kcp_plan_occurrences(p_plan_id, v_plan.starts_on,
                                     v_plan.ends_on, 5000) occ
    group by occ.policy_id, occ.block_key
    on conflict (schedule_plan_id, block_key) do update
        set participant_id = excluded.participant_id,
            block_start = excluded.block_start,
            block_end = excluded.block_end;

    insert into public.kcp_trips(
        group_id, schedule_plan_id, recurring_session_id,
        responsibility_block_id, trip_date, leg_type, display_label,
        scheduled_participant_id, status, scheduled_time, child_names)
    select
        v_plan.group_id, p_plan_id, occ.session_id, block.id,
        occ.service_date, occ.leg_type, occ.display_label,
        occ.participant_id, 'scheduled', occ.scheduled_at,
        coalesce((select array_agg(c.name order by c.name)
                  from public.kcp_children c
                  where c.group_id = v_plan.group_id
                    and c.status = 'active'), '{}')
    from public.kcp_plan_occurrences(p_plan_id, v_plan.starts_on,
                                     v_plan.ends_on, 5000) occ
    left join public.kcp_responsibility_blocks block
      on block.schedule_plan_id = p_plan_id
     and block.block_key = occ.block_key
    on conflict (schedule_plan_id, trip_date, recurring_session_id, leg_type)
    do update set
        scheduled_participant_id = excluded.scheduled_participant_id,
        scheduled_time = excluded.scheduled_time,
        display_label = excluded.display_label;

    get diagnostics v_trip_count = row_count;

    update public.kcp_schedule_plans
       set status = 'published',
           published_at = now(),
           published_by_participant_id = v_actor,
           reason = coalesce(p_reason, reason)
     where id = p_plan_id;

    update public.kcp_groups
       set active_schedule_plan_id = p_plan_id
     where id = v_plan.group_id;

    perform public.kcp_write_audit(
        v_plan.group_id, 'schedule.published', 'schedule_plan',
        p_plan_id::text,
        jsonb_build_object('version', v_plan.version, 'trips', v_trip_count));

    return v_trip_count;
end;
$$;

-- Create (or fetch) the group's editable draft, cloned from the live plan.
create or replace function public.kcp_get_or_create_draft_plan(p_group_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_draft uuid;
    v_source public.kcp_schedule_plans;
    v_next integer;
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or admin role required';
    end if;

    select id into v_draft from public.kcp_schedule_plans
     where group_id = p_group_id and status = 'draft';
    if v_draft is not null then
        return v_draft;
    end if;

    select * into v_source from public.kcp_schedule_plans
     where group_id = p_group_id and status = 'published';

    select coalesce(max(version), 0) + 1 into v_next
      from public.kcp_schedule_plans where group_id = p_group_id;

    insert into public.kcp_schedule_plans(
        group_id, version, name, status, starts_on, ends_on, timezone,
        outbound_label, return_label, auto_complete_after_minutes,
        created_by_participant_id)
    values (
        p_group_id, v_next,
        coalesce(v_source.name, 'Recurring schedule'), 'draft',
        v_source.starts_on, v_source.ends_on, v_source.timezone,
        coalesce(v_source.outbound_label, 'Drop-off'),
        coalesce(v_source.return_label, 'Pickup'),
        coalesce(v_source.auto_complete_after_minutes, 60),
        public.kcp_current_participant_id(p_group_id))
    returning id into v_draft;

    if v_source.id is not null then
        insert into public.kcp_recurring_sessions(
            schedule_plan_id, name, weekday, recurrence_interval_weeks,
            recurrence_anchor_date, outbound_enabled, outbound_time,
            return_enabled, return_time, return_day_offset,
            destination_override, display_order, status)
        select v_draft, name, weekday, recurrence_interval_weeks,
               recurrence_anchor_date, outbound_enabled, outbound_time,
               return_enabled, return_time, return_day_offset,
               destination_override, display_order, status
        from public.kcp_recurring_sessions
        where schedule_plan_id = v_source.id;
    end if;

    return v_draft;
end;
$$;

-- ===========================================================================
-- Trip lifecycle, cover and points
-- ===========================================================================

create or replace function public.kcp_can_start_trip_at(
    p_scheduled timestamptz, p_now timestamptz default now())
returns boolean
language sql immutable as $$
    select p_scheduled is not null
       and p_now >= p_scheduled - interval '30 minutes'
       and p_now <= p_scheduled + interval '4 hours';
$$;

create or replace function public.kcp_start_trip(p_trip_id uuid)
returns public.kcp_trips
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_trip public.kcp_trips;
    v_me uuid;
begin
    select * into v_trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;

    v_me := public.kcp_current_participant_id(v_trip.group_id);
    if v_me is null then raise exception 'Active group membership required'; end if;

    if v_me is distinct from coalesce(v_trip.actual_participant_id,
                                      v_trip.scheduled_participant_id)
       and not public.kcp_is_admin(v_trip.group_id) then
        raise exception 'Only the assigned driver or an admin can start this trip';
    end if;
    if v_trip.status <> 'scheduled' then
        raise exception 'Trip is not startable in status %', v_trip.status;
    end if;
    if not public.kcp_can_start_trip_at(v_trip.scheduled_time) then
        raise exception 'Trip can only be started near its scheduled time';
    end if;

    update public.kcp_trips
       set status = 'in_progress', started_at = now(),
           started_source = 'manual',
           actual_participant_id = coalesce(actual_participant_id, v_me)
     where id = p_trip_id
    returning * into v_trip;

    perform public.kcp_write_audit(v_trip.group_id, 'trip.started', 'trip',
                                   p_trip_id::text, '{}'::jsonb);
    return v_trip;
end;
$$;

create or replace function public.kcp_complete_trip(p_trip_id uuid)
returns public.kcp_trips
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_trip public.kcp_trips;
    v_me uuid;
    v_points integer;
begin
    select * into v_trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;

    v_me := public.kcp_current_participant_id(v_trip.group_id);
    if v_me is null then raise exception 'Active group membership required'; end if;
    if v_me is distinct from coalesce(v_trip.actual_participant_id,
                                      v_trip.scheduled_participant_id)
       and not public.kcp_is_admin(v_trip.group_id) then
        raise exception 'Only the driver or an admin can complete this trip';
    end if;
    if v_trip.status <> 'in_progress' then
        raise exception 'Start the trip before completing it';
    end if;

    update public.kcp_trips
       set status = 'completed', completed_at = now(),
           completed_source = 'manual'
     where id = p_trip_id
    returning * into v_trip;

    v_points := case when v_trip.volunteer_assignment then 20 else 10 end;

    insert into public.kcp_points_ledger(
        group_id, trip_id, participant_id, points, reason)
    values (v_trip.group_id, v_trip.id,
            coalesce(v_trip.actual_participant_id,
                     v_trip.scheduled_participant_id),
            v_points,
            case when v_trip.volunteer_assignment
                 then 'volunteer_trip_completed'
                 else 'trip_completed' end)
    on conflict (trip_id) where trip_id is not null do nothing;

    perform public.kcp_write_audit(v_trip.group_id, 'trip.completed', 'trip',
        p_trip_id::text, jsonb_build_object('points', v_points));
    return v_trip;
end;
$$;

create or replace function public.kcp_request_cover(
    p_trip_id uuid, p_note text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_trip public.kcp_trips;
    v_me uuid;
    v_id uuid;
begin
    select * into v_trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;

    v_me := public.kcp_current_participant_id(v_trip.group_id);
    if v_me is null then raise exception 'Active group membership required'; end if;
    if v_me is distinct from coalesce(v_trip.actual_participant_id,
                                      v_trip.scheduled_participant_id) then
        raise exception 'Only the assigned driver can request cover';
    end if;
    if v_trip.status <> 'scheduled' then
        raise exception 'Cover can only be requested for a scheduled trip';
    end if;

    insert into public.kcp_cover_requests(
        group_id, trip_id, requested_by, note)
    values (v_trip.group_id, p_trip_id, v_me, p_note)
    returning id into v_id;

    perform public.kcp_write_audit(v_trip.group_id, 'cover.requested',
                                   'trip', p_trip_id::text, '{}'::jsonb);
    return v_id;
end;
$$;

create or replace function public.kcp_accept_cover(p_request_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_req public.kcp_cover_requests;
    v_me uuid;
begin
    select * into v_req from public.kcp_cover_requests
     where id = p_request_id for update;
    if not found then raise exception 'Cover request not found'; end if;
    if v_req.status <> 'open' then
        raise exception 'This cover request is no longer open';
    end if;

    v_me := public.kcp_current_participant_id(v_req.group_id);
    if v_me is null then raise exception 'Active group membership required'; end if;
    if v_me = v_req.requested_by then
        raise exception 'You cannot cover your own trip';
    end if;

    update public.kcp_cover_requests
       set status = 'accepted', accepted_by = v_me, accepted_at = now()
     where id = p_request_id;

    update public.kcp_trips
       set actual_participant_id = v_me, volunteer_assignment = true
     where id = v_req.trip_id;

    perform public.kcp_write_audit(v_req.group_id, 'cover.accepted',
                                   'trip', v_req.trip_id::text, '{}'::jsonb);
    return v_req.trip_id;
end;
$$;

create or replace function public.kcp_withdraw_cover(
    p_request_id uuid, p_reason text default null)
returns void
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_req public.kcp_cover_requests;
    v_me uuid;
begin
    select * into v_req from public.kcp_cover_requests
     where id = p_request_id for update;
    if not found then raise exception 'Cover request not found'; end if;

    v_me := public.kcp_current_participant_id(v_req.group_id);
    if v_me is null then raise exception 'Active group membership required'; end if;
    if v_me not in (v_req.requested_by, coalesce(v_req.accepted_by, v_me))
       and not public.kcp_is_admin(v_req.group_id) then
        raise exception 'Not permitted to withdraw this cover request';
    end if;
    if v_req.status not in ('open','accepted') then
        raise exception 'This cover request is already closed';
    end if;

    update public.kcp_cover_requests
       set status = case when v_req.status = 'open' then 'cancelled'
                         else 'withdrawn' end,
           cancelled_by = v_me, cancelled_at = now(),
           cancellation_reason = p_reason
     where id = p_request_id;

    -- Responsibility falls back to the originally scheduled participant.
    update public.kcp_trips
       set actual_participant_id = null, volunteer_assignment = false
     where id = v_req.trip_id
       and status = 'scheduled';

    perform public.kcp_write_audit(v_req.group_id, 'cover.withdrawn',
                                   'trip', v_req.trip_id::text,
                                   jsonb_build_object('reason', p_reason));
end;
$$;

commit;

begin;

-- ===========================================================================
-- Group lifecycle, invitations, constraints
-- ===========================================================================

create or replace function public.kcp_upsert_profile(
    p_display_name text, p_phone text default null)
returns public.kcp_profiles
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare v_row public.kcp_profiles;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    insert into public.kcp_profiles(id, display_name, phone)
    values (auth.uid(), coalesce(nullif(trim(p_display_name),''),'Parent'), p_phone)
    on conflict (id) do update
        set display_name = coalesce(nullif(trim(p_display_name),''),
                                    public.kcp_profiles.display_name),
            phone = coalesce(p_phone, public.kcp_profiles.phone)
    returning * into v_row;
    return v_row;
end;
$$;

create or replace function public.kcp_create_group(
    p_name text,
    p_group_kind text default 'school',
    p_timezone text default 'America/Phoenix',
    p_school_name text default null,
    p_academic_year text default null
) returns public.kcp_groups
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_group public.kcp_groups;
    v_code text;
    v_participant uuid;
    v_attempt integer := 0;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    perform public.kcp_upsert_profile(
        coalesce((select display_name from public.kcp_profiles
                  where id = auth.uid()), 'Parent'));

    loop
        v_attempt := v_attempt + 1;
        v_code := public.kcp_random_code();
        exit when not exists (select 1 from public.kcp_groups where code = v_code);
        if v_attempt > 20 then
            raise exception 'Could not allocate a unique group code';
        end if;
    end loop;

    insert into public.kcp_groups(
        code, name, group_kind, timezone, school_name, academic_year, created_by)
    values (v_code, p_name, p_group_kind, p_timezone,
            p_school_name, p_academic_year, auth.uid())
    returning * into v_group;

    insert into public.kcp_group_participants(
        group_id, user_id, display_name, role, status, source, joined_at)
    values (v_group.id, auth.uid(),
            coalesce((select display_name from public.kcp_profiles
                      where id = auth.uid()), 'Parent'),
            'owner', 'active', 'creator', now())
    returning id into v_participant;

    -- Every group starts with an empty draft plan so the builder has a target.
    insert into public.kcp_schedule_plans(
        group_id, version, status, timezone, created_by_participant_id)
    values (v_group.id, 1, 'draft', p_timezone, v_participant);

    perform public.kcp_write_audit(v_group.id, 'group.created', 'group',
                                   v_group.id::text, '{}'::jsonb);
    return v_group;
end;
$$;

create or replace function public.kcp_create_invitation(
    p_group_id uuid,
    p_invited_name text,
    p_role text default 'parent',
    p_participant_id uuid default null
) returns public.kcp_invitations
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare v_row public.kcp_invitations;
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or admin role required';
    end if;
    insert into public.kcp_invitations(
        group_id, token, invited_name, role, participant_id, invited_by)
    values (p_group_id, encode(gen_random_bytes(24), 'hex'),
            p_invited_name, p_role, p_participant_id,
            public.kcp_current_participant_id(p_group_id))
    returning * into v_row;

    perform public.kcp_write_audit(p_group_id, 'invitation.created',
                                   'invitation', v_row.id::text, '{}'::jsonb);
    return v_row;
end;
$$;

create or replace function public.kcp_accept_invitation(
    p_token text, p_display_name text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_inv public.kcp_invitations;
    v_name text;
    v_participant uuid;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into v_inv from public.kcp_invitations
     where token = p_token for update;
    if not found then raise exception 'Invitation not found'; end if;
    if v_inv.status <> 'pending' then
        raise exception 'This invitation is no longer available';
    end if;
    if v_inv.expires_at < now() then
        update public.kcp_invitations set status = 'expired' where id = v_inv.id;
        raise exception 'This invitation has expired';
    end if;

    v_name := coalesce(nullif(trim(p_display_name), ''), v_inv.invited_name);
    perform public.kcp_upsert_profile(v_name);

    if v_inv.participant_id is not null then
        -- Claiming a pre-seeded roster slot: bind, never duplicate.
        update public.kcp_group_participants
           set user_id = auth.uid(), status = 'active',
               display_name = v_name, joined_at = coalesce(joined_at, now())
         where id = v_inv.participant_id
        returning id into v_participant;
    else
        insert into public.kcp_group_participants(
            group_id, user_id, display_name, role, status, source,
            invited_by, joined_at)
        values (v_inv.group_id, auth.uid(), v_name, v_inv.role, 'active',
                'invitation', v_inv.invited_by, now())
        on conflict (group_id, user_id) where user_id is not null
        do update set status = 'active'
        returning id into v_participant;
    end if;

    update public.kcp_invitations
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = v_inv.id;

    perform public.kcp_write_audit(v_inv.group_id, 'invitation.accepted',
                                   'invitation', v_inv.id::text, '{}'::jsonb);
    return v_inv.group_id;
end;
$$;

-- Owner transfer: atomic thanks to the deferred owner invariant.
create or replace function public.kcp_transfer_ownership(
    p_group_id uuid, p_to_participant_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare v_me uuid;
begin
    v_me := public.kcp_current_participant_id(p_group_id);
    if v_me is null or not exists (
        select 1 from public.kcp_group_participants
        where id = v_me and role = 'owner') then
        raise exception 'Only the current owner can transfer ownership';
    end if;

    update public.kcp_group_participants set role = 'admin' where id = v_me;
    update public.kcp_group_participants
       set role = 'owner', status = 'active'
     where id = p_to_participant_id and group_id = p_group_id;

    perform public.kcp_write_audit(p_group_id, 'group.ownership_transferred',
        'participant', p_to_participant_id::text, '{}'::jsonb);
end;
$$;

create or replace function public.kcp_submit_constraint_request(
    p_group_id uuid,
    p_drop_weekdays smallint[],
    p_pickup_weekdays smallint[],
    p_notes text default null
) returns uuid
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare
    v_me uuid;
    v_id uuid;
begin
    v_me := public.kcp_current_participant_id(p_group_id);
    if v_me is null then raise exception 'Active group membership required'; end if;

    delete from public.kcp_constraints
     where group_id = p_group_id and participant_id = v_me and status = 'pending';

    insert into public.kcp_constraints(
        group_id, participant_id, drop_weekdays, pickup_weekdays,
        notes, status, submitted_by)
    values (p_group_id, v_me, p_drop_weekdays, p_pickup_weekdays,
            p_notes, 'pending', v_me)
    returning id into v_id;

    perform public.kcp_write_audit(p_group_id, 'constraints.requested',
                                   'constraint', v_id::text, '{}'::jsonb);
    return v_id;
end;
$$;

create or replace function public.kcp_review_constraint_request(
    p_request_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare v_req public.kcp_constraints;
begin
    select * into v_req from public.kcp_constraints
     where id = p_request_id for update;
    if not found then raise exception 'Request not found'; end if;
    if not public.kcp_is_admin(v_req.group_id) then
        raise exception 'Owner or admin role required';
    end if;
    if v_req.status <> 'pending' then
        raise exception 'This request has already been reviewed';
    end if;

    if p_approve then
        update public.kcp_constraints
           set status = 'superseded'
         where group_id = v_req.group_id
           and participant_id = v_req.participant_id
           and status = 'approved';
    end if;

    update public.kcp_constraints
       set status = case when p_approve then 'approved' else 'rejected' end,
           reviewed_by = public.kcp_current_participant_id(v_req.group_id),
           review_note = p_note,
           reviewed_at = now(),
           version = 1 + coalesce((
               select max(version) from public.kcp_constraints prior
               where prior.group_id = v_req.group_id
                 and prior.participant_id = v_req.participant_id
                 and prior.status = 'superseded'), 0)
     where id = p_request_id;

    perform public.kcp_write_audit(v_req.group_id,
        case when p_approve then 'constraints.approved'
             else 'constraints.rejected' end,
        'constraint', p_request_id::text, '{}'::jsonb);
end;
$$;

create or replace function public.kcp_list_my_groups()
returns table(
    group_id uuid, code text, name text, group_kind text,
    role text, participant_id uuid, active_schedule_plan_id uuid)
language sql stable security definer
set search_path = public, pg_catalog
as $$
    select g.id, g.code, g.name, g.group_kind,
           p.role, p.id, g.active_schedule_plan_id
    from public.kcp_groups g
    join public.kcp_group_participants p on p.group_id = g.id
    where p.user_id = auth.uid() and p.status = 'active'
      and g.status = 'active'
    order by g.name;
$$;

commit;

begin;

-- ===========================================================================
-- Row Level Security
--
-- Reads are membership-scoped. Writes go through SECURITY DEFINER RPCs, so
-- direct-write policies are deliberately narrow.
-- ===========================================================================

do $$
declare t text;
begin
    foreach t in array array[
        'kcp_profiles','kcp_groups','kcp_group_participants','kcp_children',
        'kcp_invitations','kcp_constraints','kcp_school_calendars',
        'kcp_calendar_events','kcp_schedule_plans','kcp_recurring_sessions',
        'kcp_assignment_policies','kcp_policy_sessions',
        'kcp_assignment_policy_members','kcp_schedule_exceptions',
        'kcp_responsibility_blocks','kcp_trips','kcp_cover_requests',
        'kcp_points_ledger','kcp_audit_events'
    ] loop
        execute format('alter table public.%I enable row level security', t);
        execute format('alter table public.%I force row level security', t);
    end loop;
end;
$$;

-- Profiles: a user sees their own profile plus anyone sharing a group.
drop policy if exists kcp_profiles_read on public.kcp_profiles;
create policy kcp_profiles_read on public.kcp_profiles for select
    to authenticated using (
        id = auth.uid()
        or exists (
            select 1
            from public.kcp_group_participants mine
            join public.kcp_group_participants theirs
              on theirs.group_id = mine.group_id
            where mine.user_id = auth.uid() and mine.status = 'active'
              and theirs.user_id = public.kcp_profiles.id));

drop policy if exists kcp_profiles_write on public.kcp_profiles;
create policy kcp_profiles_write on public.kcp_profiles for update
    to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists kcp_groups_read on public.kcp_groups;
create policy kcp_groups_read on public.kcp_groups for select
    to authenticated using (public.kcp_is_member(id));

drop policy if exists kcp_groups_admin_update on public.kcp_groups;
create policy kcp_groups_admin_update on public.kcp_groups for update
    to authenticated using (public.kcp_is_admin(id))
    with check (public.kcp_is_admin(id));

-- Group-scoped tables: one read policy each, driven by kcp_is_member.
do $$
declare t text;
begin
    foreach t in array array[
        'kcp_group_participants','kcp_children','kcp_invitations',
        'kcp_constraints','kcp_school_calendars','kcp_schedule_plans',
        'kcp_responsibility_blocks','kcp_trips','kcp_cover_requests',
        'kcp_points_ledger','kcp_audit_events'
    ] loop
        execute format('drop policy if exists %I on public.%I',
                       t || '_read', t);
        execute format(
            'create policy %I on public.%I for select to authenticated
             using (public.kcp_is_member(group_id))', t || '_read', t);
    end loop;
end;
$$;

-- Plan-scoped tables inherit visibility from their plan's group.
do $$
declare t text;
begin
    foreach t in array array[
        'kcp_recurring_sessions','kcp_assignment_policies',
        'kcp_schedule_exceptions'
    ] loop
        execute format('drop policy if exists %I on public.%I',
                       t || '_read', t);
        execute format(
            'create policy %I on public.%I for select to authenticated
             using (exists (select 1 from public.kcp_schedule_plans plan
                            where plan.id = %I.schedule_plan_id
                              and public.kcp_is_member(plan.group_id)))',
            t || '_read', t, t);
        execute format('drop policy if exists %I on public.%I',
                       t || '_admin', t);
        execute format(
            'create policy %I on public.%I for all to authenticated
             using (exists (select 1 from public.kcp_schedule_plans plan
                            where plan.id = %I.schedule_plan_id
                              and public.kcp_is_admin(plan.group_id)))
             with check (exists (select 1 from public.kcp_schedule_plans plan
                            where plan.id = %I.schedule_plan_id
                              and public.kcp_is_admin(plan.group_id)))',
            t || '_admin', t, t, t);
    end loop;
end;
$$;

drop policy if exists kcp_calendar_events_read on public.kcp_calendar_events;
create policy kcp_calendar_events_read on public.kcp_calendar_events
    for select to authenticated using (exists (
        select 1 from public.kcp_school_calendars cal
        where cal.id = kcp_calendar_events.calendar_id
          and public.kcp_is_member(cal.group_id)));

drop policy if exists kcp_policy_sessions_read on public.kcp_policy_sessions;
create policy kcp_policy_sessions_read on public.kcp_policy_sessions
    for all to authenticated using (exists (
        select 1 from public.kcp_assignment_policies pol
        join public.kcp_schedule_plans plan on plan.id = pol.schedule_plan_id
        where pol.id = kcp_policy_sessions.policy_id
          and public.kcp_is_member(plan.group_id)))
    with check (exists (
        select 1 from public.kcp_assignment_policies pol
        join public.kcp_schedule_plans plan on plan.id = pol.schedule_plan_id
        where pol.id = kcp_policy_sessions.policy_id
          and public.kcp_is_admin(plan.group_id)));

drop policy if exists kcp_policy_members_read
    on public.kcp_assignment_policy_members;
create policy kcp_policy_members_read on public.kcp_assignment_policy_members
    for all to authenticated using (exists (
        select 1 from public.kcp_assignment_policies pol
        join public.kcp_schedule_plans plan on plan.id = pol.schedule_plan_id
        where pol.id = kcp_assignment_policy_members.policy_id
          and public.kcp_is_member(plan.group_id)))
    with check (exists (
        select 1 from public.kcp_assignment_policies pol
        join public.kcp_schedule_plans plan on plan.id = pol.schedule_plan_id
        where pol.id = kcp_assignment_policy_members.policy_id
          and public.kcp_is_admin(plan.group_id)));

-- Admins may edit plan metadata and roster rows directly; everything else
-- flows through RPCs.
drop policy if exists kcp_schedule_plans_admin on public.kcp_schedule_plans;
create policy kcp_schedule_plans_admin on public.kcp_schedule_plans
    for all to authenticated
    using (public.kcp_is_admin(group_id))
    with check (public.kcp_is_admin(group_id));

drop policy if exists kcp_participants_admin on public.kcp_group_participants;
create policy kcp_participants_admin on public.kcp_group_participants
    for all to authenticated
    using (public.kcp_is_admin(group_id))
    with check (public.kcp_is_admin(group_id));

drop policy if exists kcp_children_write on public.kcp_children;
create policy kcp_children_write on public.kcp_children
    for all to authenticated
    using (public.kcp_is_admin(group_id)
           or participant_id = public.kcp_current_participant_id(group_id))
    with check (public.kcp_is_admin(group_id)
           or participant_id = public.kcp_current_participant_id(group_id));

drop policy if exists kcp_calendars_admin on public.kcp_school_calendars;
create policy kcp_calendars_admin on public.kcp_school_calendars
    for all to authenticated
    using (public.kcp_is_admin(group_id))
    with check (public.kcp_is_admin(group_id));

drop policy if exists kcp_calendar_events_admin on public.kcp_calendar_events;
create policy kcp_calendar_events_admin on public.kcp_calendar_events
    for all to authenticated using (exists (
        select 1 from public.kcp_school_calendars cal
        where cal.id = kcp_calendar_events.calendar_id
          and public.kcp_is_admin(cal.group_id)))
    with check (exists (
        select 1 from public.kcp_school_calendars cal
        where cal.id = kcp_calendar_events.calendar_id
          and public.kcp_is_admin(cal.group_id)));

-- Anyone authenticated may look up an invitation by its unguessable token.
drop policy if exists kcp_invitations_token_read on public.kcp_invitations;
create policy kcp_invitations_token_read on public.kcp_invitations
    for select to authenticated using (true);

commit;

begin;
-- ===========================================================================
-- Grants: no direct table writes for anon; RPCs are the write surface.
-- ===========================================================================
revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
grant insert, update, delete on
    public.kcp_profiles, public.kcp_children, public.kcp_schedule_plans,
    public.kcp_recurring_sessions, public.kcp_assignment_policies,
    public.kcp_policy_sessions, public.kcp_assignment_policy_members,
    public.kcp_schedule_exceptions, public.kcp_school_calendars,
    public.kcp_calendar_events, public.kcp_group_participants
to authenticated;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
commit;
