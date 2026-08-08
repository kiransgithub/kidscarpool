begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('7d111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','fair.owner@example.com',now(),'{}','{}',now(),now(),false),
('7d222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','fair.parent@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('7d111111-1111-4111-8111-111111111111'::uuid,'Fair Owner','fair.owner@example.com',now()),
('7d222222-2222-4222-8222-222222222222'::uuid,'Fair Parent','fair.parent@example.com',now());

select auth.become('7d111111-1111-4111-8111-111111111111'::uuid);
create temporary table fairness_fixture(group_id uuid, owner_participant uuid, parent_participant uuid, parent_token text, no_points_trip uuid);
insert into fairness_fixture(group_id, owner_participant)
select created.group_id, created.owner_participant_id
from public.kcp_create_group_v3(
    'Fairness group','other','Community destination','Pilot',
    'America/Phoenix','Owner child','Level 1'
) created;

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from fairness_fixture), 'Fair Parent', 'parent',
        null, null, 'Parent child', 4, true, 14
    ) as row
)
update fairness_fixture set parent_token = (select (row).token from invitation);

select auth.become('7d222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation((select parent_token from fairness_fixture),'Fair Parent',null);
update fairness_fixture fixture
set parent_participant = participant.id
from public.kcp_group_participants participant
where participant.group_id = fixture.group_id
  and participant.user_id = '7d222222-2222-4222-8222-222222222222'::uuid;

select auth.become('7d111111-1111-4111-8111-111111111111'::uuid);
update public.kcp_groups
set current_schedule_version = 1,
    auto_complete_after_minutes = 60
where id = (select group_id from fairness_fixture);

-- Two completed Owner rides with two children each.
insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
    status, scheduled_time, time_label, child_names,
    started_at, completed_at, started_source, completed_source
)
select group_id, 1, current_date - 3, 'morning_drop', 'outbound', 'Completed A1',
       '7d111111-1111-4111-8111-111111111111'::uuid, 'Fair Owner', owner_participant,
       'completed', now() - interval '3 days', 'Past', array['Owner child','Parent child']::text[],
       now() - interval '3 days 1 hour', now() - interval '3 days', 'manual','manual'
from fairness_fixture
union all
select group_id, 1, current_date - 2, 'morning_drop', 'outbound', 'Completed A2',
       '7d111111-1111-4111-8111-111111111111'::uuid, 'Fair Owner', owner_participant,
       'completed', now() - interval '2 days', 'Past', array['Owner child','Parent child']::text[],
       now() - interval '2 days 1 hour', now() - interval '2 days', 'manual','manual'
from fairness_fixture;

-- One volunteer completion for Parent.
insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
    actual_driver_id, actual_driver_name, actual_participant_id,
    volunteer_assignment, status, scheduled_time, time_label, child_names,
    started_at, completed_at, started_source, completed_source
)
select group_id, 1, current_date - 1, 'afternoon_pickup', 'return', 'Volunteer completion',
       '7d111111-1111-4111-8111-111111111111'::uuid, 'Fair Owner', owner_participant,
       '7d222222-2222-4222-8222-222222222222'::uuid, 'Fair Parent', parent_participant,
       true, 'completed', now() - interval '1 day', 'Past', array['Parent child']::text[],
       now() - interval '1 day 1 hour', now() - interval '1 day', 'manual','manual'
from fairness_fixture;

-- One upcoming Owner assignment.
insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
    status, scheduled_time, time_label, child_names
)
select group_id, 1, current_date + 1, 'morning_drop', 'outbound', 'Upcoming',
       '7d111111-1111-4111-8111-111111111111'::uuid, 'Fair Owner', owner_participant,
       'scheduled', now() + interval '1 day', 'Future', array['Owner child']::text[]
from fairness_fixture;

insert into public.kcp_points_ledger(group_id, trip_id, user_id, points, reason)
select trip.group_id, trip.id,
       coalesce(trip.actual_driver_id, trip.scheduled_driver_id),
       case when trip.volunteer_assignment then 20 else 10 end,
       case when trip.volunteer_assignment then 'volunteer_trip' else 'scheduled_trip' end
from public.kcp_trips trip
where trip.group_id = (select group_id from fairness_fixture)
  and trip.status = 'completed';

do $$
declare
    owner_row record;
    parent_row record;
begin
    select * into owner_row
    from public.kcp_group_fairness((select group_id from fairness_fixture))
    where user_id = '7d111111-1111-4111-8111-111111111111'::uuid;
    select * into parent_row
    from public.kcp_group_fairness((select group_id from fairness_fixture))
    where user_id = '7d222222-2222-4222-8222-222222222222'::uuid;

    if owner_row.completed_rides <> 2
       or owner_row.upcoming_assigned <> 1
       or owner_row.estimated_minutes <> 120
       or owner_row.children_transported <> 4 then
        raise exception 'Owner fairness metrics are incorrect: %', row_to_json(owner_row);
    end if;
    if parent_row.completed_rides <> 1
       or parent_row.volunteer_rides <> 1
       or parent_row.points <> 20 then
        raise exception 'Parent fairness or points metrics are incorrect: %', row_to_json(parent_row);
    end if;
    if owner_row.fairness_units <= parent_row.fairness_units then
        raise exception 'Weighted workload did not reflect the larger completed load';
    end if;
end;
$$;

-- Disable public participation. A Parent sees only their own row; Admin retains all.
select public.kcp_set_participation_settings(
    (select group_id from fairness_fixture), true, false, 0.25, 0.05
);

select auth.become('7d222222-2222-4222-8222-222222222222'::uuid);

do $$
begin
    if (select count(*) from public.kcp_group_fairness((select group_id from fairness_fixture))) <> 1 then
        raise exception 'Private participation view exposed other drivers';
    end if;
    if not exists (
        select 1 from public.kcp_group_fairness((select group_id from fairness_fixture))
        where user_id = auth.uid()
    ) then
        raise exception 'Parent cannot see their own private participation summary';
    end if;
end;
$$;

select auth.become('7d111111-1111-4111-8111-111111111111'::uuid);

do $$
begin
    if (select count(*) from public.kcp_group_fairness((select group_id from fairness_fixture))) <> 2 then
        raise exception 'Owner lost the operational fairness view';
    end if;
end;
$$;

-- Disable points and verify a newly confirmed completion receives no points row.
select public.kcp_set_participation_settings(
    (select group_id from fairness_fixture), false, false, 0.25, 0.05
);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
        status, scheduled_time, time_label, child_names,
        started_at, completed_at, started_source, completed_source
    )
    select group_id, 1, current_date, 'morning_drop', 'outbound', 'No-points completion',
           '7d111111-1111-4111-8111-111111111111'::uuid, 'Fair Owner', owner_participant,
           'completed', now(), 'Now', array['Owner child']::text[],
           now() - interval '30 minutes', now(), 'manual','manual'
    from fairness_fixture returning id
)
update fairness_fixture set no_points_trip = (select id from trip);

select public.kcp_award_confirmed_trip_points((select no_points_trip from fairness_fixture));

do $$
begin
    if exists (
        select 1 from public.kcp_points_ledger
        where trip_id = (select no_points_trip from fairness_fixture)
    ) then
        raise exception 'Disabled gamification still awarded points';
    end if;
    if not exists (
        select 1 from public.kcp_my_fairness_summary()
        where group_id = (select group_id from fairness_fixture)
          and completed_rides >= 3
          and not points_enabled
    ) then
        raise exception 'Personal all-group fairness summary is incomplete';
    end if;
end;
$$;

rollback;

select 'PASS: workload fairness and optional points verified' as result;
