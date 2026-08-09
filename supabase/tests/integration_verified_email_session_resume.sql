begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
(
    '76110000-0000-4000-8000-000000000001','authenticated','authenticated',null,null,
    '{}'::jsonb,'{}'::jsonb,now(),now(),true
),
(
    '76110000-0000-4000-8000-000000000002','authenticated','authenticated','returning.parent@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
),
(
    '76110000-0000-4000-8000-000000000003','authenticated','authenticated','new.parent@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values (
    '76110000-0000-4000-8000-000000000001',
    'Returning Parent',
    'returning.parent@example.com',
    now()
);

select auth.become('76110000-0000-4000-8000-000000000001'::uuid);

create temporary table verified_resume_test(group_id uuid);
insert into verified_resume_test(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Returning family group','school','School destination','2026–27',
    'America/Phoenix','Returning Child','4'
) created;

select auth.become('76110000-0000-4000-8000-000000000002'::uuid);
select * from public.kcp_resume_verified_account(null);

do $$
declare
    target_group uuid := (select group_id from verified_resume_test);
    result record;
begin
    select * into result from public.kcp_resume_verified_account(null);

    if result.profile_id <> auth.uid()
       or result.display_name <> 'Returning Parent'
       or result.account_email <> 'returning.parent@example.com' then
        raise exception 'Verified account was not resumed: %', row_to_json(result);
    end if;

    if not exists (
        select 1 from public.kcp_memberships membership
         where membership.group_id = target_group
           and membership.user_id = auth.uid()
           and membership.role = 'owner'
           and membership.status = 'active'
    ) then raise exception 'Active owner membership was not moved to the verified account'; end if;

    if exists (
        select 1 from public.kcp_memberships membership
         where membership.group_id = target_group
           and membership.user_id = '76110000-0000-4000-8000-000000000001'::uuid
           and membership.status = 'active'
    ) then raise exception 'Previous device identity still has active group access'; end if;

    if (select created_by from public.kcp_groups where id = target_group) <> auth.uid() then
        raise exception 'Group ownership was not moved to the verified account';
    end if;

    if (select count(*) from public.kcp_list_my_groups()) <> 1 then
        raise exception 'Returning verified account cannot list its restored group';
    end if;
end;
$$;

select auth.become('76110000-0000-4000-8000-000000000003'::uuid);
select * from public.kcp_resume_verified_account('New Parent');

do $$
begin
    if not exists (
        select 1 from public.kcp_profiles profile
         where profile.id = auth.uid()
           and profile.display_name = 'New Parent'
           and profile.account_email = 'new.parent@example.com'
           and profile.identity_verified_at is not null
    ) then raise exception 'First-time verified profile was not created'; end if;
end;
$$;

rollback;

select 'PASS: verified email sessions resume profiles and group access' as result;
