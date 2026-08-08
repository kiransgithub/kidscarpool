begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values (
    '78111111-1111-4111-8111-111111111111'::uuid,
    'authenticated','authenticated','driver.mode@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, phone, account_email, identity_verified_at)
values ('78111111-1111-4111-8111-111111111111'::uuid, 'Driver Mode User', '6025550188', 'driver.mode@example.com', now());
select auth.become('78111111-1111-4111-8111-111111111111'::uuid);

create temporary table driver_fixture(group_id uuid, participant_id uuid, child_one uuid, child_two uuid, trip_id uuid);
insert into driver_fixture(group_id, participant_id)
select created.group_id, created.owner_participant_id
from public.kcp_create_group_v3(
    'Driver mode group','other','Community destination','Pilot',
    'America/Phoenix','Child One','Level 1'
) created;

update driver_fixture fixture
set child_one = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Child One';

with child as (
    insert into public.kcp_children(group_id, participant_id, name, grade_or_level, status)
    select group_id, participant_id, 'Child Two', 'Level 2', 'active' from driver_fixture
    returning id
)
update driver_fixture set child_two = (select id from child);

select public.kcp_upsert_child_safety_profile(
    (select child_one from driver_fixture), '100 First St', '500 Destination Ave', '[]'::jsonb,
    'Emergency One', '6025550101', 'booster', 'Carry rescue medication', 'Use lane A', true
);
select public.kcp_upsert_child_safety_profile(
    (select child_two from driver_fixture), '200 Second St', '500 Destination Ave', '[]'::jsonb,
    'Emergency Two', '6025550102', 'none', null, null, true
);
select public.kcp_upsert_driver_safety_profile(
    (select participant_id from driver_fixture), 'Driver Emergency', '6025550199', true, true, true, null
);
select public.kcp_upsert_vehicle(
    (select participant_id from driver_fixture), null, 'Driver mode SUV', 4, 1, 0, true
);
select public.kcp_set_group_safety_requirement((select group_id from driver_fixture), true);
update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from driver_fixture);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
        status, scheduled_time, time_label, child_names
    )
    select group_id, 1, current_date, 'morning_drop', 'outbound', 'Activity drop-off',
           '78111111-1111-4111-8111-111111111111'::uuid, 'Driver Mode User', participant_id,
           'scheduled', now() + interval '5 minutes', 'Soon',
           array['Child One','Child Two']::text[]
    from driver_fixture
    returning id
)
update driver_fixture set trip_id = (select id from trip);

select public.kcp_confirm_trip((select trip_id from driver_fixture));
select public.kcp_start_trip((select trip_id from driver_fixture));
update public.kcp_trips set started_at = now() - interval '4 minutes' where id = (select trip_id from driver_fixture);

select public.kcp_mark_child_trip_status(
    (select trip_id from driver_fixture), (select child_one from driver_fixture),
    'picked_up', 'driver-test-child-one', null, now()
);

-- Repeating the same client event cannot create a duplicate.
select public.kcp_mark_child_trip_status(
    (select trip_id from driver_fixture), (select child_one from driver_fixture),
    'picked_up', 'driver-test-child-one', null, now()
);

do $$
begin
    if (select count(*) from public.kcp_trip_events where client_event_id = 'driver-test-child-one') <> 1 then
        raise exception 'Client event id did not prevent duplicate pickup events';
    end if;

    begin
        perform public.kcp_report_destination_arrival(
            (select trip_id from driver_fixture), 'arrival-too-early', now()
        );
        raise exception 'Arrival unexpectedly allowed an unaccounted child';
    exception when others then
        if sqlerrm = 'Arrival unexpectedly allowed an unaccounted child' then raise; end if;
    end;
end;
$$;

select public.kcp_mark_child_trip_status(
    (select trip_id from driver_fixture), (select child_two from driver_fixture),
    'skipped', 'driver-test-child-two', 'Parent picked up separately', now()
);

select public.kcp_report_trip_issue(
    (select trip_id from driver_fixture), 'delay', 'Traffic delayed the pickup route',
    'driver-test-issue', now()
);

select public.kcp_report_destination_arrival(
    (select trip_id from driver_fixture), 'driver-test-arrival', now()
);

do $$
declare
    snapshot jsonb;
begin
    select public.kcp_driver_trip_snapshot((select trip_id from driver_fixture)) into snapshot;
    if jsonb_array_length(snapshot->'roster') <> 2 then
        raise exception 'Driver snapshot did not contain both children: %', snapshot;
    end if;
    if (snapshot->'trip'->>'status') <> 'completion_due' then
        raise exception 'Destination arrival did not request completion confirmation';
    end if;
    if not exists (
        select 1 from public.kcp_trip_events
        where trip_id = (select trip_id from driver_fixture)
          and event_type = 'arrived_destination'
    ) then
        raise exception 'Destination arrival event was not recorded';
    end if;
    if not exists (
        select 1 from public.kcp_trip_events
        where trip_id = (select trip_id from driver_fixture)
          and event_type = 'issue_reported'
    ) then
        raise exception 'Ride issue was not recorded';
    end if;
end;
$$;

rollback;

select 'PASS: driver-first execution and child accountability verified' as result;
