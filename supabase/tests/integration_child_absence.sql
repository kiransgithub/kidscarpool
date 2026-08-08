begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('79111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','absence.parent@example.com',now(),'{}','{}',now(),now(),false),
('79222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','absence.driver@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, phone, account_email, identity_verified_at)
values
('79111111-1111-4111-8111-111111111111'::uuid,'Absence Parent','6025550111','absence.parent@example.com',now()),
('79222222-2222-4222-8222-222222222222'::uuid,'Absence Driver','6025550222','absence.driver@example.com',now());

select auth.become('79111111-1111-4111-8111-111111111111'::uuid);
create temporary table absence_fixture(group_id uuid, child_id uuid, driver_token text, trip_id uuid, report_id uuid);
insert into absence_fixture(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Absence workflow group','other','Community destination','Pilot',
    'America/Phoenix','Parent Child','Level 1'
) created;
update absence_fixture fixture
set child_id = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Parent Child';

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from absence_fixture), 'Absence Driver', 'parent',
        null, null, 'Driver Child', 4, true, 14
    ) as row
)
update absence_fixture set driver_token = (select (row).token from invitation);

select auth.become('79222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation((select driver_token from absence_fixture),'Absence Driver',null);

select auth.become('79111111-1111-4111-8111-111111111111'::uuid);
update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from absence_fixture);
with trip as (
    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind, leg_type, display_label,
        scheduled_driver_id, scheduled_driver_name, status, scheduled_time,
        time_label, child_names
    )
    select group_id, 1, current_date, 'afternoon_pickup', 'return', 'Activity pickup',
           '79222222-2222-4222-8222-222222222222'::uuid, 'Absence Driver',
           'scheduled', now() + interval '30 minutes', 'Soon', array['Parent Child']::text[]
    from absence_fixture
    returning id
)
update absence_fixture set trip_id = (select id from trip);

update absence_fixture
set report_id = public.kcp_report_child_absence(
    child_id, trip_id, current_date, current_date,
    'picked_up_separately', 'Parent will collect at the activity', true
);

do $$
begin
    if not exists (
        select 1 from public.kcp_my_absence_reports(false)
        where report_id = (select report_id from absence_fixture)
          and reason = 'picked_up_separately'
          and can_cancel
    ) then
        raise exception 'Reporting parent cannot see or cancel the active report';
    end if;
end;
$$;

select auth.become('79222222-2222-4222-8222-222222222222'::uuid);

do $$
declare
    snapshot jsonb;
begin
    select public.kcp_driver_trip_snapshot((select trip_id from absence_fixture)) into snapshot;
    if jsonb_array_length(snapshot->'roster') <> 1 then
        raise exception 'Driver snapshot did not include the ride child';
    end if;
    if (snapshot->'roster'->0->>'absence_reason') <> 'picked_up_separately'
       or (snapshot->'roster'->0->>'latest_status') <> 'child_skipped' then
        raise exception 'Driver snapshot did not reflect the parent report: %', snapshot;
    end if;
    if not exists (
        select 1 from public.kcp_my_absence_reports(false)
        where report_id = (select report_id from absence_fixture)
    ) then
        raise exception 'Assigned driver could not see the relevant report';
    end if;
end;
$$;

select auth.become('79111111-1111-4111-8111-111111111111'::uuid);
select public.kcp_cancel_child_absence((select report_id from absence_fixture),'Child will ride after all');

select auth.become('79222222-2222-4222-8222-222222222222'::uuid);
do $$
declare
    snapshot jsonb;
begin
    select public.kcp_driver_trip_snapshot((select trip_id from absence_fixture)) into snapshot;
    if snapshot->'roster'->0->>'absence_reason' is not null then
        raise exception 'Cancelled absence remained on driver snapshot';
    end if;
end;
$$;

rollback;

select 'PASS: child absence and separate-pickup workflow verified' as result;
