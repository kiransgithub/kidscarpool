-- ===========================================================================
-- BASIS Phoenix Primary 2026-27 pilot — seed DATA.
--
-- This file contains no scheduling logic. The pilot's rules
--   Mon..Thu = one fixed parent each, Fri = 4-way rotation
-- are expressed entirely as rows in the generic engine's tables:
--   * 4 x kcp_assignment_policies(strategy='fixed'),  each scoped via
--     kcp_policy_sessions to one weekday session
--   * 1 x kcp_assignment_policies(strategy='round_robin_day') scoped to the
--     Friday session, with kcp_assignment_policy_members carrying the
--     rotation order that used to live in kcp_roster_slots
--
-- Idempotent: re-running drops and rebuilds the pilot group. Safe to run on
-- a fresh database as many times as needed during testing.
--
-- Usage (local):  psql -d kcp -f supabase/seeds/basis_pilot.sql
-- ===========================================================================

begin;

set local session_replication_role = replica;  -- defer owner invariant trigger

do $$
declare
    v_group   uuid;
    v_cal     uuid;
    v_plan    uuid;
    v_first   date := date '2026-08-10';   -- first carpool day (school starts 08-05)
    v_last    date := date '2027-05-28';
    v_parents text[] := array['Kiran','Santhosh','Mohan','Pavan'];
    v_pid     uuid[] := '{}';
    v_sess    uuid[] := '{}';
    v_policy  uuid;
    v_name    text;
    v_i       integer;
begin
    delete from public.kcp_groups where code = 'BASIS1';

    insert into public.kcp_groups(
        code, name, group_kind, school_key, school_name, academic_year, timezone)
    values ('BASIS1', 'BASIS Phoenix Primary Carpool', 'school', 'basis_phoenix_primary',
            'BASIS Phoenix Primary', '2026-27', 'America/Phoenix')
    returning id into v_group;

    -- ---- participants (roster pre-seeded; each is claimed via invitation) --
    foreach v_name in array v_parents loop
        insert into public.kcp_group_participants(
            group_id, display_name, role, status, source, can_drive)
        values (v_group, v_name,
                case when v_name = 'Kiran' then 'owner' else 'parent' end,
                'active', 'seed', true)
        returning id into strict v_policy;      -- reuse as scratch
        v_pid := v_pid || v_policy;
    end loop;

    update public.kcp_groups set created_by = null where id = v_group;

    -- ---- authoritative school calendar ------------------------------------
    insert into public.kcp_school_calendars(
        group_id, school_key, academic_year, source_sha256)
    values (v_group, 'basis_phoenix_primary', '2026-27',
            '3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464')
    returning id into v_cal;

    insert into public.kcp_calendar_events(
        calendar_id, event_type, title, start_date, end_date)
    values
      (v_cal,'first_day','First Day of School','2026-08-05','2026-08-05'),
      (v_cal,'no_school','Labor Day Break','2026-09-07','2026-09-07'),
      (v_cal,'early_release','Professional Development','2026-09-25','2026-09-25'),
      (v_cal,'early_release','Parent/Teacher Conferences','2026-10-07','2026-10-07'),
      (v_cal,'no_school','Fall Break','2026-10-12','2026-10-16'),
      (v_cal,'no_school','Veterans Day','2026-11-11','2026-11-11'),
      (v_cal,'no_school','Thanksgiving Break','2026-11-25','2026-11-30'),
      (v_cal,'early_release','Winter Break Early Release','2026-12-18','2026-12-18'),
      (v_cal,'no_late_bird','No Late Bird','2026-12-18','2026-12-18'),
      (v_cal,'no_school','Winter Break','2026-12-21','2027-01-01'),
      (v_cal,'no_school','MLK Day','2027-01-18','2027-01-18'),
      (v_cal,'early_release','Professional Development','2027-02-12','2027-02-12'),
      (v_cal,'no_school','Presidents Day','2027-02-15','2027-02-15'),
      (v_cal,'no_school','February Break','2027-02-22','2027-02-24'),
      (v_cal,'early_release','Parent/Teacher Conferences','2027-03-10','2027-03-10'),
      (v_cal,'no_school','Spring Break','2027-03-15','2027-03-19'),
      (v_cal,'early_release','Professional Development','2027-04-01','2027-04-01'),
      (v_cal,'no_school','April Break','2027-04-02','2027-04-05'),
      (v_cal,'project_week','Project Week','2027-05-24','2027-05-28'),
      (v_cal,'last_day','Last Day of School','2027-05-28','2027-05-28'),
      (v_cal,'no_late_bird','No Late Bird','2027-05-28','2027-05-28');

    -- ---- schedule plan -----------------------------------------------------
    insert into public.kcp_schedule_plans(
        group_id, version, name, status, starts_on, ends_on, timezone,
        outbound_label, return_label, created_by_participant_id)
    values (v_group, 1, 'BASIS 2026-27 carpool', 'draft', v_first, v_last,
            'America/Phoenix', 'Morning drop', 'Afternoon pickup', v_pid[1])
    returning id into v_plan;

    -- Five weekday sessions: drop 07:00, pickup 15:35.
    for v_i in 1..5 loop
        insert into public.kcp_recurring_sessions(
            schedule_plan_id, name, weekday,
            outbound_enabled, outbound_time,
            return_enabled, return_time, display_order)
        values (v_plan,
                to_char(date '2026-08-10' + (v_i - 1), 'FMDay'), v_i,
                true, time '07:00', true, time '15:35', v_i)
        returning id into v_policy;
        v_sess := v_sess || v_policy;
    end loop;

    -- ---- Mon..Thu: one fixed parent per weekday ---------------------------
    for v_i in 1..4 loop
        insert into public.kcp_assignment_policies(
            schedule_plan_id, name, strategy, fixed_participant_id,
            anchor_date, priority)
        values (v_plan, v_parents[v_i] || ' — fixed weekday', 'fixed',
                v_pid[v_i], v_first, 200)
        returning id into v_policy;

        insert into public.kcp_policy_sessions(policy_id, session_id)
        values (v_policy, v_sess[v_i]);

        insert into public.kcp_assignment_policy_members(
            policy_id, participant_id, rotation_position)
        values (v_policy, v_pid[v_i], 1);
    end loop;

    -- ---- Friday: four-way rotation, one turn per Friday --------------------
    insert into public.kcp_assignment_policies(
        schedule_plan_id, name, strategy, cycle_behavior, anchor_date, priority)
    values (v_plan, 'Friday rotation', 'round_robin_day', 'occurrence',
            v_first, 200)
    returning id into v_policy;

    insert into public.kcp_policy_sessions(policy_id, session_id)
    values (v_policy, v_sess[5]);

    for v_i in 1..4 loop
        insert into public.kcp_assignment_policy_members(
            policy_id, participant_id, rotation_position)
        values (v_policy, v_pid[v_i], v_i);
    end loop;

    -- ---- Early-release days shorten the pickup rather than blanking it -----
    -- The legacy generator emitted a NULL pickup time on early-release days,
    -- which surfaced in the UI as "time unknown". Modelling them as explicit
    -- change_time exceptions keeps every trip actionable. Adjust the 12:00
    -- placeholder once the school publishes exact early-release times.
    insert into public.kcp_schedule_exceptions(
        schedule_plan_id, session_id, exception_date, action,
        replacement_return_time, reason)
    select v_plan, null, gs::date, 'change_time', time '12:00', ev.title
    from public.kcp_calendar_events ev
    cross join lateral generate_series(ev.start_date, ev.end_date,
                                       interval '1 day') gs
    where ev.calendar_id = v_cal
      and ev.event_type in ('early_release','project_week')
      and extract(isodow from gs) between 1 and 5
      and gs::date between v_first and v_last;

    raise notice 'BASIS pilot seeded: group=% plan=% participants=%',
        v_group, v_plan, cardinality(v_pid);
end;
$$;

commit;
