begin;

-- ---------------------------------------------------------------------------
-- Generic scheduling foundation
--
-- The operational schedule is no longer encoded in group-level weekday/time
-- columns. A group owns versioned schedule plans; each plan owns recurring
-- sessions and one or more data-driven assignment policies. Generated trips
-- keep compatibility columns while also pointing to stable participant IDs.
-- ---------------------------------------------------------------------------

-- Existing groups may still use these policies. New generic plans use the
-- generic_plan compatibility value until the legacy dispatcher is removed.
do $$
begin
    if exists (
        select 1
        from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_schedule_policy_check'
    ) then
        alter table public.kcp_groups
            drop constraint kcp_groups_schedule_policy_check;
    end if;

    alter table public.kcp_groups
        add constraint kcp_groups_schedule_policy_check
        check (schedule_policy in (
            'balanced_constraints',
            'fixed_weekday_friday_rotation',
            'generic_plan'
        ));
end;
$$;

-- Repair any historical group that has a creator but no active owner before
-- enforcing the one-owner invariant.
update public.kcp_memberships m
   set role = 'owner',
       updated_at = now()
  from public.kcp_groups g
 where g.id = m.group_id
   and g.created_by = m.user_id
   and m.status = 'active'
   and not exists (
       select 1
       from public.kcp_memberships existing_owner
       where existing_owner.group_id = g.id
         and existing_owner.status = 'active'
         and existing_owner.role = 'owner'
   );

-- If experimental data accidentally created multiple owners, preserve the
-- creator as owner when possible and demote the others to admin.
with ranked_owners as (
    select
        m.group_id,
        m.user_id,
        row_number() over (
            partition by m.group_id
            order by
                case when m.user_id = g.created_by then 0 else 1 end,
                coalesce(m.joined_at, m.updated_at),
                m.user_id
        ) as owner_rank
    from public.kcp_memberships m
    join public.kcp_groups g on g.id = m.group_id
    where m.status = 'active'
      and m.role = 'owner'
)
update public.kcp_memberships m
   set role = 'admin',
       updated_at = now()
  from ranked_owners ranked
 where m.group_id = ranked.group_id
   and m.user_id = ranked.user_id
   and ranked.owner_rank > 1;

create unique index if not exists kcp_one_active_owner_per_group
    on public.kcp_memberships(group_id)
    where role = 'owner' and status = 'active';

create table if not exists public.kcp_group_participants (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    user_id uuid references public.kcp_profiles(id) on delete set null,
    display_name text not null check (length(trim(display_name)) between 1 and 80),
    can_drive boolean not null default true,
    status text not null default 'active'
        check (status in ('invited','active','inactive','removed')),
    source text not null default 'membership'
        check (source in ('membership','invitation','roster','admin')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists kcp_participant_user_per_group
    on public.kcp_group_participants(group_id, user_id)
    where user_id is not null;

create index if not exists kcp_participants_group_status_idx
    on public.kcp_group_participants(group_id, status, can_drive);

create table if not exists public.kcp_children (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    participant_id uuid not null references public.kcp_group_participants(id) on delete cascade,
    name text not null check (length(trim(name)) between 1 and 80),
    grade_or_level text,
    legacy_grade integer check (legacy_grade is null or legacy_grade between 0 and 12),
    pickup_tag text,
    status text not null default 'active'
        check (status in ('active','inactive')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (group_id, participant_id, name)
);

create table if not exists public.kcp_schedule_plans (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    version integer not null,
    name text not null default 'Recurring schedule',
    status text not null default 'draft'
        check (status in ('draft','published','superseded','archived')),
    starts_on date,
    ends_on date,
    timezone text not null default 'America/Phoenix',
    outbound_label text not null default 'Drop-off',
    return_label text not null default 'Pickup',
    auto_complete_after_minutes integer not null default 60
        check (auto_complete_after_minutes between 5 and 480),
    created_by_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    published_by_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    published_at timestamptz,
    check (starts_on is null or ends_on is null or ends_on >= starts_on),
    unique (group_id, version)
);

alter table public.kcp_groups
    add column if not exists active_schedule_plan_id uuid;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_active_schedule_plan_fk'
    ) then
        alter table public.kcp_groups
            add constraint kcp_groups_active_schedule_plan_fk
            foreign key (active_schedule_plan_id)
            references public.kcp_schedule_plans(id)
            on delete set null;
    end if;
end;
$$;

create table if not exists public.kcp_recurring_sessions (
    id uuid primary key default gen_random_uuid(),
    schedule_plan_id uuid not null references public.kcp_schedule_plans(id) on delete cascade,
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

create table if not exists public.kcp_assignment_policies (
    id uuid primary key default gen_random_uuid(),
    schedule_plan_id uuid not null references public.kcp_schedule_plans(id) on delete cascade,
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
    fixed_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    priority integer not null default 100,
    status text not null default 'active'
        check (status in ('active','inactive')),
    config jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists kcp_policies_plan_priority_idx
    on public.kcp_assignment_policies(schedule_plan_id, status, priority desc);

create table if not exists public.kcp_policy_sessions (
    policy_id uuid not null references public.kcp_assignment_policies(id) on delete cascade,
    session_id uuid not null references public.kcp_recurring_sessions(id) on delete cascade,
    primary key (policy_id, session_id)
);

create table if not exists public.kcp_assignment_policy_members (
    policy_id uuid not null references public.kcp_assignment_policies(id) on delete cascade,
    participant_id uuid not null references public.kcp_group_participants(id) on delete cascade,
    rotation_position integer not null check (rotation_position > 0),
    weight integer not null default 1 check (weight between 1 and 20),
    active boolean not null default true,
    primary key (policy_id, participant_id),
    unique (policy_id, rotation_position)
);

create table if not exists public.kcp_schedule_exceptions (
    id uuid primary key default gen_random_uuid(),
    schedule_plan_id uuid not null references public.kcp_schedule_plans(id) on delete cascade,
    session_id uuid references public.kcp_recurring_sessions(id) on delete cascade,
    exception_date date not null,
    action text not null
        check (action in (
            'skip',
            'change_time',
            'change_driver',
            'outbound_only',
            'return_only'
        )),
    replacement_outbound_time time without time zone,
    replacement_return_time time without time zone,
    override_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    reason text not null default '',
    created_by_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists kcp_schedule_exception_identity
    on public.kcp_schedule_exceptions(
        schedule_plan_id,
        exception_date,
        coalesce(session_id, '00000000-0000-0000-0000-000000000000'::uuid),
        action
    );

create table if not exists public.kcp_responsibility_blocks (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    schedule_plan_id uuid not null references public.kcp_schedule_plans(id) on delete cascade,
    schedule_version integer not null,
    policy_id uuid references public.kcp_assignment_policies(id) on delete set null,
    block_key text not null,
    block_start date not null,
    block_end date not null,
    participant_id uuid references public.kcp_group_participants(id) on delete set null,
    status text not null default 'assigned'
        check (status in ('assigned','coverage_needed','completed','cancelled')),
    created_at timestamptz not null default now(),
    check (block_end >= block_start),
    unique (schedule_plan_id, schedule_version, policy_id, block_key)
);

alter table public.kcp_trips
    add column if not exists schedule_plan_id uuid references public.kcp_schedule_plans(id) on delete set null;

alter table public.kcp_trips
    add column if not exists recurring_session_id uuid references public.kcp_recurring_sessions(id) on delete set null;

alter table public.kcp_trips
    add column if not exists responsibility_block_id uuid references public.kcp_responsibility_blocks(id) on delete set null;

alter table public.kcp_trips
    add column if not exists scheduled_participant_id uuid references public.kcp_group_participants(id) on delete set null;

alter table public.kcp_trips
    add column if not exists actual_participant_id uuid references public.kcp_group_participants(id) on delete set null;

alter table public.kcp_trips
    add column if not exists leg_type text;

alter table public.kcp_trips
    add column if not exists display_label text;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.kcp_trips'::regclass
          and conname = 'kcp_trips_leg_type_check'
    ) then
        alter table public.kcp_trips
            add constraint kcp_trips_leg_type_check
            check (leg_type is null or leg_type in ('outbound','return'));
    end if;
end;
$$;

-- The legacy unique constraint prevented more than one outbound or return trip
-- on the same date. Replace it with partial identities for legacy and generic
-- records so multiple classes or practices on one day are supported.
do $$
declare
    constraint_record record;
begin
    for constraint_record in
        select c.conname
        from pg_constraint c
        where c.conrelid = 'public.kcp_trips'::regclass
          and c.contype = 'u'
          and pg_get_constraintdef(c.oid) ilike '%group_id%'
          and pg_get_constraintdef(c.oid) ilike '%schedule_version%'
          and pg_get_constraintdef(c.oid) ilike '%trip_date%'
          and pg_get_constraintdef(c.oid) ilike '%kind%'
    loop
        execute format(
            'alter table public.kcp_trips drop constraint %I',
            constraint_record.conname
        );
    end loop;
end;
$$;

create unique index if not exists kcp_trips_legacy_identity
    on public.kcp_trips(group_id, schedule_version, trip_date, kind)
    where recurring_session_id is null;

create unique index if not exists kcp_trips_generic_identity
    on public.kcp_trips(
        group_id,
        schedule_version,
        trip_date,
        recurring_session_id,
        leg_type
    )
    where recurring_session_id is not null;

-- ---------------------------------------------------------------------------
-- RLS and read policies. Mutations are performed through validated RPCs.
-- ---------------------------------------------------------------------------

alter table public.kcp_group_participants enable row level security;
alter table public.kcp_children enable row level security;
alter table public.kcp_schedule_plans enable row level security;
alter table public.kcp_recurring_sessions enable row level security;
alter table public.kcp_assignment_policies enable row level security;
alter table public.kcp_policy_sessions enable row level security;
alter table public.kcp_assignment_policy_members enable row level security;
alter table public.kcp_schedule_exceptions enable row level security;
alter table public.kcp_responsibility_blocks enable row level security;

drop policy if exists kcp_participants_member_select on public.kcp_group_participants;
create policy kcp_participants_member_select
on public.kcp_group_participants for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_children_member_select on public.kcp_children;
create policy kcp_children_member_select
on public.kcp_children for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_plans_member_select on public.kcp_schedule_plans;
create policy kcp_plans_member_select
on public.kcp_schedule_plans for select to authenticated
using (public.kcp_is_member(group_id));

drop policy if exists kcp_sessions_member_select on public.kcp_recurring_sessions;
create policy kcp_sessions_member_select
on public.kcp_recurring_sessions for select to authenticated
using (
    exists (
        select 1
        from public.kcp_schedule_plans plan
        where plan.id = schedule_plan_id
          and public.kcp_is_member(plan.group_id)
    )
);

drop policy if exists kcp_policies_member_select on public.kcp_assignment_policies;
create policy kcp_policies_member_select
on public.kcp_assignment_policies for select to authenticated
using (
    exists (
        select 1
        from public.kcp_schedule_plans plan
        where plan.id = schedule_plan_id
          and public.kcp_is_member(plan.group_id)
    )
);

drop policy if exists kcp_policy_sessions_member_select on public.kcp_policy_sessions;
create policy kcp_policy_sessions_member_select
on public.kcp_policy_sessions for select to authenticated
using (
    exists (
        select 1
        from public.kcp_assignment_policies policy
        join public.kcp_schedule_plans plan on plan.id = policy.schedule_plan_id
        where policy.id = policy_id
          and public.kcp_is_member(plan.group_id)
    )
);

drop policy if exists kcp_policy_members_member_select on public.kcp_assignment_policy_members;
create policy kcp_policy_members_member_select
on public.kcp_assignment_policy_members for select to authenticated
using (
    exists (
        select 1
        from public.kcp_assignment_policies policy
        join public.kcp_schedule_plans plan on plan.id = policy.schedule_plan_id
        where policy.id = policy_id
          and public.kcp_is_member(plan.group_id)
    )
);

drop policy if exists kcp_exceptions_member_select on public.kcp_schedule_exceptions;
create policy kcp_exceptions_member_select
on public.kcp_schedule_exceptions for select to authenticated
using (
    exists (
        select 1
        from public.kcp_schedule_plans plan
        where plan.id = schedule_plan_id
          and public.kcp_is_member(plan.group_id)
    )
);

drop policy if exists kcp_blocks_member_select on public.kcp_responsibility_blocks;
create policy kcp_blocks_member_select
on public.kcp_responsibility_blocks for select to authenticated
using (public.kcp_is_member(group_id));

revoke all on public.kcp_group_participants from public, anon;
revoke all on public.kcp_children from public, anon;
revoke all on public.kcp_schedule_plans from public, anon;
revoke all on public.kcp_recurring_sessions from public, anon;
revoke all on public.kcp_assignment_policies from public, anon;
revoke all on public.kcp_policy_sessions from public, anon;
revoke all on public.kcp_assignment_policy_members from public, anon;
revoke all on public.kcp_schedule_exceptions from public, anon;
revoke all on public.kcp_responsibility_blocks from public, anon;

grant select on public.kcp_group_participants to authenticated;
grant select on public.kcp_children to authenticated;
grant select on public.kcp_schedule_plans to authenticated;
grant select on public.kcp_recurring_sessions to authenticated;
grant select on public.kcp_assignment_policies to authenticated;
grant select on public.kcp_policy_sessions to authenticated;
grant select on public.kcp_assignment_policy_members to authenticated;
grant select on public.kcp_schedule_exceptions to authenticated;
grant select on public.kcp_responsibility_blocks to authenticated;

-- ---------------------------------------------------------------------------
-- Stable participant identity and membership synchronization
-- ---------------------------------------------------------------------------

create or replace function public.kcp_sync_participant_from_membership()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    participant_record public.kcp_group_participants;
    prior_participant public.kcp_group_participants;
begin
    if new.status <> 'active' then
        return new;
    end if;

    select participant.*
      into participant_record
      from public.kcp_group_participants participant
     where participant.group_id = new.group_id
       and participant.user_id = new.user_id
     limit 1;

    if participant_record.id is null then
        -- During anonymous-account recovery, reuse the stable participant row
        -- linked to the removed membership with the same operational identity.
        select participant.*
          into prior_participant
          from public.kcp_group_participants participant
          join public.kcp_memberships old_membership
            on old_membership.group_id = participant.group_id
           and old_membership.user_id = participant.user_id
         where participant.group_id = new.group_id
           and old_membership.status = 'removed'
           and lower(participant.display_name) = lower(new.parent_name)
         order by participant.updated_at desc
         limit 1;

        if prior_participant.id is not null then
            update public.kcp_group_participants
               set user_id = new.user_id,
                   display_name = new.parent_name,
                   can_drive = new.role <> 'viewer',
                   status = 'active',
                   source = 'membership',
                   updated_at = now()
             where id = prior_participant.id
             returning * into participant_record;
        else
            insert into public.kcp_group_participants(
                group_id, user_id, display_name, can_drive, status, source
            ) values (
                new.group_id,
                new.user_id,
                new.parent_name,
                new.role <> 'viewer',
                'active',
                'membership'
            )
            returning * into participant_record;
        end if;
    else
        update public.kcp_group_participants
           set display_name = new.parent_name,
               can_drive = new.role <> 'viewer',
               status = 'active',
               updated_at = now()
         where id = participant_record.id
         returning * into participant_record;
    end if;

    if nullif(trim(new.child_name), '') is not null then
        insert into public.kcp_children(
            group_id,
            participant_id,
            name,
            grade_or_level,
            legacy_grade,
            status
        ) values (
            new.group_id,
            participant_record.id,
            trim(new.child_name),
            case when new.grade is null then null else new.grade::text end,
            new.grade,
            'active'
        )
        on conflict (group_id, participant_id, name) do update
           set grade_or_level = excluded.grade_or_level,
               legacy_grade = excluded.legacy_grade,
               status = 'active',
               updated_at = now();
    end if;

    return new;
end;
$$;

create or replace function public.kcp_sync_trip_driver_from_participant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if old.user_id is distinct from new.user_id then
        update public.kcp_trips
           set scheduled_driver_id = new.user_id,
               scheduled_driver_name = new.display_name,
               status = case
                   when status = 'coverage_needed'
                    and scheduled_time is not null
                    and scheduled_time >= now()
                   then 'scheduled'
                   else status
               end,
               updated_at = now()
         where scheduled_participant_id = new.id;

        update public.kcp_trips
           set actual_driver_id = new.user_id,
               actual_driver_name = new.display_name,
               updated_at = now()
         where actual_participant_id = new.id;
    end if;

    return new;
end;
$$;

drop trigger if exists kcp_membership_sync_participant
on public.kcp_memberships;

create trigger kcp_membership_sync_participant
after insert or update of parent_name, child_name, grade, role, status, user_id
on public.kcp_memberships
for each row
execute function public.kcp_sync_participant_from_membership();

drop trigger if exists kcp_participant_sync_trip_driver
on public.kcp_group_participants;

create trigger kcp_participant_sync_trip_driver
after update of user_id, display_name
on public.kcp_group_participants
for each row
execute function public.kcp_sync_trip_driver_from_participant();

-- Reuse the existing updated-at trigger function on the generic tables.
drop trigger if exists kcp_participants_touch on public.kcp_group_participants;
create trigger kcp_participants_touch
before update on public.kcp_group_participants
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_children_touch on public.kcp_children;
create trigger kcp_children_touch
before update on public.kcp_children
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_schedule_plans_touch on public.kcp_schedule_plans;
create trigger kcp_schedule_plans_touch
before update on public.kcp_schedule_plans
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_sessions_touch on public.kcp_recurring_sessions;
create trigger kcp_sessions_touch
before update on public.kcp_recurring_sessions
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_policies_touch on public.kcp_assignment_policies;
create trigger kcp_policies_touch
before update on public.kcp_assignment_policies
for each row execute function public.kcp_touch_updated_at();

drop trigger if exists kcp_exceptions_touch on public.kcp_schedule_exceptions;
create trigger kcp_exceptions_touch
before update on public.kcp_schedule_exceptions
for each row execute function public.kcp_touch_updated_at();

-- Backfill stable participants and children from existing memberships.
insert into public.kcp_group_participants(
    group_id, user_id, display_name, can_drive, status, source
)
select
    membership.group_id,
    membership.user_id,
    membership.parent_name,
    membership.role <> 'viewer',
    case when membership.status = 'active' then 'active' else 'inactive' end,
    'membership'
from public.kcp_memberships membership
where not exists (
    select 1
    from public.kcp_group_participants participant
    where participant.group_id = membership.group_id
      and participant.user_id = membership.user_id
);

insert into public.kcp_group_participants(
    group_id, user_id, display_name, can_drive, status, source
)
select
    roster.group_id,
    roster.claimed_user_id,
    roster.parent_name,
    true,
    case when roster.claimed_user_id is null then 'invited' else 'active' end,
    'roster'
from public.kcp_roster_slots roster
where not exists (
    select 1
    from public.kcp_group_participants participant
    where participant.group_id = roster.group_id
      and (
          participant.user_id = roster.claimed_user_id
          or lower(participant.display_name) = lower(roster.parent_name)
      )
);

insert into public.kcp_children(
    group_id, participant_id, name, grade_or_level, legacy_grade, pickup_tag
)
select
    membership.group_id,
    participant.id,
    membership.child_name,
    membership.grade::text,
    membership.grade,
    roster.pickup_tag
from public.kcp_memberships membership
join public.kcp_group_participants participant
  on participant.group_id = membership.group_id
 and participant.user_id = membership.user_id
left join public.kcp_roster_slots roster
  on roster.group_id = membership.group_id
 and lower(roster.child_name) = lower(membership.child_name)
where nullif(trim(membership.child_name), '') is not null
on conflict (group_id, participant_id, name) do update
   set grade_or_level = excluded.grade_or_level,
       legacy_grade = excluded.legacy_grade,
       pickup_tag = coalesce(excluded.pickup_tag, public.kcp_children.pickup_tag),
       updated_at = now();

insert into public.kcp_children(
    group_id, participant_id, name, grade_or_level, legacy_grade, pickup_tag
)
select
    roster.group_id,
    participant.id,
    roster.child_name,
    roster.grade::text,
    roster.grade,
    roster.pickup_tag
from public.kcp_roster_slots roster
join public.kcp_group_participants participant
  on participant.group_id = roster.group_id
 and lower(participant.display_name) = lower(roster.parent_name)
where nullif(trim(roster.child_name), '') is not null
on conflict (group_id, participant_id, name) do update
   set grade_or_level = excluded.grade_or_level,
       legacy_grade = excluded.legacy_grade,
       pickup_tag = coalesce(excluded.pickup_tag, public.kcp_children.pickup_tag),
       updated_at = now();

update public.kcp_trips trip
   set scheduled_participant_id = participant.id,
       scheduled_driver_name = coalesce(trip.scheduled_driver_name, participant.display_name)
  from public.kcp_group_participants participant
 where trip.scheduled_participant_id is null
   and participant.group_id = trip.group_id
   and (
       participant.user_id = trip.scheduled_driver_id
       or (
           trip.scheduled_driver_id is null
           and lower(participant.display_name) = lower(trip.scheduled_driver_name)
       )
   );

update public.kcp_trips trip
   set actual_participant_id = participant.id,
       actual_driver_name = coalesce(trip.actual_driver_name, participant.display_name)
  from public.kcp_group_participants participant
 where trip.actual_participant_id is null
   and participant.group_id = trip.group_id
   and (
       participant.user_id = trip.actual_driver_id
       or (
           trip.actual_driver_id is null
           and trip.actual_driver_name is not null
           and lower(participant.display_name) = lower(trip.actual_driver_name)
       )
   );

-- ---------------------------------------------------------------------------
-- Helper functions and atomic generic group creation
-- ---------------------------------------------------------------------------

create or replace function public.kcp_current_participant_id(p_group_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select participant.id
    from public.kcp_group_participants participant
    where participant.group_id = p_group_id
      and participant.user_id = auth.uid()
      and participant.status = 'active'
    limit 1;
$$;

create or replace function public.kcp_create_group_v3(
    p_name text,
    p_group_kind text,
    p_destination_name text,
    p_term_label text,
    p_timezone text,
    p_child_name text,
    p_grade_or_level text default null
)
returns table(
    group_id uuid,
    group_code text,
    owner_participant_id uuid,
    draft_plan_id uuid
)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    profile_record public.kcp_profiles;
    group_record public.kcp_groups;
    participant_record public.kcp_group_participants;
    plan_record public.kcp_schedule_plans;
    normalized_kind text := lower(trim(p_group_kind));
    legacy_grade integer;
    outbound_label_value text;
    return_label_value text;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    select profile.*
      into profile_record
      from public.kcp_profiles profile
     where profile.id = auth.uid();
    if not found then
        raise exception 'Complete your parent profile first';
    end if;

    if normalized_kind not in (
        'school','club','training','music','gymnastics','tennis','other'
    ) then
        raise exception 'Choose a valid carpool group type';
    end if;

    if nullif(trim(p_name), '') is null then
        raise exception 'Group name is required';
    end if;

    if nullif(trim(p_destination_name), '') is null then
        raise exception 'Destination or activity name is required';
    end if;

    if nullif(trim(p_child_name), '') is null then
        raise exception 'Child or rider name is required';
    end if;

    begin
        legacy_grade := nullif(regexp_replace(coalesce(p_grade_or_level,''), '[^0-9]', '', 'g'), '')::integer;
        if legacy_grade not between 0 and 12 then
            legacy_grade := 0;
        end if;
    exception when others then
        legacy_grade := 0;
    end;

    outbound_label_value := case normalized_kind
        when 'school' then 'School drop-off'
        when 'music' then 'Class drop-off'
        when 'tennis' then 'Practice drop-off'
        when 'training' then 'Training drop-off'
        when 'gymnastics' then 'Class drop-off'
        when 'club' then 'Club drop-off'
        else 'Outbound'
    end;

    return_label_value := case normalized_kind
        when 'school' then 'School pickup'
        when 'music' then 'Class pickup'
        when 'tennis' then 'Practice pickup'
        when 'training' then 'Training pickup'
        when 'gymnastics' then 'Class pickup'
        when 'club' then 'Club pickup'
        else 'Return'
    end;

    insert into public.kcp_groups(
        code,
        name,
        school_key,
        school_name,
        academic_year,
        timezone,
        group_kind,
        status,
        created_by,
        current_schedule_version,
        schedule_policy,
        pilot_time_override
    ) values (
        public.kcp_random_code('KCP'),
        trim(p_name),
        lower(regexp_replace(trim(p_destination_name), '[^a-zA-Z0-9]+', '-', 'g')),
        trim(p_destination_name),
        coalesce(nullif(trim(p_term_label), ''), 'Custom schedule'),
        coalesce(nullif(trim(p_timezone), ''), 'America/Phoenix'),
        normalized_kind,
        'active',
        auth.uid(),
        0,
        'generic_plan',
        false
    )
    returning * into group_record;

    -- The creator becomes the single active Owner in the same transaction.
    insert into public.kcp_memberships(
        group_id,
        user_id,
        parent_name,
        phone,
        child_name,
        grade,
        role,
        status,
        joined_at,
        updated_at
    ) values (
        group_record.id,
        auth.uid(),
        profile_record.display_name,
        profile_record.phone,
        trim(p_child_name),
        legacy_grade,
        'owner',
        'active',
        now(),
        now()
    );

    select participant.*
      into participant_record
      from public.kcp_group_participants participant
     where participant.group_id = group_record.id
       and participant.user_id = auth.uid()
     limit 1;

    update public.kcp_children child
       set grade_or_level = nullif(trim(p_grade_or_level), ''),
           updated_at = now()
     where child.group_id = group_record.id
       and child.participant_id = participant_record.id
       and lower(child.name) = lower(trim(p_child_name));

    insert into public.kcp_schedule_plans(
        group_id,
        version,
        name,
        status,
        timezone,
        outbound_label,
        return_label,
        created_by_participant_id
    ) values (
        group_record.id,
        1,
        'Recurring schedule',
        'draft',
        group_record.timezone,
        outbound_label_value,
        return_label_value,
        participant_record.id
    )
    returning * into plan_record;

    perform public.kcp_write_audit(
        group_record.id,
        'group_created',
        'group',
        group_record.id::text,
        jsonb_build_object(
            'groupCode', group_record.code,
            'groupKind', normalized_kind,
            'ownerUserId', auth.uid(),
            'ownerParticipantId', participant_record.id,
            'draftPlanId', plan_record.id,
            'calendarOptional', true
        )
    );

    return query
    select
        group_record.id,
        group_record.code,
        participant_record.id,
        plan_record.id;
end;
$$;

revoke all on function public.kcp_current_participant_id(uuid)
from public, anon;
grant execute on function public.kcp_current_participant_id(uuid)
to authenticated;

revoke all on function public.kcp_create_group_v3(
    text,text,text,text,text,text,text
) from public, anon;
grant execute on function public.kcp_create_group_v3(
    text,text,text,text,text,text,text
) to authenticated;

commit;
