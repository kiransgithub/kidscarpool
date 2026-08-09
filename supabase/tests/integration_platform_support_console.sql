begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('7e111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','platform.support@example.com',now(),'{}','{}',now(),now(),false),
('7e222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','group.owner@example.com',now(),'{}','{}',now(),now(),false),
('7e333333-3333-4333-8333-333333333333'::uuid,'authenticated','authenticated','new.owner@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, phone, account_email, identity_verified_at)
values
('7e111111-1111-4111-8111-111111111111'::uuid,'Platform Support','6025550111','platform.support@example.com',now()),
('7e222222-2222-4222-8222-222222222222'::uuid,'Group Owner','6025550222','group.owner@example.com',now()),
('7e333333-3333-4333-8333-333333333333'::uuid,'New Owner','6025550333','new.owner@example.com',now());

select public.kcp_bootstrap_platform_admin('platform.support@example.com','super_admin');

select auth.become('7e222222-2222-4222-8222-222222222222'::uuid);
create temporary table support_fixture(group_id uuid, child_id uuid, token_new_owner text, pending_invitation uuid, break_glass uuid);
insert into support_fixture(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Support visible group','other','Community destination','Pilot',
    'America/Phoenix','Support child','Level 1'
) created;
update support_fixture fixture set child_id = child.id
from public.kcp_children child
where child.group_id = fixture.group_id and child.name = 'Support child';

select public.kcp_upsert_child_safety_profile(
    (select child_id from support_fixture),
    '100 Private Pickup', '500 Private Destination', '[]'::jsonb,
    'Emergency Person', '6025550999', 'booster', 'Critical transport alert', 'Private instruction', true
);

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from support_fixture), 'New Owner', 'parent',
        null, null, 'New owner child', 4, true, 14
    ) as row
)
update support_fixture set token_new_owner = (select (row).token from invitation);

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from support_fixture), 'Pending Viewer', 'viewer',
        null, null, null, null, false, 14
    ) as row
)
update support_fixture set pending_invitation = (select (row).id from invitation);

select public.kcp_register_client_heartbeat(
    'group-owner-device-1234','test-build-1','cache-test','Test browser','Test agent',
    (select group_id from support_fixture)
);

select auth.become('7e333333-3333-4333-8333-333333333333'::uuid);
select * from public.kcp_accept_invitation((select token_new_owner from support_fixture),'New Owner',null);

select auth.become('7e111111-1111-4111-8111-111111111111'::uuid);

do $$
declare
    dashboard jsonb;
    details jsonb;
begin
    if not exists (select 1 from public.kcp_support_me() where platform_role = 'super_admin') then
        raise exception 'Super Admin session was not recognized';
    end if;
    select public.kcp_support_dashboard() into dashboard;
    if coalesce((dashboard->>'groups')::integer,0) < 1
       or (dashboard->>'latestMigration') is null then
        raise exception 'Support dashboard is incomplete: %', dashboard;
    end if;
    if not exists (
        select 1 from public.kcp_support_groups('Support visible',null,100,0)
        where group_id = (select group_id from support_fixture)
          and owner_name_masked <> 'Group Owner'
          and latest_client_build = 'test-build-1'
    ) then
        raise exception 'Global group listing is missing, unmasked or lacks heartbeat';
    end if;

    select public.kcp_support_group_details((select group_id from support_fixture)) into details;
    if details->'members'->0->>'name' in ('Group Owner','New Owner') then
        raise exception 'Support details exposed member names without break-glass: %', details;
    end if;
    if jsonb_array_length(details->'invitations') < 1 then
        raise exception 'Support details omitted invitations';
    end if;
end;
$$;

update support_fixture
set break_glass = public.kcp_support_open_break_glass(
    group_id,
    'Resolve a verified parent identity and pickup-tag support case',
    10
);

do $$
declare
    sensitive jsonb;
begin
    if not public.kcp_support_has_break_glass((select group_id from support_fixture)) then
        raise exception 'Break-glass session is not active';
    end if;
    select public.kcp_support_group_sensitive_details((select group_id from support_fixture)) into sensitive;
    if not (sensitive->'members' @> '[{"name":"Group Owner"}]'::jsonb)
       or not (sensitive->'children' @> '[{"name":"Support child","pickupAddress":"100 Private Pickup"}]'::jsonb) then
        raise exception 'Break-glass details are incomplete: %', sensitive;
    end if;
    if not exists (
        select 1 from public.kcp_platform_audit_events
        where action = 'break_glass_data_viewed'
          and entity_id = (select group_id::text from support_fixture)
    ) then
        raise exception 'Sensitive support view was not audited';
    end if;
end;
$$;

select public.kcp_support_close_break_glass((select break_glass from support_fixture));

do $$
begin
    if public.kcp_support_has_break_glass((select group_id from support_fixture)) then
        raise exception 'Break-glass session did not close';
    end if;
    begin
        perform public.kcp_support_group_sensitive_details((select group_id from support_fixture));
        raise exception 'Sensitive details remained accessible after close';
    exception when others then
        if sqlerrm = 'Sensitive details remained accessible after close' then raise; end if;
    end;
end;
$$;

select public.kcp_support_transfer_ownership(
    (select group_id from support_fixture),
    '7e333333-3333-4333-8333-333333333333'::uuid,
    'Verified former Owner requested an audited support transfer'
);

do $$
begin
    if not exists (
        select 1 from public.kcp_memberships
        where group_id = (select group_id from support_fixture)
          and user_id = '7e333333-3333-4333-8333-333333333333'::uuid
          and role = 'owner' and status = 'active'
    ) then raise exception 'Support ownership transfer failed'; end if;
    if not exists (
        select 1 from public.kcp_memberships
        where group_id = (select group_id from support_fixture)
          and user_id = '7e222222-2222-4222-8222-222222222222'::uuid
          and role = 'admin' and status = 'active'
    ) then raise exception 'Former Owner did not become Admin'; end if;
end;
$$;

select * from public.kcp_support_reissue_invitation((select pending_invitation from support_fixture),14);
select public.kcp_support_set_group_status(
    (select group_id from support_fixture),'archived','Group requested temporary deactivation'
);

do $$
begin
    if (select status from public.kcp_groups where id = (select group_id from support_fixture)) <> 'archived' then
        raise exception 'Support group archive failed';
    end if;
    if not exists (
        select 1 from public.kcp_platform_audit_events
        where action in ('support_ownership_transferred','support_group_status_changed','support_invitation_reissued')
    ) then
        raise exception 'Support repair actions were not audited';
    end if;
end;
$$;

rollback;

select 'PASS: platform support visibility and audited operations verified' as result;
