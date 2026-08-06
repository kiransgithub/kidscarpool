-- Run in Supabase SQL Editor after migrations 006-009 are applied.
-- This script is read-only and fails loudly when the canonical seed is wrong.

do $$
declare
    target_group uuid;
    school_days integer;
    trips integer;
    first_friday_driver text;
    second_friday_driver text;
    early_pickup_days integer;
    roster_count integer;
begin
    select id into target_group
    from public.kcp_groups
    where code = 'KCP-BASIS-2026-27';

    if target_group is null then
        raise exception 'Canonical BASIS pilot group is missing';
    end if;

    select count(*) into roster_count
    from public.kcp_roster_slots
    where group_id = target_group;
    if roster_count <> 4 then
        raise exception 'Expected four roster slots, found %', roster_count;
    end if;

    select count(distinct trip_date), count(*)
      into school_days, trips
      from public.kcp_trips
      where group_id = target_group and schedule_version = 1;
    if school_days <> 177 or trips <> 354 then
        raise exception 'Expected 177 school days and 354 trips, found % and %', school_days, trips;
    end if;

    select scheduled_driver_name into first_friday_driver
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = 1
      and trip_date = date '2026-08-14'
      and kind = 'morning_drop';
    if first_friday_driver <> 'Kiran' then
        raise exception 'First Friday must be Kiran, found %', first_friday_driver;
    end if;

    select scheduled_driver_name into second_friday_driver
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = 1
      and trip_date = date '2026-08-21'
      and kind = 'morning_drop';
    if second_friday_driver <> 'Santhosh' then
        raise exception 'Second Friday must be Santhosh, found %', second_friday_driver;
    end if;

    select coalesce(sum(end_date - start_date + 1), 0)::integer
      into early_pickup_days
      from public.kcp_calendar_events e
      join public.kcp_school_calendars c on c.id = e.calendar_id
      where c.group_id = target_group
        and e.event_type = 'early_release';
    if early_pickup_days <> 11 then
        raise exception 'Expected 11 early-pickup days, found %', early_pickup_days;
    end if;
end;
$$;

select 'PASS: canonical BASIS pilot seed is internally consistent' as result;
