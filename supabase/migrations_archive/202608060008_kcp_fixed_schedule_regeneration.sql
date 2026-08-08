begin;

-- ---------------------------------------------------------------------------
-- Fixed-policy schedule regeneration while preserving balanced new-group logic
-- ---------------------------------------------------------------------------

do $$
begin
    if to_regprocedure('public.kcp_generate_balanced_schedule(uuid,text)') is null
       and to_regprocedure('public.kcp_generate_schedule(uuid,text)') is not null then
        execute 'alter function public.kcp_generate_schedule(uuid,text) rename to kcp_generate_balanced_schedule';
    end if;
end;
$$;

create or replace function public.kcp_generate_fixed_schedule(
    p_group_id uuid,
    p_reason text default 'Fixed weekday schedule regenerated'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    calendar_id uuid;
    first_day date;
    last_day date;
    new_version integer;
    group_timezone text;
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or admin role required';
    end if;

    select c.id into calendar_id
    from public.kcp_school_calendars c
    where c.group_id = p_group_id
    limit 1;
    if calendar_id is null then
        raise exception 'Upload the authoritative school calendar before generating a schedule';
    end if;

    select date '2026-08-10',
           max(e.end_date) filter (where e.event_type = 'last_day')
      into first_day, last_day
      from public.kcp_calendar_events e
      where e.calendar_id = calendar_id;

    if last_day is null then
        raise exception 'Calendar must contain a last_day event';
    end if;

    select current_schedule_version + 1, timezone
      into new_version, group_timezone
      from public.kcp_groups
      where id = p_group_id
      for update;

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
            'policy', 'fixed_weekday_friday_rotation',
            'startDate', first_day,
            'monday', 'Kiran',
            'tuesday', 'Santhosh',
            'wednesday', 'Mohan',
            'thursday', 'Pavan',
            'fridayRotation', jsonb_build_array('Kiran','Santhosh','Mohan','Pavan')
        )
    );

    update public.kcp_groups
       set current_schedule_version = new_version
     where id = p_group_id;

    with school_days as (
        select d::date as school_day,
               extract(isodow from d)::integer as weekday_num
        from generate_series(first_day, last_day, interval '1 day') d
        where extract(isodow from d) between 1 and 5
          and not exists (
              select 1
              from public.kcp_calendar_events e
              where e.calendar_id = calendar_id
                and e.event_type = 'no_school'
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
    )
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind,
        scheduled_driver_id, scheduled_driver_name,
        status, scheduled_time, time_label, notes, child_names,
        volunteer_assignment
    )
    select
        p_group_id,
        new_version,
        a.school_day,
        k.kind,
        r.claimed_user_id,
        a.driver_name,
        'scheduled',
        case
            when k.kind = 'morning_drop' then make_timestamptz(
                extract(year from a.school_day)::integer,
                extract(month from a.school_day)::integer,
                extract(day from a.school_day)::integer,
                7, 0, 0, group_timezone
            )
            when exists (
                select 1 from public.kcp_calendar_events e
                where e.calendar_id = calendar_id
                  and e.event_type in ('early_release','project_week')
                  and a.school_day between e.start_date and e.end_date
            ) then null
            else make_timestamptz(
                extract(year from a.school_day)::integer,
                extract(month from a.school_day)::integer,
                extract(day from a.school_day)::integer,
                15, 35, 0, group_timezone
            )
        end,
        case
            when k.kind = 'morning_drop' then '7:00 AM'
            when exists (
                select 1 from public.kcp_calendar_events e
                where e.calendar_id = calendar_id
                  and e.event_type in ('early_release','project_week')
                  and a.school_day between e.start_date and e.end_date
            ) then 'Confirm early-release time'
            else '3:35 PM'
        end,
        trim(concat_ws(' ',
            case
                when k.kind = 'afternoon_pickup' and exists (
                    select 1 from public.kcp_calendar_events e
                    where e.calendar_id = calendar_id
                      and e.event_type in ('early_release','project_week')
                      and a.school_day between e.start_date and e.end_date
                ) then 'Early release — exact pickup time must be confirmed.'
            end,
            case
                when k.kind = 'afternoon_pickup' and exists (
                    select 1 from public.kcp_calendar_events e
                    where e.calendar_id = calendar_id
                      and e.event_type = 'no_late_bird'
                      and a.school_day between e.start_date and e.end_date
                ) then 'No Late Bird — first-grade coverage must be confirmed.'
            end,
            case
                when k.kind = 'afternoon_pickup' and a.weekday_num = 3
                then 'Kavish pickup is handled separately by Santhosh for swimming.'
            end
        )),
        case
            when k.kind = 'afternoon_pickup' and a.weekday_num = 3
                then array['Thanishka','Saanvi','Ishi']::text[]
            else array['Thanishka','Kavish','Saanvi','Ishi']::text[]
        end,
        false
    from assigned_days a
    cross join (values ('morning_drop'::text), ('afternoon_pickup'::text)) k(kind)
    left join public.kcp_roster_slots r
      on r.group_id = p_group_id
     and r.parent_name = a.driver_name;

    perform public.kcp_write_audit(
        p_group_id,
        'schedule_generated',
        'schedule_version',
        new_version::text,
        jsonb_build_object(
            'reason', p_reason,
            'policy', 'fixed_weekday_friday_rotation',
            'firstDay', first_day,
            'lastDay', last_day
        )
    );

    return new_version;
end;
$$;

create or replace function public.kcp_generate_schedule(
    p_group_id uuid,
    p_reason text default 'Schedule generated from approved constraints'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    policy_name text;
begin
    select schedule_policy into policy_name
    from public.kcp_groups
    where id = p_group_id;

    if not found then raise exception 'Group not found'; end if;

    if policy_name = 'fixed_weekday_friday_rotation' then
        return public.kcp_generate_fixed_schedule(p_group_id, p_reason);
    end if;

    return public.kcp_generate_balanced_schedule(p_group_id, p_reason);
end;
$$;

revoke all on function public.kcp_generate_fixed_schedule(uuid,text) from public, anon;
revoke all on function public.kcp_generate_balanced_schedule(uuid,text) from public, anon;
revoke all on function public.kcp_generate_schedule(uuid,text) from public, anon;
grant execute on function public.kcp_generate_schedule(uuid,text) to authenticated;

commit;
