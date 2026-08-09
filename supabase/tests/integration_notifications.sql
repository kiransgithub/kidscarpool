begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('7b111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','notify.a@example.com',now(),'{}','{}',now(),now(),false),
('7b222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','notify.b@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('7b111111-1111-4111-8111-111111111111'::uuid,'Notify Owner','notify.a@example.com',now()),
('7b222222-2222-4222-8222-222222222222'::uuid,'Notify Driver','notify.b@example.com',now());

select auth.become('7b111111-1111-4111-8111-111111111111'::uuid);
create temporary table notify_fixture(group_id uuid, child_id uuid, token_b text, cover_trip uuid, request_id uuid, reminder_trip uuid);
insert into notify_fixture(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Notification group','other','Community destination','Pilot',
    'America/Phoenix','Notify Child','Level 1'
) created;
update notify_fixture fixture set child_id = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Notify Child';

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from notify_fixture), 'Notify Driver', 'parent',
        null, null, 'Driver Child', 4, true, 14
    ) as row
)
update notify_fixture set token_b = (select (row).token from invitation);

select auth.become('7b222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation((select token_b from notify_fixture),'Notify Driver',null);

select auth.become('7b111111-1111-4111-8111-111111111111'::uuid);
update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from notify_fixture);

with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names
    )
    select group_id, 1, current_date, 'morning_drop', 'outbound', 'Coverage ride',
           '7b111111-1111-4111-8111-111111111111'::uuid, 'Notify Owner',
           'scheduled', now() + interval '50 minutes', 'Soon', array['Notify Child','Driver Child']::text[]
    from notify_fixture returning id
)
update notify_fixture set cover_trip = (select id from trip);

update notify_fixture set request_id = public.kcp_request_cover(cover_trip,'Need help');

do $$
begin
    if not exists (
        select 1 from public.kcp_notification_outbox
        where target_user_id = '7b222222-2222-4222-8222-222222222222'::uuid
          and category = 'cover_requested'
          and trip_id = (select cover_trip from notify_fixture)
    ) then
        raise exception 'Cover request did not enqueue eligible-driver notification';
    end if;
end;
$$;

select auth.become('7b222222-2222-4222-8222-222222222222'::uuid);
select public.kcp_accept_cover((select request_id from notify_fixture));

do $$
begin
    if not exists (
        select 1 from public.kcp_notification_outbox
        where target_user_id = '7b111111-1111-4111-8111-111111111111'::uuid
          and category = 'cover_accepted'
    ) then
        raise exception 'Cover acceptance did not notify the requester';
    end if;
end;
$$;

-- Child absence sends the assigned driver a targeted notification.
select auth.become('7b111111-1111-4111-8111-111111111111'::uuid);
select public.kcp_report_child_absence(
    (select child_id from notify_fixture),
    (select cover_trip from notify_fixture),
    current_date, current_date, 'picked_up_separately', 'Parent collecting', true
);

do $$
begin
    if not exists (
        select 1 from public.kcp_notification_outbox
        where target_user_id = '7b222222-2222-4222-8222-222222222222'::uuid
          and category = 'child_absence'
    ) then
        raise exception 'Child ride update did not notify assigned driver';
    end if;
end;
$$;

-- Trip-state alerts reach the active driver.
update public.kcp_trips set status = 'confirmation_due' where id = (select cover_trip from notify_fixture);

do $$
begin
    if not exists (
        select 1 from public.kcp_notification_outbox
        where target_user_id = '7b222222-2222-4222-8222-222222222222'::uuid
          and category = 'driver_confirmation_due'
    ) then
        raise exception 'Driver confirmation due alert was not enqueued';
    end if;
end;
$$;

-- Preferences suppress future matching notifications.
select auth.become('7b222222-2222-4222-8222-222222222222'::uuid);
select public.kcp_set_notification_preference('cover_requested', false, null);

do $$
begin
    if public.kcp_notification_enabled(
        '7b222222-2222-4222-8222-222222222222'::uuid,
        (select group_id from notify_fixture),
        'cover_requested'
    ) then
        raise exception 'Global notification preference was not applied';
    end if;
end;
$$;

-- Thirty-minute reminders are deduplicated even when the enqueue job repeats.
select auth.become('7b111111-1111-4111-8111-111111111111'::uuid);
with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names
    )
    select group_id, 1, current_date, 'afternoon_pickup', 'return', 'Reminder ride',
           '7b111111-1111-4111-8111-111111111111'::uuid, 'Notify Owner',
           'scheduled', now() + interval '30 minutes', 'Soon', array['Notify Child']::text[]
    from notify_fixture returning id
)
update notify_fixture set reminder_trip = (select id from trip);

select public.kcp_enqueue_trip_reminders(now());
select public.kcp_enqueue_trip_reminders(now());

do $$
begin
    if (select count(*) from public.kcp_notification_outbox
        where trip_id = (select reminder_trip from notify_fixture)
          and category = 'upcoming_ride'
          and target_user_id = '7b111111-1111-4111-8111-111111111111'::uuid) <> 1 then
        raise exception 'Reminder enqueue was not idempotent';
    end if;
end;
$$;

rollback;

select 'PASS: notification outbox, preferences and reminder dedupe verified' as result;
