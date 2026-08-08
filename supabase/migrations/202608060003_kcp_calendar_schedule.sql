begin;

-- ---------------------------------------------------------------------------
-- RPC: calendar and schedule
-- ---------------------------------------------------------------------------

create or replace function public.kcp_register_calendar(
    p_group_id uuid,
    p_school_key text,
    p_school_name text,
    p_academic_year text,
    p_source_name text,
    p_source_sha256 text,
    p_source_file_size bigint,
    p_storage_path text,
    p_events jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    calendar_id uuid;
    existing public.kcp_school_calendars;
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;

    if trim(p_school_key) = 'basis-phoenix-primary'
       and trim(p_academic_year) = '2026-27'
       and coalesce(trim(p_source_sha256),'') <> '3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464' then
        raise exception 'This PDF does not match the authoritative BASIS Phoenix Primary 2026-27 calendar';
    end if;

    select * into existing
    from public.kcp_school_calendars
    where group_id = p_group_id
      and school_key = trim(p_school_key)
      and academic_year = trim(p_academic_year);

    if found then
        raise exception 'Holiday schedule is already uploaded and considered in the carpool schedule. Uploaded on %.',
            to_char(existing.uploaded_at, 'Mon DD, YYYY');
    end if;

    insert into public.kcp_school_calendars(
        group_id, school_key, school_name, academic_year,
        source_name, source_sha256, source_file_size, storage_path, uploaded_by
    ) values (
        p_group_id, trim(p_school_key), trim(p_school_name), trim(p_academic_year),
        trim(p_source_name), nullif(trim(p_source_sha256),''), p_source_file_size,
        nullif(trim(p_storage_path),''), auth.uid()
    ) returning id into calendar_id;

    insert into public.kcp_calendar_events(calendar_id, event_type, title, start_date, end_date, notes)
    select
        calendar_id,
        item.event_type,
        item.title,
        item.start_date,
        item.end_date,
        coalesce(item.notes,'')
    from jsonb_to_recordset(coalesce(p_events, '[]'::jsonb)) as item(
        event_type text,
        title text,
        start_date date,
        end_date date,
        notes text
    );

    perform public.kcp_write_audit(
        p_group_id, 'calendar_registered', 'calendar', calendar_id::text,
        jsonb_build_object('sourceName', p_source_name, 'eventCount', jsonb_array_length(coalesce(p_events,'[]'::jsonb)))
    );
    return calendar_id;
end;
$$;

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
set search_path = public
as $$
declare
    cal_id uuid;
    first_day date;
    last_day date;
begin
    if not public.kcp_is_member(p_group_id) then raise exception 'Active group membership required'; end if;
    select id into cal_id from public.kcp_school_calendars where group_id = p_group_id limit 1;
    if cal_id is null then return; end if;

    select min(start_date) filter (where event_type = 'first_day'),
           max(end_date) filter (where event_type = 'last_day')
      into first_day, last_day
      from public.kcp_calendar_events where calendar_id = cal_id;

    return query
    with days as (
        select d::date as day
        from generate_series(first_day, last_day, interval '1 day') d
    ),
    no_school_days as (
        select distinct d::date as day
        from public.kcp_calendar_events e,
             lateral generate_series(e.start_date, e.end_date, interval '1 day') d
        where e.calendar_id = cal_id and e.event_type = 'no_school'
    ),
    instruction as (
        select day from days
        where extract(isodow from day) between 1 and 5
          and day not in (select day from no_school_days)
    ),
    long_weekend_events as (
        select distinct e.id
        from public.kcp_calendar_events e
        where e.calendar_id = cal_id
          and e.event_type = 'no_school'
          and (
              extract(isodow from e.start_date) in (1,5)
              or extract(isodow from e.end_date) in (1,5)
              or (e.end_date - e.start_date + 1) >= 3
          )
    ),
    longest as (
        select title, (end_date - start_date + 1)::integer as days
        from public.kcp_calendar_events
        where calendar_id = cal_id and event_type = 'no_school'
        order by days desc, start_date
        limit 1
    ),
    next_event as (
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
        (select count(*)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'early_release'),
        (select count(*)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'no_late_bird'),
        (select coalesce(sum(end_date - start_date + 1),0)::integer from public.kcp_calendar_events where calendar_id = cal_id and event_type = 'project_week'),
        coalesce((select days from longest),0),
        (select title from longest),
        (select count(*)::integer from public.kcp_calendar_events where calendar_id = cal_id and end_date >= current_date),
        (select title from next_event),
        (select start_date from next_event);
end;
$$;

create or replace function public.kcp_generate_schedule(
    p_group_id uuid,
    p_reason text default 'Schedule generated from approved constraints'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    cal_id uuid;
    first_day date;
    last_day date;
    d date;
    weekday_num integer;
    chosen uuid;
    new_version integer;
    group_timezone text;
    children text[];
    early_release boolean;
    trip_kind text;
    trip_time timestamptz;
    trip_label text;
    trip_notes text;
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;

    select id into cal_id from public.kcp_school_calendars where group_id = p_group_id limit 1;
    if cal_id is null then raise exception 'Upload the authoritative school calendar before generating a schedule'; end if;

    select min(start_date) filter (where event_type = 'first_day'),
           max(end_date) filter (where event_type = 'last_day')
      into first_day, last_day
      from public.kcp_calendar_events where calendar_id = cal_id;

    if first_day is null or last_day is null then
        raise exception 'Calendar must contain first_day and last_day events';
    end if;

    select current_schedule_version + 1, timezone
      into new_version, group_timezone
      from public.kcp_groups where id = p_group_id for update;

    update public.kcp_schedule_versions
       set status = 'superseded'
     where group_id = p_group_id and status = 'published';

    insert into public.kcp_schedule_versions(
        group_id, version, status, reason, generated_by, published_by, published_at,
        change_summary
    ) values (
        p_group_id, new_version, 'published', coalesce(p_reason,''), auth.uid(), auth.uid(), now(),
        jsonb_build_object('source','approved_constraints','calendarId',cal_id)
    );

    update public.kcp_groups set current_schedule_version = new_version where id = p_group_id;

    select coalesce(array_agg(m.child_name order by m.parent_name), '{}'::text[])
      into children
      from public.kcp_memberships m
     where m.group_id = p_group_id and m.status = 'active' and m.role <> 'viewer';

    create temporary table if not exists tmp_kcp_driver_counts(
        user_id uuid primary key,
        assigned integer not null default 0
    ) on commit drop;
    truncate tmp_kcp_driver_counts;
    insert into tmp_kcp_driver_counts(user_id)
    select user_id from public.kcp_memberships
    where group_id = p_group_id and status = 'active' and role <> 'viewer';

    for d in select gs::date from generate_series(first_day, last_day, interval '1 day') gs loop
        weekday_num := extract(isodow from d)::integer;
        if weekday_num not between 1 and 5 then continue; end if;
        if exists (
            select 1 from public.kcp_calendar_events e
            where e.calendar_id = cal_id and e.event_type = 'no_school'
              and d between e.start_date and e.end_date
        ) then continue; end if;

        early_release := exists (
            select 1 from public.kcp_calendar_events e
            where e.calendar_id = cal_id and e.event_type = 'early_release'
              and d between e.start_date and e.end_date
        );

        foreach trip_kind in array array['morning_drop','afternoon_pickup'] loop
            chosen := null;
            select m.user_id into chosen
            from public.kcp_memberships m
            join public.kcp_constraints c on c.group_id = m.group_id and c.user_id = m.user_id
            join tmp_kcp_driver_counts dc on dc.user_id = m.user_id
            where m.group_id = p_group_id
              and m.status = 'active'
              and m.role <> 'viewer'
              and (
                  (trip_kind = 'morning_drop' and weekday_num::smallint = any(c.drop_weekdays))
                  or
                  (trip_kind = 'afternoon_pickup' and weekday_num::smallint = any(c.pickup_weekdays))
              )
            order by dc.assigned, m.parent_name, m.user_id
            limit 1;

            if trip_kind = 'morning_drop' then
                trip_time := make_timestamptz(
                    extract(year from d)::int, extract(month from d)::int, extract(day from d)::int,
                    7, 0, 0, group_timezone
                );
                trip_label := '7:00 AM';
                trip_notes := '';
            elsif early_release then
                trip_time := null;
                trip_label := 'Confirm early-release time';
                trip_notes := 'Early release — exact pickup time requires confirmation.';
            else
                trip_time := make_timestamptz(
                    extract(year from d)::int, extract(month from d)::int, extract(day from d)::int,
                    15, 35, 0, group_timezone
                );
                trip_label := '3:35 PM';
                trip_notes := '';
            end if;

            if trip_kind = 'afternoon_pickup' and exists (
                select 1 from public.kcp_calendar_events e
                where e.calendar_id = cal_id and e.event_type = 'no_late_bird'
                  and d between e.start_date and e.end_date
            ) then
                trip_notes := concat_ws(' ', trip_notes, 'No Late Bird — first-grade coverage must be confirmed.');
            end if;

            insert into public.kcp_trips(
                group_id, schedule_version, trip_date, kind,
                scheduled_driver_id, status, scheduled_time, time_label, notes, child_names
            ) values (
                p_group_id, new_version, d, trip_kind,
                chosen,
                case when chosen is null then 'coverage_needed' else 'scheduled' end,
                trip_time, trip_label, trim(trip_notes), children
            );

            if chosen is not null then
                update tmp_kcp_driver_counts set assigned = assigned + 1 where user_id = chosen;
            end if;
        end loop;
    end loop;

    perform public.kcp_write_audit(
        p_group_id, 'schedule_generated', 'schedule_version', new_version::text,
        jsonb_build_object('reason', p_reason, 'firstDay', first_day, 'lastDay', last_day)
    );
    return new_version;
end;
$$;


commit;
