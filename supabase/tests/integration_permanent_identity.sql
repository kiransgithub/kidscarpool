begin;

insert into auth.users(
    id, aud, role, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, is_anonymous
)
values (
    '71111111-1111-4111-8111-111111111111'::uuid,
    'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb,
    now(), now(), true
);

insert into public.kcp_profiles(id, display_name)
values ('71111111-1111-4111-8111-111111111111'::uuid, 'Account Tester');

select auth.become('71111111-1111-4111-8111-111111111111'::uuid);

select * from public.kcp_register_device(
    'test-device-0001',
    'Integration test phone',
    'pwa',
    'test'
);

do $$
begin
    if not public.kcp_current_device_allowed('test-device-0001') then
        raise exception 'Registered device should be allowed';
    end if;

    if (select count(*) from public.kcp_list_my_devices()) <> 1 then
        raise exception 'Expected one registered device';
    end if;
end;
$$;

select public.kcp_revoke_device('test-device-0001', 'integration test');

do $$
begin
    if public.kcp_current_device_allowed('test-device-0001') then
        raise exception 'Revoked device must not be allowed';
    end if;
end;
$$;

update auth.users
set email = 'account.tester@example.com',
    email_confirmed_at = now(),
    is_anonymous = false,
    updated_at = now()
where id = '71111111-1111-4111-8111-111111111111'::uuid;

select * from public.kcp_record_identity_upgrade();

do $$
declare
    identity record;
    profile record;
begin
    select * into identity from public.kcp_identity_status();
    if identity.email <> 'account.tester@example.com'
       or identity.is_anonymous
       or not identity.identity_verified then
        raise exception 'Permanent identity status is incorrect: %', row_to_json(identity);
    end if;

    select * into profile
    from public.kcp_profiles
    where id = '71111111-1111-4111-8111-111111111111'::uuid;

    if profile.account_email <> 'account.tester@example.com'
       or profile.identity_verified_at is null then
        raise exception 'Profile identity upgrade was not recorded';
    end if;
end;
$$;

rollback;

select 'PASS: permanent identity and device registry verified' as result;
