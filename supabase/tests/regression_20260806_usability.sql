-- Run in Supabase SQL Editor after migrations 010-012.
-- Read-only verification except for lifecycle function boundary checks, which
-- use no application rows.

do $$
declare
    target_group uuid;
    current_version integer;
    school_days integer;
    trip_operations integer;
    first_upcoming timestamptz;
    cron_jobs integer;
begin
    select id, current_schedule_version
      into target_group, current_version
      from public.kcp_groups
     where code = 'KCP-BASIS-2026-27';

    if target_group is null then
        raise exception 'Canonical BASIS group missing';
    end if;

    select count(distinct trip_date), count(*)
      into school_days, trip_operations
      from public.kcp_trips
     where group_id = target_group
       and schedule_version = current_version;

    if school_days <> 177 or trip_operations <> 354 then
        raise exception 'Expected 177 days/354 trips in current schedule, found %/%',
            school_days, trip_operations;
    end if;

    if not exists (
        select 1 from public.kcp_groups
        where id = target_group
          and group_kind = 'school'
          and schedule_start_date = date '2026-08-10'
          and schedule_end_date = date '2027-05-28'
          and auto_complete_after_minutes = 60
    ) then
        raise exception 'Canonical group configuration is incomplete';
    end if;

    if public.kcp_can_start_trip_at(
        timestamptz '2026-08-10 07:00:00-07',
        timestamptz '2026-08-10 06:49:59-07'
    ) then
        raise exception '10-minute start gate regression';
    end if;

    if not public.kcp_can_start_trip_at(
        timestamptz '2026-08-10 07:00:00-07',
        timestamptz '2026-08-10 06:50:00-07'
    ) then
        raise exception 'Start gate should open at exactly 10 minutes';
    end if;

    select count(*) into cron_jobs
    from cron.job
    where jobname = 'kcp-auto-trip-lifecycle';
    if cron_jobs <> 1 then
        raise exception 'Expected one lifecycle cron job, found %', cron_jobs;
    end if;

    select min(scheduled_time) into first_upcoming
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = current_version
      and scheduled_time >= now();

    raise notice 'Current BASIS schedule version %, nearest upcoming time %, cron jobs %',
        current_version, first_upcoming, cron_jobs;
end;
$$;

select
    g.code,
    g.current_schedule_version,
    g.group_kind,
    g.schedule_start_date,
    g.schedule_end_date,
    g.auto_complete_after_minutes,
    (
        select count(distinct t.trip_date)
        from public.kcp_trips t
        where t.group_id = g.id
          and t.schedule_version = g.current_schedule_version
    ) as school_days,
    (
        select count(*)
        from public.kcp_trips t
        where t.group_id = g.id
          and t.schedule_version = g.current_schedule_version
    ) as trip_operations
from public.kcp_groups g
where g.code = 'KCP-BASIS-2026-27';

select 'PASS: optional calendar, schedule recreation, start gate and cron configuration verified' as result;
