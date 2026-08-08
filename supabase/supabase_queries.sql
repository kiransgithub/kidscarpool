select
  public.kcp_health ();

select
  table_name
from
  information_schema.tables
where
  table_schema = 'public'
  and table_name like 'kcp_%'
order by
  table_name;

select
  id,
  name,
  public
from
  storage.buckets
where
  id = 'kcp-school-calendars';

select
  routine_name
from
  information_schema.routines
where
  routine_schema = 'public'
  and routine_name like 'kcp_%'
order by
  routine_name;

select
  public.kcp_random_code ('KCP');

select
  public.kcp_random_invite_token ();

select
  'profiles' as entity,
  count(*) as row_count
from
  public.kcp_profiles
union all
select
  'groups',
  count(*)
from
  public.kcp_groups
union all
select
  'memberships',
  count(*)
from
  public.kcp_memberships
union all
select
  'calendars',
  count(*)
from
  public.kcp_school_calendars
union all
select
  'trips',
  count(*)
from
  public.kcp_trips
union all
select
  'audit events',
  count(*)
from
  public.kcp_audit_events;

select
  g.code,
  g.name,
  g.school_name,
  g.academic_year,
  m.parent_name,
  m.child_name,
  m.role,
  m.status,
  m.user_id
from
  public.kcp_groups g
  left join public.kcp_memberships m on m.group_id = g.id
order by
  g.created_at,
  m.parent_name;

select
  g.code,
  g.name,
  g.school_name,
  g.academic_year,
  g.current_schedule_version,
  g.schedule_policy,
  g.created_by
from
  public.kcp_groups g
where
  g.code = 'KCP-BASIS-2026-27';

select
  parent_name,
  child_name,
  grade,
  pickup_tag,
  fixed_weekday,
  friday_rotation_order,
  claimed_user_id
from
  public.kcp_roster_slots
where
  group_id = (
    select
      id
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
order by
  fixed_weekday;

select
  count(distinct trip_date) as school_days,
  count(*) as trip_operations
from
  public.kcp_trips
where
  group_id = (
    select
      id
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
  and schedule_version = 1;

select
  scheduled_driver_name,
  count(*) as trip_operations
from
  public.kcp_trips
where
  group_id = (
    select
      id
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
  and schedule_version = 1
group by
  scheduled_driver_name
order by
  scheduled_driver_name;

select
  trip_date,
  scheduled_driver_name
from
  public.kcp_trips
where
  group_id = (
    select
      id
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
  and schedule_version = 1
  and kind = 'morning_drop'
  and extract(
    isodow
    from
      trip_date
  ) = 5
order by
  trip_date
limit
  8;

select
  code,
  current_schedule_version,
  group_kind,
  schedule_start_date,
  schedule_end_date,
  auto_complete_after_minutes
from
  public.kcp_groups
where
  code = 'KCP-BASIS-2026-27';

select
  count(distinct trip_date) as school_days,
  count(*) as trip_operations
from
  public.kcp_trips
where
  group_id = (
    select
      id
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
  and schedule_version = (
    select
      current_schedule_version
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  );

select
  scheduled_driver_name,
  count(*) as trip_operations
from
  public.kcp_trips
where
  group_id = (
    select
      id
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
  and schedule_version = (
    select
      current_schedule_version
    from
      public.kcp_groups
    where
      code = 'KCP-BASIS-2026-27'
  )
group by
  scheduled_driver_name
order by
  scheduled_driver_name;

select
  jobid,
  jobname,
  schedule,
  active
from
  cron.job
where
  jobname = 'kcp-auto-trip-lifecycle';

select
  *
from
  public.kcp_issue_roster_recovery_code ('KCP-BASIS-2026-27', 'Kiran', 30);