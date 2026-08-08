-- Verifies that Saturday/Sunday are first-class scheduling and availability
-- days in the consolidated schema. All test rows are rolled back.

begin;

\set QUIET on
\pset pager off

do $$
declare
    v_owner uuid := gen_random_uuid();
    v_group public.kcp_groups;
    v_plan uuid;
    v_owner_pid uuid;
    v_policy uuid;
    v_request uuid;
    v_occurrences integer;
    v_saturday_times time[];
    v_sunday_times time[];
begin
    insert into auth.users(id) values (v_owner);
    perform auth.become(v_owner);
    perform public.kcp_upsert_profile('Weekend Owner');

    v_group := public.kcp_create_group(
        'Weekend Activity Carpool',
        'activity',
        'America/Phoenix'
    );
    v_owner_pid := public.kcp_current_participant_id(v_group.id);

    select id into v_plan
    from public.kcp_schedule_plans
    where group_id = v_group.id and status = 'draft';

    update public.kcp_schedule_plans
       set starts_on = date '2030-01-05',
           ends_on = date '2030-01-06',
           outbound_label = 'Activity drop-off',
           return_label = 'Activity pickup'
     where id = v_plan;

    insert into public.kcp_recurring_sessions(
        schedule_plan_id, name, weekday,
        outbound_time, return_time, display_order
    ) values
        (v_plan, 'Saturday activity', 6, time '09:15', time '10:45', 1),
        (v_plan, 'Sunday activity',   7, time '16:30', time '18:00', 2);

    insert into public.kcp_assignment_policies(
        schedule_plan_id, strategy, fixed_participant_id, anchor_date
    ) values (
        v_plan, 'fixed', v_owner_pid, date '2030-01-05'
    ) returning id into v_policy;

    insert into public.kcp_assignment_policy_members(
        policy_id, participant_id, rotation_position
    ) values (v_policy, v_owner_pid, 1);

    select count(*) into v_occurrences
    from public.kcp_plan_occurrences(
        v_plan, date '2030-01-05', date '2030-01-06', 20
    );
    assert v_occurrences = 4,
        format('expected four weekend ride legs, found %s', v_occurrences);

    select array_agg(local_time order by local_time)
      into v_saturday_times
      from public.kcp_plan_occurrences(
          v_plan, date '2030-01-05', date '2030-01-06', 20
      )
     where service_date = date '2030-01-05';
    assert v_saturday_times = array[time '09:15', time '10:45'],
        format('Saturday times were %s', v_saturday_times);

    select array_agg(local_time order by local_time)
      into v_sunday_times
      from public.kcp_plan_occurrences(
          v_plan, date '2030-01-05', date '2030-01-06', 20
      )
     where service_date = date '2030-01-06';
    assert v_sunday_times = array[time '16:30', time '18:00'],
        format('Sunday times were %s', v_sunday_times);

    v_request := public.kcp_submit_constraint_request(
        v_group.id,
        array[6,7]::smallint[],
        array[6,7]::smallint[],
        'Available on both weekend days'
    );
    perform public.kcp_review_constraint_request(v_request, true, 'Approved');

    assert (
        select drop_weekdays = array[6,7]::smallint[]
           and pickup_weekdays = array[6,7]::smallint[]
           and status = 'approved'
        from public.kcp_constraints
        where id = v_request
    ), 'Saturday/Sunday availability was not preserved';

    assert not public.kcp_can_start_trip_at(
        timestamptz '2030-01-05 09:15:00-07',
        timestamptz '2030-01-05 09:04:59-07'
    ), 'start gate opened earlier than ten minutes';

    assert public.kcp_can_start_trip_at(
        timestamptz '2030-01-05 09:15:00-07',
        timestamptz '2030-01-05 09:05:00-07'
    ), 'start gate did not open at exactly ten minutes';

    raise notice 'PASS: weekend schedule, times, availability and start gate';
end;
$$;

rollback;
