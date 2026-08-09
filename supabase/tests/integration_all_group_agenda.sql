begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values (
    '73111111-1111-4111-8111-111111111111'::uuid,
    'authenticated','authenticated','agenda.member@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values ('73111111-1111-4111-8111-111111111111'::uuid, 'Agenda Member', 'agenda.member@example.com', now());

select auth.become('73111111-1111-4111-8111-111111111111'::uuid);

create temporary table agenda_groups(group_id uuid, name text);
insert into agenda_groups
select created.group_id, 'Morning group'
from public.kcp_create_group_v3('Morning group','school','Destination A','Term','America/Phoenix','Rider A','4') created;
insert into agenda_groups
select created.group_id, 'Evening group'
from public.kcp_create_group_v3('Evening group','music','Destination B','Term','America/Phoenix','Rider B','Beginner') created;

update public.kcp_groups
set current_schedule_version = 1
where id in (select group_id from agenda_groups);

insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, status,
    scheduled_time, time_label, child_names
)
select group_id, 1, current_date + 1, 'morning_drop', 'outbound', 'School drop-off',
       '73111111-1111-4111-8111-111111111111'::uuid, 'Agenda Member', 'scheduled',
       now() + interval '1 day', '7:00 AM', array['Rider A']::text[]
from agenda_groups where name = 'Morning group';

insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, status,
    scheduled_time, time_label, child_names
)
select group_id, 1, current_date + 2, 'afternoon_pickup', 'return', 'Class pickup',
       '73111111-1111-4111-8111-111111111111'::uuid, 'Agenda Member', 'scheduled',
       now() + interval '2 days', '7:00 PM', array['Rider B']::text[]
from agenda_groups where name = 'Evening group';

do $$
begin
    if (select count(*) from public.kcp_my_agenda(now(), now() + interval '10 days', 50)) <> 2 then
        raise exception 'All-group agenda did not include both memberships';
    end if;

    if (select count(distinct group_id) from public.kcp_my_agenda(now(), now() + interval '10 days', 50)) <> 2 then
        raise exception 'Agenda results were not grouped across memberships';
    end if;

    if not exists (
        select 1 from public.kcp_my_agenda(now(), now() + interval '10 days', 50)
        where display_label = 'Class pickup'
          and group_name = 'Evening group'
    ) then
        raise exception 'Evening group trip was missing from personal agenda';
    end if;
end;
$$;

rollback;

select 'PASS: all-group personal agenda verified' as result;
