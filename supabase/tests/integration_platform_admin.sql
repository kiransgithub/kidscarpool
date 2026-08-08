begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
(
    '72111111-1111-4111-8111-111111111111'::uuid,
    'authenticated','authenticated','support.admin@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
),
(
    '72222222-2222-4222-8222-222222222222'::uuid,
    'authenticated','authenticated','regular.member@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('72111111-1111-4111-8111-111111111111'::uuid, 'Support Admin', 'support.admin@example.com', now()),
('72222222-2222-4222-8222-222222222222'::uuid, 'Regular Member', 'regular.member@example.com', now());

select public.kcp_bootstrap_platform_admin('support.admin@example.com', 'super_admin');
select auth.become('72222222-2222-4222-8222-222222222222'::uuid);

create temporary table platform_test_group(group_id uuid);
insert into platform_test_group
select created.group_id
from public.kcp_create_group_v3(
    'Support-visible group', 'other', 'Community center', 'Pilot',
    'America/Phoenix', 'Rider', 'Level 1'
) created;

select public.kcp_report_client_error(
    'integration_test', 'test-client',
    (select group_id from platform_test_group),
    'TEST_FAILURE', jsonb_build_object('safe', true), 'synthetic technical detail'
);

-- A normal group member must not receive platform-wide results.
do $$
begin
    begin
        perform * from public.kcp_admin_list_groups(null, 10, 0);
        raise exception 'Normal user unexpectedly received platform group list';
    exception when others then
        if sqlerrm = 'Normal user unexpectedly received platform group list' then raise; end if;
    end;
end;
$$;

select auth.become('72111111-1111-4111-8111-111111111111'::uuid);

do $$
declare
    target_group uuid := (select group_id from platform_test_group);
    access_event uuid;
    access_expiry timestamptz;
begin
    if not public.kcp_is_platform_admin() then
        raise exception 'Bootstrapped Super Admin was not recognized';
    end if;

    if not exists (
        select 1 from public.kcp_admin_list_groups('Support-visible', 10, 0)
        where group_id = target_group
    ) then
        raise exception 'Super Admin could not see the group';
    end if;

    if (select count(*) from public.kcp_admin_list_client_errors(20)
        where operation = 'integration_test') <> 1 then
        raise exception 'Super Admin could not inspect client error reference';
    end if;

    select event_id, expires_at into access_event, access_expiry
    from public.kcp_admin_open_break_glass(target_group, 'Investigate integration support case');

    if access_event is null or access_expiry <= now() then
        raise exception 'Break-glass event was not created';
    end if;

    perform public.kcp_admin_close_break_glass(access_event);

    if not exists (
        select 1 from public.kcp_platform_audit_events
        where action = 'break_glass_opened'
          and entity_id = target_group::text
    ) then
        raise exception 'Break-glass access was not audited';
    end if;
end;
$$;

rollback;

select 'PASS: platform Super Admin and support RBAC verified' as result;
