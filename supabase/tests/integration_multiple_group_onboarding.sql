begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('75110000-0000-4000-8000-000000000001','authenticated','authenticated','multi.owner@example.com',now(),'{}','{}',now(),now(),false),
('75110000-0000-4000-8000-000000000002','authenticated','authenticated','multi.accept@example.com',now(),'{}','{}',now(),now(),false),
('75110000-0000-4000-8000-000000000003','authenticated','authenticated','multi.decline@example.com',now(),'{}','{}',now(),now(),false),
('75110000-0000-4000-8000-000000000004','authenticated','authenticated','multi.pending@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('75110000-0000-4000-8000-000000000001','Multi-group Owner','multi.owner@example.com',now()),
('75110000-0000-4000-8000-000000000002','Accepting Driver','multi.accept@example.com',now()),
('75110000-0000-4000-8000-000000000003','Declining Driver','multi.decline@example.com',now()),
('75110000-0000-4000-8000-000000000004','Pending Driver','multi.pending@example.com',now());

select auth.become('75110000-0000-4000-8000-000000000001'::uuid);

create temporary table multi_group_test(
    sequence integer primary key,
    group_id uuid,
    plan_id uuid,
    invitation_token text
);

insert into multi_group_test(sequence, group_id, plan_id)
select 1, created.group_id, created.draft_plan_id
from public.kcp_create_group_v3('School rotation','school','North School','Fall','America/Phoenix','Owner Child','5') created;
insert into multi_group_test(sequence, group_id, plan_id)
select 2, created.group_id, created.draft_plan_id
from public.kcp_create_group_v3('Music rotation','music','Music Studio','Fall','America/Phoenix','Owner Child','5') created;
insert into multi_group_test(sequence, group_id, plan_id)
select 3, created.group_id, created.draft_plan_id
from public.kcp_create_group_v3('Sports rotation','training','Sports Center','Fall','America/Phoenix','Owner Child','5') created;

do $$
declare
    test record;
    invitation public.kcp_invitations;
begin
    for test in select * from multi_group_test order by sequence loop
        invitation := public.kcp_create_driver_invitation(
            test.group_id,
            case test.sequence when 1 then 'Accepting Driver' when 2 then 'Declining Driver' else 'Pending Driver' end,
            case test.sequence when 1 then 'multi.accept@example.com' when 2 then 'multi.decline@example.com' else 'multi.pending@example.com' end,
            null,
            case test.sequence when 1 then 'Accepted Child' when 2 then null else 'Pending Child' end,
            case test.sequence when 1 then '4' when 2 then null else 'Beginner' end,
            14
        );
        update multi_group_test set invitation_token = invitation.token where sequence = test.sequence;
    end loop;
end;
$$;

do $$
declare
    owner_group_count integer;
    draft_state jsonb;
begin
    select count(*) into owner_group_count from public.kcp_list_my_groups();
    if owner_group_count <> 3 then raise exception 'Owner expected 3 isolated groups, found %', owner_group_count; end if;

    select public.kcp_schedule_builder_state(group_id) into draft_state
    from multi_group_test where sequence = 3;
    if draft_state->'plan' is null then raise exception 'Owner cannot view pending-driver schedule draft'; end if;

    begin
        perform public.kcp_publish_schedule_plan_v3(
            (select plan_id from multi_group_test where sequence = 3),
            'Must remain draft while driver is pending', gen_random_uuid()
        );
        raise exception 'Pending driver unexpectedly allowed publication';
    exception when others then
        if position('All invited drivers must accept or decline' in sqlerrm) = 0 then raise; end if;
    end;
end;
$$;

select auth.become('75110000-0000-4000-8000-000000000002'::uuid);
select * from public.kcp_accept_invitation(
    (select invitation_token from multi_group_test where sequence = 1), 'Accepting Driver', null
);

do $$
begin
    if (select count(*) from public.kcp_list_my_groups()) <> 1 then
        raise exception 'Accepting driver should see exactly one group';
    end if;
    if not exists (
        select 1 from public.kcp_children child
        join public.kcp_group_participants participant on participant.id = child.participant_id
        where participant.user_id = auth.uid() and child.name = 'Accepted Child'
    ) then raise exception 'Known invited child was not attached to accepting driver'; end if;
end;
$$;

select auth.become('75110000-0000-4000-8000-000000000003'::uuid);
select public.kcp_decline_invitation((select invitation_token from multi_group_test where sequence = 2));

do $$
begin
    if (select count(*) from public.kcp_list_my_groups()) <> 0 then
        raise exception 'Declining driver unexpectedly received a membership';
    end if;
end;
$$;

select auth.become('75110000-0000-4000-8000-000000000001'::uuid);
do $$
begin
    if not exists (
        select 1 from public.kcp_invitations invitation
        join multi_group_test test on test.group_id = invitation.group_id and test.sequence = 1
        where invitation.status = 'accepted'
    ) then raise exception 'Owner cannot see accepted invitation status'; end if;
    if not exists (
        select 1 from public.kcp_invitations invitation
        join multi_group_test test on test.group_id = invitation.group_id and test.sequence = 2
        where invitation.status = 'declined'
    ) then raise exception 'Owner cannot see declined invitation status'; end if;
    if not exists (
        select 1 from public.kcp_invitations invitation
        join multi_group_test test on test.group_id = invitation.group_id and test.sequence = 3
        where invitation.status = 'pending'
    ) then raise exception 'Pending group invitation state was not isolated'; end if;
end;
$$;

rollback;

select 'PASS: multiple group creation, invitation decisions, isolation and publish gate verified' as result;
