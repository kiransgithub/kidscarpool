-- Kidscarpool (KCP) cloud pilot schema for Supabase.
-- Designed for a private MVP pilot using Supabase anonymous authentication.
-- All client-facing tables use RLS. Mutations that span multiple tables are
-- exposed through SECURITY DEFINER RPC functions that validate auth.uid().

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text not null check (length(trim(display_name)) between 1 and 80),
    phone text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.kcp_groups (
    id uuid primary key default gen_random_uuid(),
    code text not null unique,
    name text not null check (length(trim(name)) between 1 and 120),
    school_key text not null,
    school_name text not null,
    academic_year text not null,
    timezone text not null default 'America/Phoenix',
    status text not null default 'active' check (status in ('active','archived')),
    created_by uuid not null references public.kcp_profiles(id),
    current_schedule_version integer not null default 0,
    pilot_time_override boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.kcp_memberships (
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    user_id uuid not null references public.kcp_profiles(id) on delete cascade,
    parent_name text not null,
    phone text,
    child_name text not null,
    grade integer not null check (grade between 0 and 12),
    role text not null default 'parent' check (role in ('owner','admin','parent','viewer')),
    status text not null default 'active' check (status in ('invited','pending','active','suspended','removed')),
    invited_by uuid references public.kcp_profiles(id),
    joined_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (group_id, user_id)
);

create index if not exists kcp_memberships_user_idx
    on public.kcp_memberships(user_id, status);

create table if not exists public.kcp_invitations (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    token text not null unique,
    invited_parent_name text not null,
    phone text,
    child_name text not null,
    grade integer not null check (grade between 0 and 12),
    role text not null default 'parent' check (role in ('admin','parent','viewer')),
    status text not null default 'pending' check (status in ('pending','accepted','declined','expired','revoked')),
    invited_by uuid not null references public.kcp_profiles(id),
    accepted_by uuid references public.kcp_profiles(id),
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '14 days'),
    accepted_at timestamptz
);

create index if not exists kcp_invitations_group_idx
    on public.kcp_invitations(group_id, status);

create table if not exists public.kcp_constraints (
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    user_id uuid not null references public.kcp_profiles(id) on delete cascade,
    drop_weekdays smallint[] not null default array[1,2,3,4,5]::smallint[],
    pickup_weekdays smallint[] not null default array[1,2,3,4,5]::smallint[],
    notes text not null default '',
    version integer not null default 1,
    effective_from date,
    updated_by uuid not null references public.kcp_profiles(id),
    updated_at timestamptz not null default now(),
    primary key (group_id, user_id),
    check (drop_weekdays <@ array[1,2,3,4,5]::smallint[]),
    check (pickup_weekdays <@ array[1,2,3,4,5]::smallint[])
);

create table if not exists public.kcp_constraint_requests (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    user_id uuid not null references public.kcp_profiles(id) on delete cascade,
    previous_drop_weekdays smallint[] not null,
    previous_pickup_weekdays smallint[] not null,
    requested_drop_weekdays smallint[] not null,
    requested_pickup_weekdays smallint[] not null,
    notes text not null default '',
    status text not null default 'pending' check (status in ('pending','approved','rejected','withdrawn')),
    submitted_at timestamptz not null default now(),
    reviewed_at timestamptz,
    reviewed_by uuid references public.kcp_profiles(id),
    review_note text,
    base_version integer not null default 1,
    check (requested_drop_weekdays <@ array[1,2,3,4,5]::smallint[]),
    check (requested_pickup_weekdays <@ array[1,2,3,4,5]::smallint[])
);

create unique index if not exists kcp_one_pending_constraint_request
    on public.kcp_constraint_requests(group_id, user_id)
    where status = 'pending';

create table if not exists public.kcp_school_calendars (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    school_key text not null,
    school_name text not null,
    academic_year text not null,
    source_name text not null,
    source_sha256 text,
    source_file_size bigint,
    storage_path text,
    uploaded_by uuid not null references public.kcp_profiles(id),
    uploaded_at timestamptz not null default now(),
    unique (group_id, school_key, academic_year)
);

create table if not exists public.kcp_calendar_events (
    id uuid primary key default gen_random_uuid(),
    calendar_id uuid not null references public.kcp_school_calendars(id) on delete cascade,
    event_type text not null check (event_type in ('no_school','early_release','no_late_bird','project_week','first_day','last_day')),
    title text not null,
    start_date date not null,
    end_date date not null,
    notes text not null default '',
    check (end_date >= start_date)
);

create index if not exists kcp_calendar_events_calendar_idx
    on public.kcp_calendar_events(calendar_id, start_date);

create table if not exists public.kcp_schedule_versions (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    version integer not null,
    status text not null default 'published' check (status in ('draft','published','superseded')),
    reason text not null,
    generated_by uuid not null references public.kcp_profiles(id),
    generated_at timestamptz not null default now(),
    published_by uuid references public.kcp_profiles(id),
    published_at timestamptz,
    change_summary jsonb not null default '{}'::jsonb,
    unique (group_id, version)
);

create table if not exists public.kcp_trips (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    schedule_version integer not null,
    trip_date date not null,
    kind text not null check (kind in ('morning_drop','afternoon_pickup')),
    scheduled_driver_id uuid references public.kcp_profiles(id),
    actual_driver_id uuid references public.kcp_profiles(id),
    status text not null default 'scheduled' check (status in ('scheduled','coverage_needed','cover_requested','cover_accepted','in_progress','completed','cancelled')),
    scheduled_time timestamptz,
    time_label text not null,
    notes text not null default '',
    child_names text[] not null default '{}'::text[],
    started_at timestamptz,
    completed_at timestamptz,
    volunteer_assignment boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (group_id, schedule_version, trip_date, kind)
);

create index if not exists kcp_trips_active_idx
    on public.kcp_trips(group_id, schedule_version, trip_date, kind);

create table if not exists public.kcp_cover_requests (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    requested_by uuid not null references public.kcp_profiles(id),
    note text not null default '',
    status text not null default 'open' check (status in ('open','accepted','cancelled')),
    accepted_by uuid references public.kcp_profiles(id),
    created_at timestamptz not null default now(),
    accepted_at timestamptz
);

create unique index if not exists kcp_one_open_cover_per_trip
    on public.kcp_cover_requests(trip_id)
    where status = 'open';

create table if not exists public.kcp_points_ledger (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    user_id uuid not null references public.kcp_profiles(id),
    points integer not null check (points in (10,20)),
    reason text not null check (reason in ('scheduled_trip','volunteer_trip')),
    created_at timestamptz not null default now(),
    unique (trip_id)
);

create table if not exists public.kcp_audit_events (
    id bigint generated always as identity primary key,
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    actor_id uuid references public.kcp_profiles(id),
    action text not null,
    entity_type text not null,
    entity_id text not null,
    details jsonb not null default '{}'::jsonb,
    occurred_at timestamptz not null default now()
);

create index if not exists kcp_audit_group_idx
    on public.kcp_audit_events(group_id, occurred_at desc);

-- Preserves the existing native pilot's whole-group snapshot while the SwiftUI
-- app is migrated screen by screen. PWA screens use normalized tables.
create table if not exists public.kcp_group_snapshots (
    group_id uuid primary key references public.kcp_groups(id) on delete cascade,
    snapshot jsonb not null,
    updated_by uuid not null references public.kcp_profiles(id),
    updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

create or replace function public.kcp_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create or replace function public.kcp_forbid_audit_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    raise exception 'KCP audit history is append-only';
end;
$$;

drop trigger if exists kcp_profiles_touch on public.kcp_profiles;
create trigger kcp_profiles_touch
before update on public.kcp_profiles
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_groups_touch on public.kcp_groups;
create trigger kcp_groups_touch
before update on public.kcp_groups
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_trips_touch on public.kcp_trips;
create trigger kcp_trips_touch
before update on public.kcp_trips
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_audit_no_update on public.kcp_audit_events;
create trigger kcp_audit_no_update
before update or delete on public.kcp_audit_events
for each row execute function public.kcp_forbid_audit_mutation();

create or replace function public.kcp_is_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.kcp_memberships m
        where m.group_id = p_group_id
          and m.user_id = auth.uid()
          and m.status = 'active'
    );
$$;

create or replace function public.kcp_is_admin(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.kcp_memberships m
        where m.group_id = p_group_id
          and m.user_id = auth.uid()
          and m.status = 'active'
          and m.role in ('owner','admin')
    );
$$;

create or replace function public.kcp_storage_group_id(p_name text)
returns uuid
language plpgsql
immutable
set search_path = public
as $$
begin
    return split_part(p_name, '/', 1)::uuid;
exception when others then
    return null;
end;
$$;

create or replace function public.kcp_random_code(p_prefix text default 'KCP')
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
    candidate text;
begin
    loop
        candidate := upper(p_prefix || '-' || substr(encode(gen_random_bytes(6), 'hex'), 1, 10));
        exit when not exists (select 1 from public.kcp_groups where code = candidate);
    end loop;
    return candidate;
end;
$$;

create or replace function public.kcp_random_invite_token()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
    candidate text;
begin
    loop
        candidate := upper(substr(translate(encode(gen_random_bytes(8), 'base64'), '/+=', 'XYZ'), 1, 8));
        exit when not exists (select 1 from public.kcp_invitations where token = candidate);
    end loop;
    return candidate;
end;
$$;

create or replace function public.kcp_write_audit(
    p_group_id uuid,
    p_action text,
    p_entity_type text,
    p_entity_id text,
    p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.kcp_audit_events(group_id, actor_id, action, entity_type, entity_id, details)
    values (p_group_id, auth.uid(), p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.kcp_profiles enable row level security;
alter table public.kcp_groups enable row level security;
alter table public.kcp_memberships enable row level security;
alter table public.kcp_invitations enable row level security;
alter table public.kcp_constraints enable row level security;
alter table public.kcp_constraint_requests enable row level security;
alter table public.kcp_school_calendars enable row level security;
alter table public.kcp_calendar_events enable row level security;
alter table public.kcp_schedule_versions enable row level security;
alter table public.kcp_trips enable row level security;
alter table public.kcp_cover_requests enable row level security;
alter table public.kcp_points_ledger enable row level security;
alter table public.kcp_audit_events enable row level security;
alter table public.kcp_group_snapshots enable row level security;

-- Recreate policies so the migration is idempotent.
drop policy if exists kcp_profiles_self_or_group on public.kcp_profiles;
create policy kcp_profiles_self_or_group
on public.kcp_profiles for select to authenticated
using (
    id = auth.uid()
    or exists (
        select 1
        from public.kcp_memberships mine
        join public.kcp_memberships theirs on theirs.group_id = mine.group_id
        where mine.user_id = auth.uid()
          and mine.status = 'active'
          and theirs.user_id = kcp_profiles.id
          and theirs.status = 'active'
    )
);

drop policy if exists kcp_profiles_self_update on public.kcp_profiles;
create policy kcp_profiles_self_update
on public.kcp_profiles for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists kcp_groups_member_select on public.kcp_groups;
create policy kcp_groups_member_select
on public.kcp_groups for select to authenticated
using (public.kcp_is_member(id));

drop policy if exists kcp_memberships_group_select on public.kcp_memberships;
create policy kcp_memberships_group_select
on public.kcp_memberships for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_invitations_admin_select on public.kcp_invitations;
create policy kcp_invitations_admin_select
on public.kcp_invitations for select to authenticated
using (public.kcp_is_admin(group_id) or accepted_by = auth.uid());

drop policy if exists kcp_constraints_group_select on public.kcp_constraints;
create policy kcp_constraints_group_select
on public.kcp_constraints for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_constraint_requests_group_select on public.kcp_constraint_requests;
create policy kcp_constraint_requests_group_select
on public.kcp_constraint_requests for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_calendars_group_select on public.kcp_school_calendars;
create policy kcp_calendars_group_select
on public.kcp_school_calendars for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_calendar_events_group_select on public.kcp_calendar_events;
create policy kcp_calendar_events_group_select
on public.kcp_calendar_events for select to authenticated
using (
    exists (
        select 1 from public.kcp_school_calendars c
        where c.id = calendar_id and public.kcp_is_member(c.group_id)
    )
);

drop policy if exists kcp_schedule_versions_group_select on public.kcp_schedule_versions;
create policy kcp_schedule_versions_group_select
on public.kcp_schedule_versions for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_trips_group_select on public.kcp_trips;
create policy kcp_trips_group_select
on public.kcp_trips for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_cover_group_select on public.kcp_cover_requests;
create policy kcp_cover_group_select
on public.kcp_cover_requests for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_points_group_select on public.kcp_points_ledger;
create policy kcp_points_group_select
on public.kcp_points_ledger for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_audit_group_select on public.kcp_audit_events;
create policy kcp_audit_group_select
on public.kcp_audit_events for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_snapshots_group_select on public.kcp_group_snapshots;
create policy kcp_snapshots_group_select
on public.kcp_group_snapshots for select to authenticated
using (public.kcp_is_member(group_id));


commit;
