begin;

-- ---------------------------------------------------------------------------
-- Generic carpool groups and calendar-optional recurring schedules
-- ---------------------------------------------------------------------------

alter table public.kcp_groups
    add column if not exists group_kind text not null default 'school';

alter table public.kcp_groups
    add column if not exists schedule_start_date date;

alter table public.kcp_groups
    add column if not exists schedule_end_date date;

alter table public.kcp_groups
    add column if not exists service_weekdays smallint[] not null
        default array[1,2,3,4,5]::smallint[];

alter table public.kcp_groups
    add column if not exists drop_time time without time zone not null default time '07:00';

alter table public.kcp_groups
    add column if not exists pickup_time time without time zone not null default time '15:35';

alter table public.kcp_groups
    add column if not exists auto_lifecycle_enabled boolean not null default true;

alter table public.kcp_groups
    add column if not exists auto_complete_after_minutes integer not null default 60;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_kind_check'
    ) then
        alter table public.kcp_groups
            add constraint kcp_groups_kind_check
            check (group_kind in ('school','club','training','music','gymnastics','tennis','other'));
    end if;

    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_date_range_check'
    ) then
        alter table public.kcp_groups
            add constraint kcp_groups_date_range_check
            check (
                schedule_start_date is null
                or schedule_end_date is null
                or schedule_end_date >= schedule_start_date
            );
    end if;

    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_service_weekdays_check'
    ) then
        alter table public.kcp_groups
            add constraint kcp_groups_service_weekdays_check
            check (
                cardinality(service_weekdays) > 0
                and service_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]
            );
    end if;

    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_groups'::regclass
          and conname = 'kcp_groups_auto_complete_minutes_check'
    ) then
        alter table public.kcp_groups
            add constraint kcp_groups_auto_complete_minutes_check
            check (auto_complete_after_minutes between 5 and 480);
    end if;
end;
$$;

update public.kcp_groups
set group_kind = 'school',
    schedule_start_date = date '2026-08-10',
    schedule_end_date = date '2027-05-28',
    service_weekdays = array[1,2,3,4,5]::smallint[],
    drop_time = time '07:00',
    pickup_time = time '15:35',
    auto_lifecycle_enabled = true,
    auto_complete_after_minutes = 60
where code = 'KCP-BASIS-2026-27';

create or replace function public.kcp_create_group_v2(
    p_name text,
    p_group_kind text,
    p_destination_name text,
    p_destination_key text,
    p_term_label text,
    p_schedule_start_date date,
    p_schedule_end_date date,
    p_service_weekdays smallint[],
    p_drop_time time without time zone,
    p_pickup_time time without time zone,
    p_auto_complete_after_minutes integer,
    p_child_name text,
    p_grade integer,
    p_drop_weekdays smallint[],
    p_pickup_weekdays smallint[],
    p_notes text default ''
)
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    new_group public.kcp_groups;
    profile public.kcp_profiles;
    normalized_kind text := lower(trim(p_group_kind));
    normalized_service_days smallint[] := coalesce(p_service_weekdays, '{}'::smallint[]);
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into profile
    from public.kcp_profiles
    where id = auth.uid();
    if not found then raise exception 'Complete your parent profile first'; end if;

    if normalized_kind not in ('school','club','training','music','gymnastics','tennis','other') then
        raise exception 'Choose a valid carpool group type';
    end if;
    if p_schedule_start_date is null or p_schedule_end_date is null
       or p_schedule_end_date < p_schedule_start_date then
        raise exception 'Enter a valid recurring schedule date range';
    end if;
    if cardinality(normalized_service_days) = 0
       or not (normalized_service_days <@ array[1,2,3,4,5,6,7]::smallint[]) then
        raise exception 'Choose at least one valid recurring weekday';
    end if;
    if p_auto_complete_after_minutes not between 5 and 480 then
        raise exception 'Auto-complete duration must be between 5 and 480 minutes';
    end if;

    insert into public.kcp_groups(
        code, name, school_key, school_name, academic_year,
        group_kind, schedule_start_date, schedule_end_date,
        service_weekdays, drop_time, pickup_time,
        auto_lifecycle_enabled, auto_complete_after_minutes,
        created_by
    ) values (
        public.kcp_random_code('KCP'),
        trim(p_name),
        coalesce(nullif(trim(p_destination_key),''), 'carpool-destination'),
        trim(p_destination_name),
        coalesce(nullif(trim(p_term_label),''), 'Custom schedule'),
        normalized_kind,
        p_schedule_start_date,
        p_schedule_end_date,
        normalized_service_days,
        p_drop_time,
        p_pickup_time,
        true,
        p_auto_complete_after_minutes,
        auth.uid()
    ) returning * into new_group;

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade,
        role, status, joined_at
    ) values (
        new_group.id, auth.uid(), profile.display_name, profile.phone,
        trim(p_child_name), p_grade, 'owner', 'active', now()
    );

    insert into public.kcp_constraints(
        group_id, user_id, drop_weekdays, pickup_weekdays, notes,
        updated_by, effective_from
    ) values (
        new_group.id,
        auth.uid(),
        coalesce(p_drop_weekdays, normalized_service_days),
        coalesce(p_pickup_weekdays, normalized_service_days),
        coalesce(p_notes,''),
        auth.uid(),
        p_schedule_start_date
    );

    perform public.kcp_write_audit(
        new_group.id,
        'group_created',
        'group',
        new_group.id::text,
        jsonb_build_object(
            'name', new_group.name,
            'code', new_group.code,
            'groupKind', new_group.group_kind,
            'calendarOptional', true,
            'scheduleStartDate', new_group.schedule_start_date,
            'scheduleEndDate', new_group.schedule_end_date,
            'serviceWeekdays', new_group.service_weekdays,
            'autoCompleteAfterMinutes', new_group.auto_complete_after_minutes
        )
    );

    return query select new_group.id, new_group.code;
end;
$$;

revoke all on function public.kcp_create_group_v2(
    text,text,text,text,text,date,date,smallint[],time without time zone,
    time without time zone,integer,text,integer,smallint[],smallint[],text
) from public, anon;

grant execute on function public.kcp_create_group_v2(
    text,text,text,text,text,date,date,smallint[],time without time zone,
    time without time zone,integer,text,integer,smallint[],smallint[],text
) to authenticated;

-- Balanced scheduling now works with either:
-- 1. a calendar (holidays/closures are excluded), or
-- 2. only the group's recurring date range and weekdays.
create or replace function public.kcp_generate_balanced_schedule(
    p_group_id uuid,
    p_reason text default 'Schedule generated from approved constraints'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    group_record public.kcp_groups;
    calendar_id uuid;
    range_start date;
    range_end date;
    d date;
    weekday_num integer;
    chosen uuid;
    chosen_name text;
    new_version integer;
    children text[];
    early_release boolean;
    trip_kind text;
    trip_time timestamptz;
    trip_label text;
    trip_notes text;
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or admin role required';
    end if;

    select * into group_record
    from public.kcp_groups
    where id = p_group_id
    for update;
    if not found then raise exception 'Group not found'; end if;

    select id into calendar_id
    from public.kcp_school_calendars
    where group_id = p_group_id
    limit 1;

    range_start := group_record.schedule_start_date;
    range_end := group_record.schedule_end_date;

    if range_start is null and calendar_id is not null then
        select min(e.start_date) filter (where e.event_type = 'first_day')
          into range_start
          from public.kcp_calendar_events e
         where e.calendar_id = calendar_id;
    end if;
    if range_end is null and calendar_id is not null then
        select max(e.end_date) filter (where e.event_type = 'last_day')
          into range_end
          from public.kcp_calendar_events e
         where e.calendar_id = calendar_id;
    end if;

    if range_start is null or range_end is null or range_end < range_start then
        raise exception 'Set the recurring start/end dates or upload a calendar before generating a schedule';
    end if;

    new_version := group_record.current_schedule_version + 1;

    update public.kcp_schedule_versions
       set status = 'superseded'
     where group_id = p_group_id and status = 'published';

    insert into public.kcp_schedule_versions(
        group_id, version, status, reason, generated_by,
        generated_at, published_by, published_at, change_summary
    ) values (
        p_group_id,
        new_version,
        'published',
        coalesce(p_reason,''),
        auth.uid(),
        now(),
        auth.uid(),
        now(),
        jsonb_build_object(
            'source', 'approved_constraints',
            'calendarUsed', calendar_id is not null,
            'groupKind', group_record.group_kind,
            'scheduleStartDate', range_start,
            'scheduleEndDate', range_end,
            'serviceWeekdays', group_record.service_weekdays
        )
    );

    update public.kcp_groups
       set current_schedule_version = new_version
     where id = p_group_id;

    select coalesce(array_agg(m.child_name order by m.parent_name), '{}'::text[])
      into children
      from public.kcp_memberships m
     where m.group_id = p_group_id
       and m.status = 'active'
       and m.role <> 'viewer';

    create temporary table if not exists tmp_kcp_driver_counts(
        user_id uuid primary key,
        assigned integer not null default 0
    ) on commit drop;
    truncate tmp_kcp_driver_counts;

    insert into tmp_kcp_driver_counts(user_id)
    select user_id
    from public.kcp_memberships
    where group_id = p_group_id
      and status = 'active'
      and role <> 'viewer';

    for d in
        select gs::date
        from generate_series(range_start, range_end, interval '1 day') gs
    loop
        weekday_num := extract(isodow from d)::integer;
        if not (weekday_num::smallint = any(group_record.service_weekdays)) then
            continue;
        end if;

        if calendar_id is not null and exists (
            select 1
            from public.kcp_calendar_events e
            where e.calendar_id = calendar_id
              and e.event_type = 'no_school'
              and d between e.start_date and e.end_date
        ) then
            continue;
        end if;

        early_release := calendar_id is not null and exists (
            select 1
            from public.kcp_calendar_events e
            where e.calendar_id = calendar_id
              and e.event_type in ('early_release','project_week')
              and d between e.start_date and e.end_date
        );

        foreach trip_kind in array array['morning_drop','afternoon_pickup'] loop
            chosen := null;
            chosen_name := null;

            select m.user_id, m.parent_name
              into chosen, chosen_name
              from public.kcp_memberships m
              join public.kcp_constraints c
                on c.group_id = m.group_id and c.user_id = m.user_id
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
                    extract(year from d)::integer,
                    extract(month from d)::integer,
                    extract(day from d)::integer,
                    extract(hour from group_record.drop_time)::integer,
                    extract(minute from group_record.drop_time)::integer,
                    0,
                    group_record.timezone
                );
                trip_label := to_char(group_record.drop_time, 'FMHH12:MI AM');
                trip_notes := '';
            elsif early_release then
                trip_time := null;
                trip_label := 'Confirm early-release time';
                trip_notes := 'Early release — exact pickup time requires confirmation.';
            else
                trip_time := make_timestamptz(
                    extract(year from d)::integer,
                    extract(month from d)::integer,
                    extract(day from d)::integer,
                    extract(hour from group_record.pickup_time)::integer,
                    extract(minute from group_record.pickup_time)::integer,
                    0,
                    group_record.timezone
                );
                trip_label := to_char(group_record.pickup_time, 'FMHH12:MI AM');
                trip_notes := '';
            end if;

            if trip_kind = 'afternoon_pickup'
               and calendar_id is not null
               and exists (
                   select 1
                   from public.kcp_calendar_events e
                   where e.calendar_id = calendar_id
                     and e.event_type = 'no_late_bird'
                     and d between e.start_date and e.end_date
               ) then
                trip_notes := concat_ws(
                    ' ',
                    trip_notes,
                    'No Late Bird — first-grade coverage must be confirmed.'
                );
            end if;

            insert into public.kcp_trips(
                group_id, schedule_version, trip_date, kind,
                scheduled_driver_id, scheduled_driver_name,
                status, scheduled_time, time_label, notes, child_names
            ) values (
                p_group_id,
                new_version,
                d,
                trip_kind,
                chosen,
                chosen_name,
                case when chosen is null then 'coverage_needed' else 'scheduled' end,
                trip_time,
                trip_label,
                trim(trip_notes),
                children
            );

            if chosen is not null then
                update tmp_kcp_driver_counts
                   set assigned = assigned + 1
                 where user_id = chosen;
            end if;
        end loop;
    end loop;

    perform public.kcp_write_audit(
        p_group_id,
        'schedule_generated',
        'schedule_version',
        new_version::text,
        jsonb_build_object(
            'reason', p_reason,
            'calendarUsed', calendar_id is not null,
            'firstDay', range_start,
            'lastDay', range_end
        )
    );

    return new_version;
end;
$$;

revoke all on function public.kcp_generate_balanced_schedule(uuid,text)
from public, anon, authenticated;

-- The public dispatcher remains the only client-facing schedule-generation RPC.
grant execute on function public.kcp_generate_schedule(uuid,text) to authenticated;

commit;
