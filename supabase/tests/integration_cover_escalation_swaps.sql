begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('7a111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','swap.a@example.com',now(),'{}','{}',now(),now(),false),
('7a222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','swap.b@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('7a111111-1111-4111-8111-111111111111'::uuid,'Driver A','swap.a@example.com',now()),
('7a222222-2222-4222-8222-222222222222'::uuid,'Driver B','swap.b@example.com',now());

select auth.become('7a111111-1111-4111-8111-111111111111'::uuid);
create temporary table operation_fixture(group_id uuid, participant_a uuid, participant_b uuid, token_b text, cover_trip uuid, cover_request uuid, trip_a uuid, trip_b uuid, swap_id uuid);
insert into operation_fixture(group_id, participant_a)
select created.group_id, created.owner_participant_id
from public.kcp_create_group_v3(
    'Cover and swap group','other','Community destination','Pilot',
    'America/Phoenix','Child A','Level 1'
) created;

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from operation_fixture), 'Driver B', 'parent',
        null, null, 'Child B', 4, true, 14
    ) as row
)
update operation_fixture set token_b = (select (row).token from invitation);

select auth.become('7a222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation((select token_b from operation_fixture),'Driver B',null);
update operation_fixture fixture
set participant_b = participant.id
from public.kcp_group_participants participant
where participant.group_id = fixture.group_id and participant.user_id = '7a222222-2222-4222-8222-222222222222'::uuid;

select auth.become('7a111111-1111-4111-8111-111111111111'::uuid);
update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from operation_fixture);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
        status, scheduled_time, time_label, child_names
    )
    select group_id, 1, current_date, 'morning_drop', 'outbound', 'Cover ride',
           '7a111111-1111-4111-8111-111111111111'::uuid, 'Driver A', participant_a,
           'scheduled', now() + interval '50 minutes', 'Soon', array['Child A','Child B']::text[]
    from operation_fixture
    returning id
)
update operation_fixture set cover_trip = (select id from trip);

update operation_fixture
set cover_request = public.kcp_request_cover(cover_trip, 'Appointment conflict');
select public.kcp_process_cover_escalations(now(), (select group_id from operation_fixture));

do $$
begin
    if (select escalation_stage from public.kcp_cover_requests where id = (select cover_request from operation_fixture)) <> 'eligible_drivers' then
        raise exception '50-minute cover request did not escalate to eligible drivers';
    end if;
    if (select respond_by from public.kcp_cover_requests where id = (select cover_request from operation_fixture)) is null then
        raise exception 'Cover response deadline was not set';
    end if;
end;
$$;

select auth.become('7a222222-2222-4222-8222-222222222222'::uuid);
select public.kcp_accept_cover((select cover_request from operation_fixture));
select public.kcp_process_cover_escalations(now(), (select group_id from operation_fixture));

do $$
begin
    if (select escalation_stage from public.kcp_cover_requests where id = (select cover_request from operation_fixture)) <> 'resolved' then
        raise exception 'Accepted cover was not marked resolved';
    end if;
    if (select status from public.kcp_trips where id = (select cover_trip from operation_fixture)) <> 'cover_accepted' then
        raise exception 'Accepted cover did not update the ride';
    end if;
end;
$$;

-- Future swap pair assigned to different drivers.
select auth.become('7a111111-1111-4111-8111-111111111111'::uuid);
with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
        status, scheduled_time, time_label, child_names, confirmed_at, confirmed_by
    )
    select group_id, 1, current_date + 2, 'morning_drop', 'outbound', 'Ride A',
           '7a111111-1111-4111-8111-111111111111'::uuid, 'Driver A', participant_a,
           'ready', now() + interval '2 days', 'Future', array['Child A']::text[], now(),
           '7a111111-1111-4111-8111-111111111111'::uuid
    from operation_fixture
    returning id
)
update operation_fixture set trip_a = (select id from trip);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
        status, scheduled_time, time_label, child_names, confirmed_at, confirmed_by
    )
    select group_id, 1, current_date + 3, 'afternoon_pickup', 'return', 'Ride B',
           '7a222222-2222-4222-8222-222222222222'::uuid, 'Driver B', participant_b,
           'ready', now() + interval '3 days', 'Future', array['Child B']::text[], now(),
           '7a222222-2222-4222-8222-222222222222'::uuid
    from operation_fixture
    returning id
)
update operation_fixture set trip_b = (select id from trip);

update operation_fixture
set swap_id = public.kcp_create_trip_swap(trip_a, trip_b, 'Exchange these two days');

select auth.become('7a222222-2222-4222-8222-222222222222'::uuid);
select public.kcp_respond_trip_swap((select swap_id from operation_fixture), true, null);

do $$
begin
    if (select scheduled_driver_id from public.kcp_trips where id = (select trip_a from operation_fixture)) <> '7a222222-2222-4222-8222-222222222222'::uuid then
        raise exception 'Offered ride did not move to Driver B';
    end if;
    if (select scheduled_driver_id from public.kcp_trips where id = (select trip_b from operation_fixture)) <> '7a111111-1111-4111-8111-111111111111'::uuid then
        raise exception 'Requested ride did not move to Driver A';
    end if;
    if exists (
        select 1 from public.kcp_trips
        where id in ((select trip_a from operation_fixture),(select trip_b from operation_fixture))
          and (status <> 'scheduled' or confirmed_at is not null)
    ) then
        raise exception 'Swap did not reset driver confirmation safely';
    end if;
    if (select status from public.kcp_trip_swap_requests where id = (select swap_id from operation_fixture)) <> 'accepted' then
        raise exception 'Swap request did not become accepted';
    end if;
end;
$$;

rollback;

select 'PASS: cover escalation and coordinated swaps verified' as result;
