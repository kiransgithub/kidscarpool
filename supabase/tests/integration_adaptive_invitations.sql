begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
(
    '74111111-1111-4111-8111-111111111111'::uuid,
    'authenticated','authenticated','invite.owner@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
),
(
    '74222222-2222-4222-8222-222222222222'::uuid,
    'authenticated','authenticated','invite.viewer@example.com',now(),
    '{}'::jsonb,'{}'::jsonb,now(),now(),false
);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('74111111-1111-4111-8111-111111111111'::uuid, 'Invitation Owner', 'invite.owner@example.com', now()),
('74222222-2222-4222-8222-222222222222'::uuid, 'Schedule Viewer', 'invite.viewer@example.com', now());

select auth.become('74111111-1111-4111-8111-111111111111'::uuid);

create temporary table invitation_test(group_id uuid, viewer_token text, viewer_invitation uuid);
insert into invitation_test(group_id)
select created.group_id
from public.kcp_create_group_v3(
    'Adaptive invitation group','other','Community destination','Pilot',
    'America/Phoenix','Owner rider','Level 1'
) created;

with invitation as (
    select public.kcp_create_invitation_v2(
        (select group_id from invitation_test),
        'Schedule Viewer',
        'viewer',
        'invite.viewer@example.com',
        null,
        null,
        null,
        true,
        14
    ) as row
)
update invitation_test
set viewer_token = (select (row).token from invitation),
    viewer_invitation = (select (row).id from invitation);

do $$
declare
    preview record;
begin
    select * into preview
    from public.kcp_invitation_preview((select viewer_token from invitation_test));

    if preview.role <> 'viewer'
       or preview.child_name is not null
       or preview.can_drive
       or not preview.email_bound
       or preview.status <> 'pending' then
        raise exception 'Viewer invitation preview is incorrect: %', row_to_json(preview);
    end if;

    begin
        perform public.kcp_create_invitation_v2(
            (select group_id from invitation_test),
            'Parent Without Child', 'parent', null, null, null, null, true, 14
        );
        raise exception 'Parent invitation unexpectedly allowed no child';
    exception when others then
        if sqlerrm = 'Parent invitation unexpectedly allowed no child' then raise; end if;
    end;
end;
$$;

select auth.become('74222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation(
    (select viewer_token from invitation_test),
    'Schedule Viewer',
    null
);

do $$
declare
    target_group uuid := (select group_id from invitation_test);
begin
    if not exists (
        select 1 from public.kcp_memberships member
        where member.group_id = target_group
          and member.user_id = '74222222-2222-4222-8222-222222222222'::uuid
          and member.role = 'viewer'
          and member.status = 'active'
          and member.child_name is null
          and member.grade is null
    ) then
        raise exception 'Viewer membership was not created without child data';
    end if;

    if not exists (
        select 1 from public.kcp_group_participants participant
        where participant.group_id = target_group
          and participant.user_id = '74222222-2222-4222-8222-222222222222'::uuid
          and participant.status = 'active'
          and not participant.can_drive
    ) then
        raise exception 'Viewer participant must be non-driving';
    end if;

    if exists (
        select 1 from public.kcp_constraints constraint_row
        where constraint_row.group_id = target_group
          and constraint_row.user_id = '74222222-2222-4222-8222-222222222222'::uuid
    ) then
        raise exception 'Viewer must not receive driving constraints';
    end if;
end;
$$;

rollback;

select 'PASS: adaptive Viewer invitation and acceptance verified' as result;
