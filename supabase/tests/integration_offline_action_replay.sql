begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('7f111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','offline.driver@example.com',now(),'{}','{}',now(),now(),false),
('7f222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','offline.outsider@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('7f111111-1111-4111-8111-111111111111'::uuid,'Offline Driver','offline.driver@example.com',now()),
('7f222222-2222-4222-8222-222222222222'::uuid,'Offline Outsider','offline.outsider@example.com',now());

select auth.become('7f111111-1111-4111-8111-111111111111'::uuid);
create temporary table offline_fixture(group_id uuid, participant_id uuid, child_id uuid, trip_id uuid, scheduled timestamptz, device_start timestamptz);
insert into offline_fixture(group_id,participant_id,scheduled,device_start)
select created.group_id, created.owner_participant_id,
       date_trunc('minute',now() - interval '2 hours'),
       date_trunc('minute',now() - interval '1 hour 55 minutes')
from public.kcp_create_group_v3(
    'Offline replay group','other','Community destination','Pilot',
    'America/Phoenix','Offline child','Level 1'
) created;
update offline_fixture fixture set child_id = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Offline child';

select public.kcp_upsert_child_safety_profile(
    (select child_id from offline_fixture),'100 Offline Pickup','500 Offline Destination','[]'::jsonb,
    'Emergency','6025550777','none',null,null,true
);
select public.kcp_upsert_driver_safety_profile(
    (select participant_id from offline_fixture),'Emergency','6025550888',true,true,true,null
);
select public.kcp_upsert_vehicle(
    (select participant_id from offline_fixture),null,'Offline vehicle',4,1,0,true
);
select public.kcp_set_group_safety_requirement((select group_id from offline_fixture),true);
update public.kcp_groups set current_schedule_version = 1 where id = (select group_id from offline_fixture);

with trip as (
    insert into public.kcp_trips(
        group_id,schedule_version,trip_date,kind,leg_type,display_label,
        scheduled_driver_id,scheduled_driver_name,scheduled_participant_id,
        status,scheduled_time,time_label,child_names,
        confirmed_at,confirmed_by
    )
    select group_id,1,scheduled::date,'morning_drop','outbound','Offline ride',
           '7f111111-1111-4111-8111-111111111111'::uuid,'Offline Driver',participant_id,
           'ready',scheduled,'Past',array['Offline child']::text[],
           device_start - interval '5 minutes','7f111111-1111-4111-8111-111111111111'::uuid
    from offline_fixture returning id
)
update offline_fixture set trip_id = (select id from trip);

-- Server time is now outside the normal +90 minute manual gate, but the saved
-- device time was within the original ride window.
select public.kcp_apply_offline_trip_action(
    'offline-start-action-0001',(select trip_id from offline_fixture),'start_trip','{}'::jsonb,
    (select device_start from offline_fixture)
);

-- Retrying the same action ID is idempotent.
select public.kcp_apply_offline_trip_action(
    'offline-start-action-0001',(select trip_id from offline_fixture),'start_trip','{}'::jsonb,
    (select device_start from offline_fixture)
);

select public.kcp_apply_offline_trip_action(
    'offline-child-action-0002',(select trip_id from offline_fixture),'child_picked_up',
    jsonb_build_object('childId',(select child_id from offline_fixture)),
    (select device_start + interval '10 minutes' from offline_fixture)
);
select public.kcp_apply_offline_trip_action(
    'offline-arrival-action-0003',(select trip_id from offline_fixture),'arrive_destination','{}'::jsonb,
    (select device_start + interval '35 minutes' from offline_fixture)
);
select public.kcp_apply_offline_trip_action(
    'offline-complete-action-0004',(select trip_id from offline_fixture),'confirm_completion','{}'::jsonb,
    (select device_start + interval '36 minutes' from offline_fixture)
);

do $$
begin
    if (select status from public.kcp_trips where id = (select trip_id from offline_fixture)) <> 'completed' then
        raise exception 'Ordered offline replay did not complete the ride';
    end if;
    if (select started_source from public.kcp_trips where id = (select trip_id from offline_fixture)) <> 'offline' then
        raise exception 'Delayed offline Start was not identified correctly';
    end if;
    if (select count(*) from public.kcp_client_action_receipts where user_id = auth.uid()) <> 4 then
        raise exception 'Duplicate replay created a second receipt or a receipt is missing';
    end if;
    if (select count(*) from public.kcp_trip_events where client_event_id = 'receipt:offline-start-action-0001') <> 1 then
        raise exception 'Offline Start receipt event is not idempotent';
    end if;
    if (select count(*) from public.kcp_my_client_action_receipts(array[
        'offline-start-action-0001','offline-child-action-0002','offline-arrival-action-0003','offline-complete-action-0004'
    ])) <> 4 then
        raise exception 'Client cannot reconcile applied offline actions';
    end if;
end;
$$;

select auth.become('7f222222-2222-4222-8222-222222222222'::uuid);
do $$
begin
    begin
        perform public.kcp_apply_offline_trip_action(
            'offline-outsider-action-9999',(select trip_id from offline_fixture),'report_issue',
            '{"category":"other","note":"Unauthorized replay"}'::jsonb,now()
        );
        raise exception 'Outsider replay unexpectedly succeeded';
    exception when others then
        if sqlerrm = 'Outsider replay unexpectedly succeeded' then raise; end if;
    end;
end;
$$;

rollback;

select 'PASS: ordered idempotent offline replay and delayed Start verified' as result;
