begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values (
    '77111111-1111-4111-8111-111111111111'::uuid,
    'authenticated','authenticated','trip.state@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values ('77111111-1111-4111-8111-111111111111'::uuid, 'Trip State Driver', 'trip.state@example.com', now());

select auth.become('77111111-1111-4111-8111-111111111111'::uuid);

create temporary table state_fixture(group_id uuid, explicit_trip uuid, unattended_trip uuid, admin_trip uuid);
insert into state_fixture(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Safe trip state group','other','Community destination','Pilot',
    'America/Phoenix','Rider','Level 1'
) created;

update public.kcp_groups
set current_schedule_version = 1,
    auto_lifecycle_enabled = true,
    auto_complete_after_minutes = 5
where id = (select group_id from state_fixture);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names
    )
    select group_id, 1, current_date, 'morning_drop', 'outbound', 'Explicit ride',
           '77111111-1111-4111-8111-111111111111'::uuid, 'Trip State Driver',
           'scheduled', now() + interval '5 minutes', 'Soon', array['Rider']::text[]
    from state_fixture
    returning id
)
update state_fixture set explicit_trip = (select id from trip);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names
    )
    select group_id, 1, current_date, 'afternoon_pickup', 'return', 'Unattended ride',
           '77111111-1111-4111-8111-111111111111'::uuid, 'Trip State Driver',
           'scheduled', now() - interval '10 minutes', 'Past', array['Rider']::text[]
    from state_fixture
    returning id
)
update state_fixture set unattended_trip = (select id from trip);

-- Time passage requests confirmation; it never starts, completes or awards.
select public.kcp_process_trip_lifecycle(now(), (select group_id from state_fixture));

do $$
begin
    if (select status from public.kcp_trips where id = (select unattended_trip from state_fixture)) <> 'confirmation_due' then
        raise exception 'Unattended ride should be confirmation_due';
    end if;
    if exists (select 1 from public.kcp_points_ledger where trip_id = (select unattended_trip from state_fixture)) then
        raise exception 'Unattended ride received points';
    end if;
    if (select started_at from public.kcp_trips where id = (select unattended_trip from state_fixture)) is not null
       or (select completed_at from public.kcp_trips where id = (select unattended_trip from state_fixture)) is not null then
        raise exception 'Lifecycle inferred factual ride activity';
    end if;
end;
$$;

-- Explicit driver flow: confirm -> ready -> start -> arrival -> confirmation -> points.
select public.kcp_confirm_trip((select explicit_trip from state_fixture));

do $$
begin
    if (select status from public.kcp_trips where id = (select explicit_trip from state_fixture)) <> 'ready' then
        raise exception 'Driver confirmation did not produce ready state';
    end if;
end;
$$;

select public.kcp_start_trip((select explicit_trip from state_fixture));

-- Simulate enough elapsed ride time for the test without sleeping.
update public.kcp_trips
set started_at = now() - interval '4 minutes'
where id = (select explicit_trip from state_fixture);

select public.kcp_complete_trip((select explicit_trip from state_fixture));

do $$
begin
    if (select status from public.kcp_trips where id = (select explicit_trip from state_fixture)) <> 'completion_due' then
        raise exception 'Arrival report should create completion_due';
    end if;
    if exists (select 1 from public.kcp_points_ledger where trip_id = (select explicit_trip from state_fixture)) then
        raise exception 'Arrival report awarded points before explicit completion';
    end if;
end;
$$;

select public.kcp_confirm_trip_completion((select explicit_trip from state_fixture));
select public.kcp_confirm_trip_completion((select explicit_trip from state_fixture))
where false;

do $$
begin
    if (select status from public.kcp_trips where id = (select explicit_trip from state_fixture)) <> 'completed' then
        raise exception 'Explicit completion confirmation did not complete the ride';
    end if;
    if (select count(*) from public.kcp_points_ledger where trip_id = (select explicit_trip from state_fixture)) <> 1 then
        raise exception 'Confirmed ride must have exactly one points row';
    end if;
    if (select points from public.kcp_points_ledger where trip_id = (select explicit_trip from state_fixture)) <> 10 then
        raise exception 'Scheduled confirmed ride should award 10 points';
    end if;
    if not exists (
        select 1 from public.kcp_trip_events
        where trip_id = (select explicit_trip from state_fixture)
          and event_type = 'completion_confirmed'
    ) then
        raise exception 'Explicit completion event was not recorded';
    end if;
end;
$$;

-- Administrative resolution requires a note and remains auditable.
with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names, started_at, started_source, completion_due_at
    )
    select group_id, 1, current_date, 'afternoon_pickup', 'return', 'Admin resolution ride',
           '77111111-1111-4111-8111-111111111111'::uuid, 'Trip State Driver',
           'completion_due', now() - interval '30 minutes', 'Past', array['Rider']::text[],
           now() - interval '20 minutes', 'manual', now() - interval '5 minutes'
    from state_fixture
    returning id
)
update state_fixture set admin_trip = (select id from trip);

select public.kcp_admin_confirm_trip_completion(
    (select admin_trip from state_fixture),
    'Driver confirmed arrival by phone after app issue'
);

do $$
begin
    if (select completed_source from public.kcp_trips where id = (select admin_trip from state_fixture)) <> 'admin' then
        raise exception 'Administrative confirmation source was not recorded';
    end if;
    if not exists (
        select 1 from public.kcp_trip_events
        where trip_id = (select admin_trip from state_fixture)
          and event_type = 'admin_completion_confirmed'
    ) then
        raise exception 'Administrative completion event was not recorded';
    end if;
end;
$$;

-- Completion-due rides become unconfirmed, never automatically completed.
update public.kcp_trips
set status = 'completion_due', completed_at = null, completed_source = null,
    completion_due_at = now() - interval '3 hours'
where id = (select unattended_trip from state_fixture);
select public.kcp_process_trip_lifecycle(now(), (select group_id from state_fixture));

do $$
begin
    if (select status from public.kcp_trips where id = (select unattended_trip from state_fixture)) <> 'unconfirmed' then
        raise exception 'Overdue completion should become unconfirmed';
    end if;
    if exists (select 1 from public.kcp_points_ledger where trip_id = (select unattended_trip from state_fixture)) then
        raise exception 'Unconfirmed ride received points';
    end if;
end;
$$;

rollback;

select 'PASS: safe trip state machine requires explicit completion' as result;
