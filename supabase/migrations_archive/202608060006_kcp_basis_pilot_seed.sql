begin;

-- ---------------------------------------------------------------------------
-- KCP canonical BASIS Phoenix Primary 2026-27 pilot seed
--
-- This migration is additive. It does not truncate or delete existing KCP
-- groups, schedules, profiles, memberships, calendars, or audit history.
-- It creates one preloaded, private pilot group that can be claimed by Kiran.
-- ---------------------------------------------------------------------------

-- A seeded group exists before a real pilot user claims it, so the owner and
-- original calendar uploader/generator fields must temporarily allow NULL.
alter table public.kcp_groups
    alter column created_by drop not null;

alter table public.kcp_school_calendars
    alter column uploaded_by drop not null;

alter table public.kcp_schedule_versions
    alter column generated_by drop not null;

alter table public.kcp_groups
    add column if not exists schedule_policy text not null default 'balanced_constraints';

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_schedule_policy_check'
    ) then
        alter table public.kcp_groups
            add constraint kcp_groups_schedule_policy_check
            check (schedule_policy in ('balanced_constraints','fixed_weekday_friday_rotation'));
    end if;
end;
$$;

alter table public.kcp_trips
    add column if not exists scheduled_driver_name text;

alter table public.kcp_trips
    add column if not exists actual_driver_name text;

-- Backfill readable driver names for previously created trips when possible.
update public.kcp_trips t
set scheduled_driver_name = m.parent_name
from public.kcp_memberships m
where t.scheduled_driver_name is null
  and t.scheduled_driver_id is not null
  and m.group_id = t.group_id
  and m.user_id = t.scheduled_driver_id;

update public.kcp_trips t
set actual_driver_name = m.parent_name
from public.kcp_memberships m
where t.actual_driver_name is null
  and t.actual_driver_id is not null
  and m.group_id = t.group_id
  and m.user_id = t.actual_driver_id;

create table if not exists public.kcp_roster_slots (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    parent_name text not null,
    child_name text not null,
    grade integer not null check (grade between 0 and 12),
    pickup_tag text not null,
    fixed_weekday smallint not null check (fixed_weekday between 1 and 4),
    friday_rotation_order smallint not null check (friday_rotation_order between 1 and 4),
    claimed_user_id uuid references public.kcp_profiles(id) on delete set null,
    claimed_at timestamptz,
    notes text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (group_id, parent_name),
    unique (group_id, pickup_tag),
    unique (group_id, fixed_weekday),
    unique (group_id, friday_rotation_order)
);

create index if not exists kcp_roster_slots_claimed_idx
    on public.kcp_roster_slots(group_id, claimed_user_id);

alter table public.kcp_roster_slots enable row level security;

drop policy if exists kcp_roster_slots_member_select on public.kcp_roster_slots;
create policy kcp_roster_slots_member_select
on public.kcp_roster_slots for select to authenticated
using (public.kcp_is_member(group_id));

revoke all on public.kcp_roster_slots from public, anon;
grant select on public.kcp_roster_slots to authenticated;

-- Prevent duplicate calendar events when the migration is replayed.
create unique index if not exists kcp_calendar_event_identity
    on public.kcp_calendar_events(calendar_id, event_type, title, start_date, end_date);

-- ---------------------------------------------------------------------------
-- Seed the private canonical group, roster, authoritative calendar and version 1
-- ---------------------------------------------------------------------------

insert into public.kcp_groups(
    id, code, name, school_key, school_name, academic_year, timezone,
    status, created_by, current_schedule_version, pilot_time_override,
    schedule_policy, created_at, updated_at
)
values (
    'a8b6c1a0-2627-4b10-8502-000000000001'::uuid,
    'KCP-BASIS-2026-27',
    'BASIS Phoenix Primary Carpool',
    'basis-phoenix-primary',
    'BASIS Phoenix Primary',
    '2026-27',
    'America/Phoenix',
    'active',
    null,
    1,
    true,
    'fixed_weekday_friday_rotation',
    now(),
    now()
)
on conflict (code) do update
set name = excluded.name,
    school_key = excluded.school_key,
    school_name = excluded.school_name,
    academic_year = excluded.academic_year,
    timezone = excluded.timezone,
    status = 'active',
    current_schedule_version = greatest(public.kcp_groups.current_schedule_version, 1),
    schedule_policy = 'fixed_weekday_friday_rotation',
    updated_at = now();

insert into public.kcp_roster_slots(
    id, group_id, parent_name, child_name, grade, pickup_tag,
    fixed_weekday, friday_rotation_order, notes
)
values
(
    'a8b6c1a0-2627-4b10-8502-000000000101'::uuid,
    (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'),
    'Kiran', 'Thanishka', 4, '4128', 1, 1,
    'Monday responsibility. First parent in the Friday rotation.'
),
(
    'a8b6c1a0-2627-4b10-8502-000000000102'::uuid,
    (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'),
    'Santhosh', 'Kavish', 5, '5200', 2, 2,
    'Tuesday responsibility. On Wednesdays, Kavish pickup is handled separately for swimming.'
),
(
    'a8b6c1a0-2627-4b10-8502-000000000103'::uuid,
    (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'),
    'Mohan', 'Saanvi', 5, '5206', 3, 3,
    'Wednesday responsibility.'
),
(
    'a8b6c1a0-2627-4b10-8502-000000000104'::uuid,
    (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'),
    'Pavan', 'Ishi', 1, '1118', 4, 4,
    'Thursday responsibility. Ishi uses Late Bird for the common pickup window.'
)
on conflict (group_id, parent_name) do update
set child_name = excluded.child_name,
    grade = excluded.grade,
    pickup_tag = excluded.pickup_tag,
    fixed_weekday = excluded.fixed_weekday,
    friday_rotation_order = excluded.friday_rotation_order,
    notes = excluded.notes,
    updated_at = now();

insert into public.kcp_school_calendars(
    id, group_id, school_key, school_name, academic_year,
    source_name, source_sha256, source_file_size, storage_path,
    uploaded_by, uploaded_at
)
values (
    'a8b6c1a0-2627-4b10-8502-000000000201'::uuid,
    (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'),
    'basis-phoenix-primary',
    'BASIS Phoenix Primary',
    '2026-27',
    'BASIS Phoenix Primary Academic Calendar 2026-27.pdf',
    '3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464',
    null,
    null,
    null,
    now()
)
on conflict (group_id, school_key, academic_year) do update
set school_name = excluded.school_name,
    source_name = excluded.source_name,
    source_sha256 = excluded.source_sha256;

with calendar_row as (
    select id
    from public.kcp_school_calendars
    where group_id = (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27')
      and school_key = 'basis-phoenix-primary'
      and academic_year = '2026-27'
), events(event_type, title, start_date, end_date, notes) as (
    values
    ('first_day', 'First Day of School', date '2026-08-05', date '2026-08-05', ''),
    ('no_school', 'Labor Day Break', date '2026-09-07', date '2026-09-07', ''),
    ('early_release', 'Professional Development', date '2026-09-25', date '2026-09-25', ''),
    ('early_release', 'Parent/Teacher Conferences', date '2026-10-07', date '2026-10-07', ''),
    ('no_school', 'Fall Break', date '2026-10-12', date '2026-10-16', ''),
    ('no_school', 'Veterans Day', date '2026-11-11', date '2026-11-11', ''),
    ('no_school', 'Thanksgiving Break', date '2026-11-25', date '2026-11-30', ''),
    ('early_release', 'Winter Break Early Release', date '2026-12-18', date '2026-12-18', 'No Late Bird'),
    ('no_late_bird', 'No Late Bird', date '2026-12-18', date '2026-12-18', ''),
    ('no_school', 'Winter Break', date '2026-12-21', date '2027-01-01', ''),
    ('no_school', 'MLK Day', date '2027-01-18', date '2027-01-18', ''),
    ('early_release', 'Professional Development', date '2027-02-12', date '2027-02-12', ''),
    ('no_school', 'Presidents Day', date '2027-02-15', date '2027-02-15', ''),
    ('no_school', 'February Break', date '2027-02-22', date '2027-02-24', ''),
    ('early_release', 'Parent/Teacher Conferences', date '2027-03-10', date '2027-03-10', ''),
    ('no_school', 'Spring Break', date '2027-03-15', date '2027-03-19', ''),
    ('early_release', 'Professional Development', date '2027-04-01', date '2027-04-01', ''),
    ('no_school', 'April Break', date '2027-04-02', date '2027-04-05', ''),
    ('project_week', 'Project Week', date '2027-05-24', date '2027-05-28', ''),
    ('early_release', 'Project Week Early Release', date '2027-05-24', date '2027-05-28', ''),
    ('last_day', 'Last Day of School', date '2027-05-28', date '2027-05-28', 'No Late Bird'),
    ('no_late_bird', 'No Late Bird', date '2027-05-28', date '2027-05-28', '')
)
insert into public.kcp_calendar_events(
    calendar_id, event_type, title, start_date, end_date, notes
)
select c.id, e.event_type, e.title, e.start_date, e.end_date, e.notes
from calendar_row c
cross join events e
on conflict (calendar_id, event_type, title, start_date, end_date) do update
set notes = excluded.notes;

insert into public.kcp_schedule_versions(
    id, group_id, version, status, reason, generated_by, generated_at,
    published_by, published_at, change_summary
)
values (
    'a8b6c1a0-2627-4b10-8502-000000000301'::uuid,
    (select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'),
    1,
    'published',
    'User-confirmed fixed weekday schedule beginning Monday August 10, 2026',
    null,
    now(),
    null,
    now(),
    jsonb_build_object(
        'policy', 'fixed_weekday_friday_rotation',
        'startDate', '2026-08-10',
        'monday', 'Kiran',
        'tuesday', 'Santhosh',
        'wednesday', 'Mohan',
        'thursday', 'Pavan',
        'fridayRotation', jsonb_build_array('Kiran','Santhosh','Mohan','Pavan')
    )
)
on conflict (group_id, version) do update
set reason = excluded.reason,
    change_summary = excluded.change_summary;

-- Seed exactly 177 instructional days from Monday Aug 10, 2026 through
-- Friday May 28, 2027. Each school day receives a drop and a pickup.
with group_row as (
    select id, timezone
    from public.kcp_groups
    where code = 'KCP-BASIS-2026-27'
), calendar_row as (
    select c.id
    from public.kcp_school_calendars c
    join group_row g on g.id = c.group_id
    where c.school_key = 'basis-phoenix-primary'
      and c.academic_year = '2026-27'
), school_days as (
    select d::date as school_day,
           extract(isodow from d)::integer as weekday_num
    from generate_series(date '2026-08-10', date '2027-05-28', interval '1 day') d
    where extract(isodow from d) between 1 and 5
      and not exists (
          select 1
          from public.kcp_calendar_events e
          join calendar_row c on c.id = e.calendar_id
          where e.event_type = 'no_school'
            and d::date between e.start_date and e.end_date
      )
), ranked_days as (
    select school_day,
           weekday_num,
           count(*) filter (where weekday_num = 5)
               over (order by school_day rows between unbounded preceding and current row) as friday_sequence
    from school_days
), assigned_days as (
    select school_day,
           weekday_num,
           case weekday_num
               when 1 then 'Kiran'
               when 2 then 'Santhosh'
               when 3 then 'Mohan'
               when 4 then 'Pavan'
               when 5 then (array['Kiran','Santhosh','Mohan','Pavan'])[
                   (((friday_sequence - 1) % 4) + 1)::integer
               ]
           end as driver_name
    from ranked_days
), trip_rows as (
    select
        g.id as group_id,
        1 as schedule_version,
        a.school_day as trip_date,
        k.kind,
        r.claimed_user_id as scheduled_driver_id,
        a.driver_name as scheduled_driver_name,
        'scheduled'::text as status,
        case
            when k.kind = 'morning_drop' then make_timestamptz(
                extract(year from a.school_day)::integer,
                extract(month from a.school_day)::integer,
                extract(day from a.school_day)::integer,
                7, 0, 0, g.timezone
            )
            when exists (
                select 1
                from public.kcp_calendar_events e
                join calendar_row c on c.id = e.calendar_id
                where e.event_type in ('early_release','project_week')
                  and a.school_day between e.start_date and e.end_date
            ) then null
            else make_timestamptz(
                extract(year from a.school_day)::integer,
                extract(month from a.school_day)::integer,
                extract(day from a.school_day)::integer,
                15, 35, 0, g.timezone
            )
        end as scheduled_time,
        case
            when k.kind = 'morning_drop' then '7:00 AM'
            when exists (
                select 1
                from public.kcp_calendar_events e
                join calendar_row c on c.id = e.calendar_id
                where e.event_type in ('early_release','project_week')
                  and a.school_day between e.start_date and e.end_date
            ) then 'Confirm early-release time'
            else '3:35 PM'
        end as time_label,
        trim(concat_ws(' ',
            case
                when k.kind = 'afternoon_pickup' and exists (
                    select 1
                    from public.kcp_calendar_events e
                    join calendar_row c on c.id = e.calendar_id
                    where e.event_type in ('early_release','project_week')
                      and a.school_day between e.start_date and e.end_date
                ) then 'Early release — exact pickup time must be confirmed.'
            end,
            case
                when k.kind = 'afternoon_pickup' and exists (
                    select 1
                    from public.kcp_calendar_events e
                    join calendar_row c on c.id = e.calendar_id
                    where e.event_type = 'no_late_bird'
                      and a.school_day between e.start_date and e.end_date
                ) then 'No Late Bird — first-grade coverage must be confirmed.'
            end,
            case
                when k.kind = 'afternoon_pickup' and a.weekday_num = 3
                then 'Kavish pickup is handled separately by Santhosh for swimming.'
            end
        )) as notes,
        case
            when k.kind = 'afternoon_pickup' and a.weekday_num = 3
                then array['Thanishka','Saanvi','Ishi']::text[]
            else array['Thanishka','Kavish','Saanvi','Ishi']::text[]
        end as child_names
    from assigned_days a
    cross join (values ('morning_drop'::text), ('afternoon_pickup'::text)) k(kind)
    cross join group_row g
    left join public.kcp_roster_slots r
      on r.group_id = g.id and r.parent_name = a.driver_name
)
insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind,
    scheduled_driver_id, scheduled_driver_name,
    actual_driver_id, actual_driver_name,
    status, scheduled_time, time_label, notes, child_names,
    volunteer_assignment, created_at, updated_at
)
select
    group_id, schedule_version, trip_date, kind,
    scheduled_driver_id, scheduled_driver_name,
    null, null,
    status, scheduled_time, time_label, notes, child_names,
    false, now(), now()
from trip_rows
on conflict (group_id, schedule_version, trip_date, kind) do update
set scheduled_driver_id = coalesce(public.kcp_trips.scheduled_driver_id, excluded.scheduled_driver_id),
    scheduled_driver_name = excluded.scheduled_driver_name,
    scheduled_time = excluded.scheduled_time,
    time_label = excluded.time_label,
    notes = excluded.notes,
    child_names = excluded.child_names,
    updated_at = now()
where public.kcp_trips.status in ('scheduled','coverage_needed');

insert into public.kcp_audit_events(
    group_id, actor_id, action, entity_type, entity_id, details, occurred_at
)
select
    g.id,
    null,
    'pilot_data_seeded',
    'schedule_version',
    '1',
    jsonb_build_object(
        'startDate', '2026-08-10',
        'schoolDays', 177,
        'trips', 354,
        'policy', 'Monday Kiran; Tuesday Santhosh; Wednesday Mohan; Thursday Pavan; Friday rotation starting Kiran'
    ),
    now()
from public.kcp_groups g
where g.code = 'KCP-BASIS-2026-27'
  and not exists (
      select 1 from public.kcp_audit_events a
      where a.group_id = g.id
        and a.action = 'pilot_data_seeded'
        and a.entity_type = 'schedule_version'
        and a.entity_id = '1'
  );

commit;
