-- ===========================================================================
-- Equivalence test: generic engine == legacy BASIS generator
--
-- This is the safety net for deleting kcp_roster_slots,
-- kcp_generate_fixed_schedule and kcp_generate_balanced_schedule.
--
-- `expected` below is an INDEPENDENT restatement of the legacy rule, written
-- straight from kcp_generate_fixed_schedule (migration 202608060008):
--   * school days = Mon..Fri between 2026-08-10 and last_day,
--     excluding no_school ranges
--   * Mon->Kiran, Tue->Santhosh, Wed->Mohan, Thu->Pavan
--   * Fri -> (array[Kiran,Santhosh,Mohan,Pavan])[((friday_seq - 1) % 4) + 1]
--   * drop 07:00, pickup 15:35 America/Phoenix
--
-- It deliberately does NOT call the old function, so the test still passes
-- after that function is deleted.
--
-- Prereqs: baseline applied, supabase/seeds/basis_pilot.sql run.
-- Usage:   psql -d kcp -v ON_ERROR_STOP=1 -f this_file
-- ===========================================================================

\set QUIET on
\pset pager off

do $$
declare
    v_group uuid;
    v_plan  uuid;
    v_owner uuid;
    v_mismatch integer;
    v_expected integer;
    v_actual   integer;
    r record;
begin
    select id into v_group from public.kcp_groups where code = 'BASIS1';
    if v_group is null then
        raise exception 'Run supabase/seeds/basis_pilot.sql first';
    end if;
    select id into v_plan from public.kcp_schedule_plans
     where group_id = v_group and version = 1;

    -- kcp_plan_occurrences is membership-gated, so act as the owner.
    insert into auth.users(id) values (gen_random_uuid())
        returning id into strict v_owner;
    insert into public.kcp_profiles(id, display_name)
        values (v_owner, 'Kiran') on conflict do nothing;
    update public.kcp_group_participants
       set user_id = v_owner
     where group_id = v_group and display_name = 'Kiran';
    insert into public.kcp_memberships(
        group_id, user_id, parent_name, child_name, role, status, joined_at
    ) values (
        v_group, v_owner, 'Kiran', null, 'owner', 'active', now()
    ) on conflict (group_id, user_id) do update
       set role = 'owner', status = 'active', joined_at = coalesce(public.kcp_memberships.joined_at, now());
    perform auth.become(v_owner);

    create temp table expected_rows on commit drop as
    with last_day as (
        select max(ev.end_date) as d
        from public.kcp_calendar_events ev
        join public.kcp_school_calendars cal on cal.id = ev.calendar_id
        where cal.group_id = v_group and ev.event_type = 'last_day'
    ), school_days as (
        select day_series::date as school_day,
               extract(isodow from day_series)::integer as weekday_num
        from last_day, generate_series(date '2026-08-10', last_day.d,
                                       interval '1 day') day_series
        where extract(isodow from day_series) between 1 and 5
          and not exists (
              select 1
              from public.kcp_calendar_events ev
              join public.kcp_school_calendars cal on cal.id = ev.calendar_id
              where cal.group_id = v_group
                and ev.event_type = 'no_school'
                and day_series::date between ev.start_date and ev.end_date)
    ), ranked as (
        select school_day, weekday_num,
               count(*) filter (where weekday_num = 5) over (
                   order by school_day
                   rows between unbounded preceding and current row
               ) as friday_sequence
        from school_days
    )
    select school_day as service_date,
           leg.leg_type,
           case weekday_num
               when 1 then 'Kiran' when 2 then 'Santhosh'
               when 3 then 'Mohan' when 4 then 'Pavan'
               when 5 then (array['Kiran','Santhosh','Mohan','Pavan'])[
                   (((friday_sequence - 1) % 4) + 1)::integer]
           end as driver_name
    from ranked
    cross join (values ('outbound'), ('return')) as leg(leg_type);

    create temp table actual_rows on commit drop as
    select occ.service_date, occ.leg_type, occ.participant_name as driver_name
    from public.kcp_plan_occurrences(v_plan, date '2026-08-10',
                                     date '2027-05-28', 5000) occ;

    select count(*) into v_expected from expected_rows;
    select count(*) into v_actual   from actual_rows;

    raise notice 'expected legs: %, generic legs: %', v_expected, v_actual;

    -- Full symmetric difference on (date, leg, driver).
    select count(*) into v_mismatch from (
        (select * from expected_rows except select * from actual_rows)
        union all
        (select * from actual_rows except select * from expected_rows)
    ) diff;

    if v_mismatch > 0 then
        raise notice '--- first 20 differing rows ---';
        for r in
            select 'legacy-only' as side, * from (
                select * from expected_rows except select * from actual_rows) a
            union all
            select 'generic-only', * from (
                select * from actual_rows except select * from expected_rows) b
            order by 2, 3 limit 20
        loop
            raise notice '% % % %', r.side, r.service_date, r.leg_type,
                                    r.driver_name;
        end loop;
        raise exception
            'EQUIVALENCE FAILED: % differing (date, leg, driver) rows',
            v_mismatch;
    end if;

    raise notice 'PASS: generic engine reproduces the BASIS schedule exactly (% legs)',
        v_actual;
end;
$$;
