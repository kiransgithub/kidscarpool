-- End-to-end local integration test for a generic, calendar-free group,
-- cover acceptance identity, automatic lifecycle and points.
-- Runs inside a transaction and rolls everything back.

begin;

-- Notification recipients are real application users, so keep the fixture
-- consistent with the production auth/profile relationship.
insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'authenticated', 'authenticated',
     'owner.lifecycle@example.com', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), false),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'authenticated', 'authenticated',
     'volunteer.lifecycle@example.com', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), false);

insert into public.kcp_profiles(id, display_name, phone)
values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'Owner Tester', '6025550101'),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'Volunteer Tester', '6025550102');

do $$
declare
    v_owner constant uuid := '11111111-1111-4111-8111-111111111111'::uuid;
    v_volunteer constant uuid := '22222222-2222-4222-8222-222222222222'::uuid;
    v_group_id uuid;
    v_group_code text;
    v_version integer;
    v_generated_trips integer;
    v_cover_trip uuid;
    v_regular_trip uuid;
    v_request_id uuid;
    v_points integer;
    v_status text;
    v_actual_driver uuid;
    v_actual_driver_name text;
    v_started_source text;
    v_completed_source text;
    v_calendar_count integer;
begin
    perform set_config('request.jwt.claim.sub', v_owner::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);

    select created.group_id, created.group_code
      into v_group_id, v_group_code
      from public.kcp_create_group_v2(
          p_name => 'Tennis Practice Pilot',
          p_group_kind => 'tennis',
          p_destination_name => 'Community Tennis Center',
          p_destination_key => 'community-tennis-center',
          p_term_label => 'Fall Training',
          p_schedule_start_date => date '2030-01-07',
          p_schedule_end_date => date '2030-01-18',
          p_service_weekdays => array[1,3,5]::smallint[],
          p_drop_time => time '17:00',
          p_pickup_time => time '19:00',
          p_auto_complete_after_minutes => 30,
          p_child_name => 'Owner Child',
          p_grade => 0,
          p_drop_weekdays => array[1,3,5]::smallint[],
          p_pickup_weekdays => array[1,3,5]::smallint[],
          p_notes => 'Calendar intentionally omitted'
      ) created;

    if v_group_id is null or v_group_code is null then
        raise exception 'Generic group creation returned no identity';
    end if;

    select count(*) into v_calendar_count
    from public.kcp_school_calendars
    where group_id = v_group_id;
    if v_calendar_count <> 0 then
        raise exception 'Generic group unexpectedly required or created a calendar';
    end if;

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade,
        role, status, joined_at
    ) values (
        v_group_id, v_volunteer, 'Volunteer Tester', '6025550102',
        'Volunteer Child', 0, 'parent', 'active', now()
    );

    insert into public.kcp_constraints(
        group_id, user_id, drop_weekdays, pickup_weekdays,
        notes, updated_by, effective_from
    ) values (
        v_group_id, v_volunteer,
        array[1,3,5]::smallint[], array[1,3,5]::smallint[],
        'Available for all tennis days', v_volunteer, date '2030-01-07'
    );

    select public.kcp_generate_schedule(
        v_group_id,
        'Integration test without a calendar'
    ) into v_version;

    select count(*) into v_generated_trips
    from public.kcp_trips
    where group_id = v_group_id
      and schedule_version = v_version;

    if v_generated_trips = 0 then
        raise exception 'Calendar-free recurring schedule generated no trips';
    end if;

    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind,
        scheduled_driver_id, scheduled_driver_name,
        status, scheduled_time, time_label, child_names
    ) values (
        v_group_id, v_version + 1000, current_date - 2, 'afternoon_pickup',
        v_owner, 'Owner Tester',
        'cover_requested', now() - interval '31 minutes', 'Test pickup',
        array['Owner Child','Volunteer Child']::text[]
    ) returning id into v_cover_trip;

    insert into public.kcp_cover_requests(
        group_id, trip_id, requested_by, note, status
    ) values (
        v_group_id, v_cover_trip, v_owner,
        'Owner needs a volunteer for the integration test', 'open'
    ) returning id into v_request_id;

    perform set_config('request.jwt.claim.sub', v_volunteer::text, true);
    perform public.kcp_accept_cover(v_request_id);

    select t.status, t.actual_driver_id, t.actual_driver_name
      into v_status, v_actual_driver, v_actual_driver_name
      from public.kcp_trips t
     where t.id = v_cover_trip;

    if v_status <> 'cover_accepted'
       or v_actual_driver <> v_volunteer
       or v_actual_driver_name <> 'Volunteer Tester' then
        raise exception 'Cover acceptance did not preserve volunteer identity: status %, id %, name %',
            v_status, v_actual_driver, v_actual_driver_name;
    end if;

    if not exists (
        select 1
        from public.kcp_cover_requests r
        where r.id = v_request_id
          and r.status = 'accepted'
          and r.accepted_by = v_volunteer
    ) then
        raise exception 'Requester cannot determine who accepted coverage';
    end if;

    -- Safety hardening requires the active driver to confirm, start, report
    -- arrival, and confirm completion explicitly.
    perform public.kcp_confirm_trip(v_cover_trip);
    perform public.kcp_start_trip(v_cover_trip);
    update public.kcp_trips set started_at = now() - interval '4 minutes'
     where id = v_cover_trip;
    perform public.kcp_complete_trip(v_cover_trip);
    perform public.kcp_confirm_trip_completion(v_cover_trip);

    select t.status, t.started_source, t.completed_source
      into v_status, v_started_source, v_completed_source
      from public.kcp_trips t
     where t.id = v_cover_trip;

    if v_status <> 'completed'
       or v_started_source <> 'manual'
       or v_completed_source <> 'manual' then
        raise exception 'Volunteer trip did not complete safely: status %, start %, complete %',
            v_status, v_started_source, v_completed_source;
    end if;

    select p.points into v_points
    from public.kcp_points_ledger p
    where p.trip_id = v_cover_trip;
    if v_points <> 20 then
        raise exception 'Volunteer completion expected 20 points, found %', v_points;
    end if;

    -- Repeat for a regular assigned trip and verify idempotent 10-point award.
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind,
        scheduled_driver_id, scheduled_driver_name,
        status, scheduled_time, time_label, child_names
    ) values (
        v_group_id, v_version + 1001, current_date - 2, 'morning_drop',
        v_owner, 'Owner Tester',
        'scheduled', now() - interval '31 minutes', 'Test drop',
        array['Owner Child','Volunteer Child']::text[]
    ) returning id into v_regular_trip;

    perform set_config('request.jwt.claim.sub', v_owner::text, true);
    perform public.kcp_confirm_trip(v_regular_trip);
    perform public.kcp_start_trip(v_regular_trip);
    update public.kcp_trips set started_at = now() - interval '4 minutes'
     where id = v_regular_trip;
    perform public.kcp_complete_trip(v_regular_trip);
    perform public.kcp_confirm_trip_completion(v_regular_trip);
    perform public.kcp_award_confirmed_trip_points(v_regular_trip);

    select p.points into v_points
    from public.kcp_points_ledger p
    where p.trip_id = v_regular_trip;
    if v_points <> 10 then
        raise exception 'Regular completion expected 10 points, found %', v_points;
    end if;

    if (select count(*) from public.kcp_points_ledger where trip_id = v_regular_trip) <> 1 then
        raise exception 'Repeated lifecycle processing created duplicate points';
    end if;

    if not exists (
        select 1
        from public.kcp_audit_events a
        where a.group_id = v_group_id
          and a.action = 'trip_completion_confirmed'
          and a.entity_id = v_cover_trip::text
    ) then
        raise exception 'Confirmed completion was not recorded in the audit trail';
    end if;
end;
$$;

rollback;

select 'PASS: generic group, optional calendar, cover identity, safe lifecycle and points verified' as result;
