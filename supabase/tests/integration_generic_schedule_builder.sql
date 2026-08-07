-- End-to-end generic schedule regression test.
-- Verifies owner creation, weekday-specific evening times, weekly bundled
-- rotation, calendar-free publishing, stable participant IDs, and versioning.
-- The test rolls back all disposable data.

begin;

set local session_replication_role = replica;
insert into public.kcp_profiles(id, display_name, phone)
values
    ('41111111-1111-4111-8111-111111111111'::uuid, 'Owner Driver', '6025550141'),
    ('42222222-2222-4222-8222-222222222222'::uuid, 'Second Driver', '6025550142');
set local session_replication_role = origin;

do $$
declare
    owner_user constant uuid := '41111111-1111-4111-8111-111111111111'::uuid;
    second_user constant uuid := '42222222-2222-4222-8222-222222222222'::uuid;
    target_group uuid;
    target_plan uuid;
    owner_participant uuid;
    second_participant uuid;
    first_schedule_version integer;
    second_schedule_version integer;
    trip_count integer;
    owner_count integer;
    second_count integer;
    calendar_count integer;
    fixed_owner_count integer;
    thursday_times time[];
    friday_times time[];
    week_one_drivers text[];
    week_two_drivers text[];
    week_three_drivers text[];
    cloned_plan uuid;
begin
    perform set_config('request.jwt.claim.sub', owner_user::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);

    select created.group_id, created.owner_participant_id, created.draft_plan_id
      into target_group, owner_participant, target_plan
      from public.kcp_create_group_v3(
          p_name => 'Evening Activity Carpool',
          p_group_kind => 'music',
          p_destination_name => 'Community Arts Center',
          p_term_label => 'Fall session',
          p_timezone => 'America/Phoenix',
          p_child_name => 'Owner Rider',
          p_grade_or_level => 'Intermediate'
      ) created;

    if target_group is null or target_plan is null or owner_participant is null then
        raise exception 'Generic group creation did not return group, owner participant and draft plan';
    end if;

    select count(*) into fixed_owner_count
    from public.kcp_memberships membership
    where membership.group_id = target_group
      and membership.user_id = owner_user
      and membership.role = 'owner'
      and membership.status = 'active';
    if fixed_owner_count <> 1 then
        raise exception 'Group creator must be the single active Owner; found %', fixed_owner_count;
    end if;

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade,
        role, status, invited_by, joined_at
    ) values (
        target_group,
        second_user,
        'Second Driver',
        '6025550142',
        'Second Rider',
        0,
        'parent',
        'active',
        owner_user,
        now()
    );

    select participant.id into second_participant
    from public.kcp_group_participants participant
    where participant.group_id = target_group
      and participant.user_id = second_user;

    if second_participant is null then
        raise exception 'Membership trigger did not create the second stable participant';
    end if;

    perform public.kcp_save_schedule_plan(
        p_plan_id => target_plan,
        p_name => 'Two-evening weekly rotation',
        p_starts_on => date '2026-08-10',
        p_ends_on => date '2026-08-28',
        p_outbound_label => 'Class drop-off',
        p_return_label => 'Class pickup',
        p_auto_complete_after_minutes => 45,
        p_sessions => jsonb_build_array(
            jsonb_build_object(
                'name', 'Thursday class',
                'weekday', 4,
                'intervalWeeks', 1,
                'anchorDate', '2026-08-10',
                'outboundEnabled', true,
                'outboundTime', '18:30',
                'returnEnabled', true,
                'returnTime', '19:00',
                'returnDayOffset', 0,
                'displayOrder', 1
            ),
            jsonb_build_object(
                'name', 'Friday class',
                'weekday', 5,
                'intervalWeeks', 1,
                'anchorDate', '2026-08-10',
                'outboundEnabled', true,
                'outboundTime', '17:00',
                'returnEnabled', true,
                'returnTime', '18:00',
                'returnDayOffset', 0,
                'displayOrder', 2
            )
        ),
        p_strategy => 'round_robin_week',
        p_cycle_behavior => 'calendar',
        p_anchor_date => date '2026-08-10',
        p_participant_ids => array[owner_participant, second_participant],
        p_fixed_participant_id => null
    );

    select public.kcp_publish_schedule_plan(
        target_plan,
        'Generic weekly bundled rotation integration test'
    ) into first_schedule_version;

    if first_schedule_version <> 1 then
        raise exception 'Fresh generic group expected schedule version 1, found %', first_schedule_version;
    end if;

    select count(*) into calendar_count
    from public.kcp_school_calendars calendar
    where calendar.group_id = target_group;
    if calendar_count <> 0 then
        raise exception 'Generic schedule unexpectedly required or created a calendar';
    end if;

    select count(*) into trip_count
    from public.kcp_trips trip
    where trip.group_id = target_group
      and trip.schedule_version = first_schedule_version;
    if trip_count <> 12 then
        raise exception 'Expected 12 evening trip operations across three weeks, found %', trip_count;
    end if;

    select array_agg(
               (trip.scheduled_time at time zone 'America/Phoenix')::time
               order by trip.scheduled_time
           )
      into thursday_times
      from public.kcp_trips trip
     where trip.group_id = target_group
       and trip.schedule_version = first_schedule_version
       and trip.trip_date = date '2026-08-13';
    if thursday_times <> array[time '18:30', time '19:00'] then
        raise exception 'Thursday times are incorrect: %', thursday_times;
    end if;

    select array_agg(
               (trip.scheduled_time at time zone 'America/Phoenix')::time
               order by trip.scheduled_time
           )
      into friday_times
      from public.kcp_trips trip
     where trip.group_id = target_group
       and trip.schedule_version = first_schedule_version
       and trip.trip_date = date '2026-08-14';
    if friday_times <> array[time '17:00', time '18:00'] then
        raise exception 'Friday times are incorrect: %', friday_times;
    end if;

    select array_agg(distinct trip.scheduled_driver_name order by trip.scheduled_driver_name)
      into week_one_drivers
      from public.kcp_trips trip
     where trip.group_id = target_group
       and trip.schedule_version = first_schedule_version
       and trip.trip_date between date '2026-08-10' and date '2026-08-16';

    select array_agg(distinct trip.scheduled_driver_name order by trip.scheduled_driver_name)
      into week_two_drivers
      from public.kcp_trips trip
     where trip.group_id = target_group
       and trip.schedule_version = first_schedule_version
       and trip.trip_date between date '2026-08-17' and date '2026-08-23';

    select array_agg(distinct trip.scheduled_driver_name order by trip.scheduled_driver_name)
      into week_three_drivers
      from public.kcp_trips trip
     where trip.group_id = target_group
       and trip.schedule_version = first_schedule_version
       and trip.trip_date between date '2026-08-24' and date '2026-08-30';

    if week_one_drivers <> array['Owner Driver']::text[] then
        raise exception 'Week 1 must remain bundled to Owner Driver, found %', week_one_drivers;
    end if;
    if week_two_drivers <> array['Second Driver']::text[] then
        raise exception 'Week 2 must remain bundled to Second Driver, found %', week_two_drivers;
    end if;
    if week_three_drivers <> array['Owner Driver']::text[] then
        raise exception 'Week 3 must rotate back to Owner Driver, found %', week_three_drivers;
    end if;

    select count(*) into owner_count
    from public.kcp_trips trip
    where trip.group_id = target_group
      and trip.schedule_version = first_schedule_version
      and trip.scheduled_participant_id = owner_participant;

    select count(*) into second_count
    from public.kcp_trips trip
    where trip.group_id = target_group
      and trip.schedule_version = first_schedule_version
      and trip.scheduled_participant_id = second_participant;

    if owner_count <> 8 or second_count <> 4 then
        raise exception 'Stable participant distribution expected 8/4, found %/%', owner_count, second_count;
    end if;

    if exists (
        select 1
        from public.kcp_trips trip
        where trip.group_id = target_group
          and trip.schedule_version = first_schedule_version
          and (
              trip.leg_type not in ('outbound','return')
              or trip.display_label not in ('Class drop-off','Class pickup')
              or trip.schedule_plan_id <> target_plan
              or trip.recurring_session_id is null
              or trip.responsibility_block_id is null
          )
    ) then
        raise exception 'Generated trips are missing generic leg, label, plan, session, or responsibility-block metadata';
    end if;

    select public.kcp_get_or_create_draft_plan(target_group) into cloned_plan;
    if cloned_plan = target_plan then
        raise exception 'Editing a published plan must create a new draft version';
    end if;

    perform public.kcp_save_schedule_plan(
        p_plan_id => cloned_plan,
        p_name => 'Two-evening weekly rotation v2',
        p_starts_on => date '2026-08-10',
        p_ends_on => date '2026-08-28',
        p_outbound_label => 'Class drop-off',
        p_return_label => 'Class pickup',
        p_auto_complete_after_minutes => 45,
        p_sessions => jsonb_build_array(
            jsonb_build_object(
                'name', 'Thursday class', 'weekday', 4,
                'intervalWeeks', 1, 'anchorDate', '2026-08-10',
                'outboundEnabled', true, 'outboundTime', '18:30',
                'returnEnabled', true, 'returnTime', '19:00',
                'returnDayOffset', 0, 'displayOrder', 1
            ),
            jsonb_build_object(
                'name', 'Friday class', 'weekday', 5,
                'intervalWeeks', 1, 'anchorDate', '2026-08-10',
                'outboundEnabled', true, 'outboundTime', '17:00',
                'returnEnabled', true, 'returnTime', '18:00',
                'returnDayOffset', 0, 'displayOrder', 2
            )
        ),
        p_strategy => 'round_robin_week',
        p_cycle_behavior => 'calendar',
        p_anchor_date => date '2026-08-10',
        p_participant_ids => array[owner_participant, second_participant],
        p_fixed_participant_id => null
    );

    select public.kcp_publish_schedule_plan(cloned_plan, 'Versioning regression')
      into second_schedule_version;

    if second_schedule_version <> 2 then
        raise exception 'Second publication expected schedule version 2, found %', second_schedule_version;
    end if;

    if (select count(*) from public.kcp_trips where group_id = target_group and schedule_version = 1) <> 12
       or (select count(*) from public.kcp_trips where group_id = target_group and schedule_version = 2) <> 12 then
        raise exception 'Publishing version 2 must retain version 1 trips for audit';
    end if;

    if not exists (
        select 1
        from public.kcp_audit_events audit
        where audit.group_id = target_group
          and audit.action = 'schedule_plan_published'
          and audit.entity_id = cloned_plan::text
    ) then
        raise exception 'Generic plan publication was not written to the audit trail';
    end if;
end;
$$;

rollback;

select 'PASS: generic owner, evening sessions, weekly bundle rotation and schedule versioning verified' as result;
