begin;

-- ---------------------------------------------------------------------------
-- Replace the temporary driver-count table with an in-memory JSONB map.
-- This keeps balanced assignment deterministic while allowing Supabase's
-- static database lint to verify the full function body.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_generate_balanced_schedule(
    p_group_id uuid,
    p_reason text default 'Schedule generated from approved constraints'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_group public.kcp_groups;
    v_calendar_id uuid;
    v_range_start date;
    v_range_end date;
    v_day date;
    v_weekday_num integer;
    v_chosen uuid;
    v_chosen_name text;
    v_new_version integer;
    v_children text[];
    v_early_release boolean;
    v_trip_kind text;
    v_trip_time timestamptz;
    v_trip_label text;
    v_trip_notes text;
    v_driver_counts jsonb := '{}'::jsonb;
    v_current_count integer;
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or admin role required';
    end if;

    select g.*
      into v_group
      from public.kcp_groups g
     where g.id = p_group_id
     for update;
    if not found then raise exception 'Group not found'; end if;

    select c.id
      into v_calendar_id
      from public.kcp_school_calendars c
     where c.group_id = p_group_id
     order by c.uploaded_at desc
     limit 1;

    v_range_start := v_group.schedule_start_date;
    v_range_end := v_group.schedule_end_date;

    if v_range_start is null and v_calendar_id is not null then
        select min(e.start_date) filter (where e.event_type = 'first_day')
          into v_range_start
          from public.kcp_calendar_events e
         where e.calendar_id = v_calendar_id;
    end if;

    if v_range_end is null and v_calendar_id is not null then
        select max(e.end_date) filter (where e.event_type = 'last_day')
          into v_range_end
          from public.kcp_calendar_events e
         where e.calendar_id = v_calendar_id;
    end if;

    if v_range_start is null
       or v_range_end is null
       or v_range_end < v_range_start then
        raise exception 'Set the recurring start/end dates or upload a calendar before generating a schedule';
    end if;

    v_new_version := v_group.current_schedule_version + 1;

    update public.kcp_schedule_versions v
       set status = 'superseded'
     where v.group_id = p_group_id
       and v.status = 'published';

    insert into public.kcp_schedule_versions(
        group_id, version, status, reason, generated_by,
        generated_at, published_by, published_at, change_summary
    ) values (
        p_group_id,
        v_new_version,
        'published',
        coalesce(p_reason,''),
        auth.uid(),
        now(),
        auth.uid(),
        now(),
        jsonb_build_object(
            'source', 'approved_constraints',
            'calendarUsed', v_calendar_id is not null,
            'groupKind', v_group.group_kind,
            'scheduleStartDate', v_range_start,
            'scheduleEndDate', v_range_end,
            'serviceWeekdays', v_group.service_weekdays,
            'assignmentCounter', 'jsonb'
        )
    );

    update public.kcp_groups g
       set current_schedule_version = v_new_version
     where g.id = p_group_id;

    select coalesce(
               array_agg(m.child_name order by m.parent_name),
               '{}'::text[]
           )
      into v_children
      from public.kcp_memberships m
     where m.group_id = p_group_id
       and m.status = 'active'
       and m.role <> 'viewer';

    select coalesce(
               jsonb_object_agg(m.user_id::text, to_jsonb(0)),
               '{}'::jsonb
           )
      into v_driver_counts
      from public.kcp_memberships m
     where m.group_id = p_group_id
       and m.status = 'active'
       and m.role <> 'viewer';

    for v_day in
        select gs::date
          from generate_series(v_range_start, v_range_end, interval '1 day') gs
    loop
        v_weekday_num := extract(isodow from v_day)::integer;

        if not (v_weekday_num::smallint = any(v_group.service_weekdays)) then
            continue;
        end if;

        if v_calendar_id is not null and exists (
            select 1
              from public.kcp_calendar_events e
             where e.calendar_id = v_calendar_id
               and e.event_type = 'no_school'
               and v_day between e.start_date and e.end_date
        ) then
            continue;
        end if;

        v_early_release := v_calendar_id is not null and exists (
            select 1
              from public.kcp_calendar_events e
             where e.calendar_id = v_calendar_id
               and e.event_type in ('early_release','project_week')
               and v_day between e.start_date and e.end_date
        );

        foreach v_trip_kind in array array['morning_drop','afternoon_pickup'] loop
            v_chosen := null;
            v_chosen_name := null;

            select m.user_id, m.parent_name
              into v_chosen, v_chosen_name
              from public.kcp_memberships m
              join public.kcp_constraints c
                on c.group_id = m.group_id
               and c.user_id = m.user_id
             where m.group_id = p_group_id
               and m.status = 'active'
               and m.role <> 'viewer'
               and (
                   (
                       v_trip_kind = 'morning_drop'
                       and v_weekday_num::smallint = any(c.drop_weekdays)
                   )
                   or
                   (
                       v_trip_kind = 'afternoon_pickup'
                       and v_weekday_num::smallint = any(c.pickup_weekdays)
                   )
               )
             order by
                 coalesce((v_driver_counts ->> m.user_id::text)::integer, 0),
                 m.parent_name,
                 m.user_id
             limit 1;

            if v_trip_kind = 'morning_drop' then
                v_trip_time := make_timestamptz(
                    extract(year from v_day)::integer,
                    extract(month from v_day)::integer,
                    extract(day from v_day)::integer,
                    extract(hour from v_group.drop_time)::integer,
                    extract(minute from v_group.drop_time)::integer,
                    0,
                    v_group.timezone
                );
                v_trip_label := to_char(v_group.drop_time, 'FMHH12:MI AM');
                v_trip_notes := '';
            elsif v_early_release then
                v_trip_time := null;
                v_trip_label := 'Confirm early-release time';
                v_trip_notes := 'Early release — exact pickup time requires confirmation.';
            else
                v_trip_time := make_timestamptz(
                    extract(year from v_day)::integer,
                    extract(month from v_day)::integer,
                    extract(day from v_day)::integer,
                    extract(hour from v_group.pickup_time)::integer,
                    extract(minute from v_group.pickup_time)::integer,
                    0,
                    v_group.timezone
                );
                v_trip_label := to_char(v_group.pickup_time, 'FMHH12:MI AM');
                v_trip_notes := '';
            end if;

            if v_trip_kind = 'afternoon_pickup'
               and v_calendar_id is not null
               and exists (
                   select 1
                     from public.kcp_calendar_events e
                    where e.calendar_id = v_calendar_id
                      and e.event_type = 'no_late_bird'
                      and v_day between e.start_date and e.end_date
               ) then
                v_trip_notes := concat_ws(
                    ' ',
                    v_trip_notes,
                    'No Late Bird — first-grade coverage must be confirmed.'
                );
            end if;

            insert into public.kcp_trips(
                group_id, schedule_version, trip_date, kind,
                scheduled_driver_id, scheduled_driver_name,
                status, scheduled_time, time_label, notes, child_names
            ) values (
                p_group_id,
                v_new_version,
                v_day,
                v_trip_kind,
                v_chosen,
                v_chosen_name,
                case when v_chosen is null then 'coverage_needed' else 'scheduled' end,
                v_trip_time,
                v_trip_label,
                trim(v_trip_notes),
                v_children
            );

            if v_chosen is not null then
                v_current_count := coalesce(
                    (v_driver_counts ->> v_chosen::text)::integer,
                    0
                );
                v_driver_counts := jsonb_set(
                    v_driver_counts,
                    array[v_chosen::text],
                    to_jsonb(v_current_count + 1),
                    true
                );
            end if;
        end loop;
    end loop;

    perform public.kcp_write_audit(
        p_group_id,
        'schedule_generated',
        'schedule_version',
        v_new_version::text,
        jsonb_build_object(
            'reason', p_reason,
            'calendarUsed', v_calendar_id is not null,
            'firstDay', v_range_start,
            'lastDay', v_range_end,
            'driverCounts', v_driver_counts
        )
    );

    return v_new_version;
end;
$$;

revoke all on function public.kcp_generate_balanced_schedule(uuid,text)
from public, anon, authenticated;

commit;
