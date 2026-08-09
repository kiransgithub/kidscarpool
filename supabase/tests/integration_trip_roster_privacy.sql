begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('76111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','privacy.owner@example.com',now(),'{}','{}',now(),now(),false),
('76222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','privacy.driver@example.com',now(),'{}','{}',now(),now(),false),
('76333333-3333-4333-8333-333333333333'::uuid,'authenticated','authenticated','privacy.viewer@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('76111111-1111-4111-8111-111111111111'::uuid,'Privacy Owner','privacy.owner@example.com',now()),
('76222222-2222-4222-8222-222222222222'::uuid,'Privacy Driver','privacy.driver@example.com',now()),
('76333333-3333-4333-8333-333333333333'::uuid,'Privacy Viewer','privacy.viewer@example.com',now());

select auth.become('76111111-1111-4111-8111-111111111111'::uuid);
create temporary table privacy_fixture(group_id uuid, owner_child uuid, driver_child uuid, driver_token text, viewer_token text, trip_id uuid);
grant select on privacy_fixture to authenticated;
insert into privacy_fixture(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Roster privacy group','other','Community destination','Pilot',
    'America/Phoenix','Owner Child','Level 1'
) created;

update privacy_fixture fixture
set owner_child = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Owner Child';

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from privacy_fixture), 'Privacy Driver', 'parent',
        null, null, 'Driver Child', 4, true, 14
    ) as row
)
update privacy_fixture set driver_token = (select (row).token from invitation);

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from privacy_fixture), 'Privacy Viewer', 'viewer',
        null, null, null, null, false, 14
    ) as row
)
update privacy_fixture set viewer_token = (select (row).token from invitation);

select auth.become('76222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation((select driver_token from privacy_fixture),'Privacy Driver',null);

select auth.become('76333333-3333-4333-8333-333333333333'::uuid);
select * from public.kcp_accept_invitation((select viewer_token from privacy_fixture),'Privacy Viewer',null);

select auth.become('76111111-1111-4111-8111-111111111111'::uuid);
update privacy_fixture fixture
set driver_child = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Driver Child';

select public.kcp_upsert_child_safety_profile(
    (select owner_child from privacy_fixture),
    '100 Owner Pickup', '500 Destination', '[]'::jsonb,
    'Owner Emergency', '6025550101', 'booster', 'Owner critical alert',
    'Owner pickup instructions', true
);
select public.kcp_upsert_child_safety_profile(
    (select driver_child from privacy_fixture),
    '200 Driver Pickup', '500 Destination', '[]'::jsonb,
    'Driver Emergency', '6025550102', 'none', null,
    'Driver child instructions', true
);

update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from privacy_fixture);
with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names, notes
    )
    select group_id, 1, current_date + 2, 'morning_drop', 'outbound', 'Outbound',
           '76222222-2222-4222-8222-222222222222'::uuid, 'Privacy Driver',
           'scheduled', now() + interval '2 days', 'Future time',
           array['Owner Child','Driver Child']::text[], 'Sensitive operational note'
    from privacy_fixture
    returning id
)
update privacy_fixture set trip_id = (select id from trip);

-- Viewer receives no child master rows and no sensitive child list in agenda.
select auth.become('76333333-3333-4333-8333-333333333333'::uuid);
set local role authenticated;

do $$
begin
    if (select count(*) from public.kcp_children where group_id = (select group_id from privacy_fixture)) <> 0 then
        raise exception 'Viewer unexpectedly read child master rows';
    end if;
    if exists (
        select 1 from public.kcp_my_agenda(now(), now() + interval '7 days', 20)
        where cardinality(child_names) > 0 or notes <> ''
    ) then
        raise exception 'Viewer agenda exposed child names or notes';
    end if;
    begin
        perform * from public.kcp_get_trip_operational_roster((select trip_id from privacy_fixture));
        raise exception 'Viewer unexpectedly opened the operational roster';
    exception when others then
        if sqlerrm = 'Viewer unexpectedly opened the operational roster' then raise; end if;
    end;
end;
$$;
reset role;

-- Assigned driver outside the ride window receives only their own child.
select auth.become('76222222-2222-4222-8222-222222222222'::uuid);
set local role authenticated;
do $$
begin
    if public.kcp_trip_roster_access_scope((select trip_id from privacy_fixture)) <> 'own_child' then
        raise exception 'Driver outside window should receive own-child scope';
    end if;
    if (select count(*) from public.kcp_get_trip_operational_roster((select trip_id from privacy_fixture))) <> 1 then
        raise exception 'Driver outside window should see only their child';
    end if;
end;
$$;
reset role;

-- Bring the trip into the operational window; the assigned driver receives all.
select auth.become('76111111-1111-4111-8111-111111111111'::uuid);
update public.kcp_trips
set scheduled_time = now() + interval '30 minutes', trip_date = current_date
where id = (select trip_id from privacy_fixture);

select auth.become('76222222-2222-4222-8222-222222222222'::uuid);
set local role authenticated;
do $$
begin
    if public.kcp_trip_roster_access_scope((select trip_id from privacy_fixture)) <> 'assigned_driver' then
        raise exception 'Imminent assigned driver did not receive driver scope';
    end if;
    if (select count(*) from public.kcp_get_trip_operational_roster((select trip_id from privacy_fixture))) <> 2 then
        raise exception 'Assigned driver did not receive the complete ride roster';
    end if;
end;
$$;
reset role;

select auth.become('76111111-1111-4111-8111-111111111111'::uuid);
do $$
begin
    if not exists (
        select 1 from public.kcp_sensitive_access_events
        where trip_id = (select trip_id from privacy_fixture)
          and access_scope = 'assigned_driver'
    ) then
        raise exception 'Sensitive driver access was not audited';
    end if;
end;
$$;

rollback;

select 'PASS: Viewer masking and trip-scoped roster privacy verified' as result;
