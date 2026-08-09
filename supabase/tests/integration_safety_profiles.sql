begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values (
    '75111111-1111-4111-8111-111111111111'::uuid,
    'authenticated','authenticated','safety.owner@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values ('75111111-1111-4111-8111-111111111111'::uuid, 'Safety Owner', 'safety.owner@example.com', now());

select auth.become('75111111-1111-4111-8111-111111111111'::uuid);

create temporary table safety_fixture(group_id uuid, participant_id uuid, child_one uuid, child_two uuid, vehicle_id uuid, trip_id uuid);

insert into safety_fixture(group_id, participant_id)
select created.group_id, created.owner_participant_id
from public.kcp_create_group_v3(
    'Safety profile group','other','Community destination','Pilot',
    'America/Phoenix','Rider One','Level 1'
) created;

update safety_fixture fixture
set child_one = child.id
from public.kcp_children child
where child.group_id = fixture.group_id
  and child.participant_id = fixture.participant_id
  and child.name = 'Rider One';

with inserted_child as (
    insert into public.kcp_children(group_id, participant_id, name, grade_or_level, status)
    select group_id, participant_id, 'Rider Two', 'Level 2', 'active'
    from safety_fixture
    returning id
)
update safety_fixture set child_two = (select id from inserted_child);

select public.kcp_upsert_child_safety_profile(
    (select child_one from safety_fixture),
    '100 Pickup St', '200 Destination Ave', '[]'::jsonb,
    'Emergency One', '6025550101', 'booster', null,
    'Use pickup lane A', true
);

select public.kcp_upsert_child_safety_profile(
    (select child_two from safety_fixture),
    '300 Pickup St', '200 Destination Ave', '[]'::jsonb,
    'Emergency Two', '6025550102', 'car_seat', 'Critical transport note',
    null, true
);

select public.kcp_upsert_driver_safety_profile(
    (select participant_id from safety_fixture),
    'Driver Emergency', '6025550199', true, true, true, null
);

with vehicle as (
    select public.kcp_upsert_vehicle(
        (select participant_id from safety_fixture), null,
        'Small test vehicle', 2, 0, 0, true
    ) as row
)
update safety_fixture set vehicle_id = (select (row).id from vehicle);

select public.kcp_set_group_safety_requirement((select group_id from safety_fixture), true);

update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from safety_fixture);

with inserted_trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names
    )
    select group_id, 1, current_date + 1, 'morning_drop', 'outbound', 'Outbound',
           '75111111-1111-4111-8111-111111111111'::uuid, 'Safety Owner',
           'scheduled', now() + interval '1 day', 'Test time',
           array['Rider One','Rider Two']::text[]
    from safety_fixture
    returning id
)
update safety_fixture set trip_id = (select id from inserted_trip);

do $$
declare
    status record;
begin
    select * into status
    from public.kcp_trip_capacity_status(
        (select trip_id from safety_fixture),
        (select participant_id from safety_fixture)
    );

    if status.eligible then
        raise exception 'Vehicle without booster and car-seat capacity must be ineligible';
    end if;
    if status.required_seats <> 2
       or status.required_boosters <> 1
       or status.required_car_seats <> 1 then
        raise exception 'Seat requirements were counted incorrectly: %', row_to_json(status);
    end if;
end;
$$;

select public.kcp_upsert_vehicle(
    (select participant_id from safety_fixture),
    (select vehicle_id from safety_fixture),
    'Ready test vehicle', 4, 1, 1, true
);

do $$
declare
    status record;
    profile jsonb;
begin
    select * into status
    from public.kcp_trip_capacity_status(
        (select trip_id from safety_fixture),
        (select participant_id from safety_fixture)
    );
    if not status.eligible then
        raise exception 'Compatible vehicle and completed driver profile should be eligible: %', row_to_json(status);
    end if;

    select public.kcp_my_safety_profile((select group_id from safety_fixture)) into profile;
    if jsonb_array_length(profile->'children') <> 2
       or jsonb_array_length(profile->'vehicles') <> 1
       or coalesce((profile->>'required')::boolean, false) is not true then
        raise exception 'Safety profile summary is incomplete: %', profile;
    end if;
end;
$$;

rollback;

select 'PASS: child, driver and vehicle safety profiles verified' as result;
