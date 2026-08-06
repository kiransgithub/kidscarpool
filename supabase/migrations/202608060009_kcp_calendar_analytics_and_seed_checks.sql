begin;

-- Count early-release DAYS, not merely event rows. Project Week is five days.
create or replace function public.kcp_calendar_analytics(p_group_id uuid)
returns table(
    instructional_days integer,
    holiday_periods integer,
    no_school_weekdays integer,
    long_weekends integer,
    upcoming_long_weekends integer,
    early_pickups integer,
    no_late_bird_days integer,
    project_week_days integer,
    longest_break_days integer,
    longest_break_title text,
    upcoming_event_count integer,
    next_event_title text,
    next_event_date date
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    cal_id uuid;
    first_day date;
    last_day date;
begin
    if not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;

    select id into cal_id
    from public.kcp_school_calendars
    where group_id = p_group_id
    limit 1;
    if cal_id is null then return; end if;

    select min(start_date) filter (where event_type = 'first_day'),
           max(end_date) filter (where event_type = 'last_day')
      into first_day, last_day
      from public.kcp_calendar_events
      where calendar_id = cal_id;

    return query
    with days as (
        select d::date as day
        from generate_series(first_day, last_day, interval '1 day') d
    ), no_school_days as (
        select distinct d::date as day
        from public.kcp_calendar_events e,
             lateral generate_series(e.start_date, e.end_date, interval '1 day') d
        where e.calendar_id = cal_id and e.event_type = 'no_school'
    ), instruction as (
        select day from days
        where extract(isodow from day) between 1 and 5
          and day not in (select day from no_school_days)
    ), long_weekend_events as (
        select distinct e.id
        from public.kcp_calendar_events e
        where e.calendar_id = cal_id
          and e.event_type = 'no_school'
          and (
              extract(isodow from e.start_date) in (1,5)
              or extract(isodow from e.end_date) in (1,5)
              or (e.end_date - e.start_date + 1) >= 3
          )
    ), longest as (
        select title, (end_date - start_date + 1)::integer as days
        from public.kcp_calendar_events
        where calendar_id = cal_id and event_type = 'no_school'
        order by days desc, start_date
        limit 1
    ), next_event as (
        select title, start_date
        from public.kcp_calendar_events
        where calendar_id = cal_id and end_date >= current_date
        order by start_date, title
        limit 1
    )
    select
        (select count(*)::integer from instruction),
        (select count(*)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'no_school'),
        (select count(*)::integer from no_school_days where extract(isodow from day) between 1 and 5),
        (select count(*)::integer from long_weekend_events),
        (select count(*)::integer from public.kcp_calendar_events e where e.id in (select id from long_weekend_events) and e.end_date >= current_date),
        (select coalesce(sum(end_date - start_date + 1),0)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'early_release'),
        (select coalesce(sum(end_date - start_date + 1),0)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'no_late_bird'),
        (select coalesce(sum(end_date - start_date + 1),0)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'project_week'),
        coalesce((select days from longest),0),
        (select title from longest),
        (select count(*)::integer from public.kcp_calendar_events where calendar_id = cal_id and end_date >= current_date),
        (select title from next_event),
        (select start_date from next_event);
end;
$$;

revoke all on function public.kcp_calendar_analytics(uuid) from public, anon;
grant execute on function public.kcp_calendar_analytics(uuid) to authenticated;

-- If there is exactly one existing anonymous profile whose name starts with
-- Kiran, automatically claim the seeded owner slot. Otherwise the PWA shows a
-- one-tap claim button and no guess is made.
do $$
declare
    matching_count integer;
    matching_user uuid;
    target_group uuid;
begin
    select count(*)
      into matching_count
      from public.kcp_profiles
      where lower(display_name) like 'kiran%';

    if matching_count = 1 then
        select id
          into matching_user
          from public.kcp_profiles
          where lower(display_name) like 'kiran%'
          limit 1;
    end if;

    select id into target_group
    from public.kcp_groups
    where code = 'KCP-BASIS-2026-27';

    if matching_count = 1 and target_group is not null then
        perform public.kcp_bind_seeded_roster(
            target_group,
            matching_user,
            'Kiran',
            true
        );
    end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Migration smoke checks: no data is removed; seeded counts must be exact.
-- ---------------------------------------------------------------------------

do $$
declare
    target_group uuid;
    school_day_count integer;
    trip_count integer;
    kiran_trip_count integer;
    santhosh_trip_count integer;
    mohan_trip_count integer;
    pavan_trip_count integer;
begin
    select id into target_group
    from public.kcp_groups
    where code = 'KCP-BASIS-2026-27';

    select count(distinct trip_date), count(*)
      into school_day_count, trip_count
      from public.kcp_trips
      where group_id = target_group
        and schedule_version = 1;

    select count(*) into kiran_trip_count
    from public.kcp_trips
    where group_id = target_group and schedule_version = 1
      and scheduled_driver_name = 'Kiran';

    select count(*) into santhosh_trip_count
    from public.kcp_trips
    where group_id = target_group and schedule_version = 1
      and scheduled_driver_name = 'Santhosh';

    select count(*) into mohan_trip_count
    from public.kcp_trips
    where group_id = target_group and schedule_version = 1
      and scheduled_driver_name = 'Mohan';

    select count(*) into pavan_trip_count
    from public.kcp_trips
    where group_id = target_group and schedule_version = 1
      and scheduled_driver_name = 'Pavan';

    if school_day_count <> 177 then
        raise exception 'KCP seed expected 177 school days, found %', school_day_count;
    end if;
    if trip_count <> 354 then
        raise exception 'KCP seed expected 354 trips, found %', trip_count;
    end if;
    if kiran_trip_count <> 82 then
        raise exception 'KCP seed expected 82 Kiran trips, found %', kiran_trip_count;
    end if;
    if santhosh_trip_count <> 92 then
        raise exception 'KCP seed expected 92 Santhosh trips, found %', santhosh_trip_count;
    end if;
    if mohan_trip_count <> 88 then
        raise exception 'KCP seed expected 88 Mohan trips, found %', mohan_trip_count;
    end if;
    if pavan_trip_count <> 92 then
        raise exception 'KCP seed expected 92 Pavan trips, found %', pavan_trip_count;
    end if;
end;
$$;

commit;
