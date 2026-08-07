-- Verifies that anonymous-account recovery changes the Auth UUID without
-- replacing the stable participant referenced by schedule policies and trips.

begin;

insert into auth.users(
    id, aud, role, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, is_anonymous
)
values
    (
        '51111111-1111-4111-8111-111111111111'::uuid,
        'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb,
        now(), now(), true
    ),
    (
        '52222222-2222-4222-8222-222222222222'::uuid,
        'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb,
        now(), now(), true
    );

insert into public.kcp_profiles(id, display_name, phone)
values
    ('51111111-1111-4111-8111-111111111111'::uuid, 'Recovery Driver', '6025550151'),
    ('52222222-2222-4222-8222-222222222222'::uuid, 'Recovery Driver', '6025550151');

do $$
declare
    source_user constant uuid := '51111111-1111-4111-8111-111111111111'::uuid;
    target_user constant uuid := '52222222-2222-4222-8222-222222222222'::uuid;
    target_group uuid;
    stable_participant uuid;
    target_plan uuid;
    schedule_version integer;
    participant_count integer;
    active_owner_count integer;
begin
    perform set_config('request.jwt.claim.sub', source_user::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);

    select created.group_id, created.owner_participant_id, created.draft_plan_id
      into target_group, stable_participant, target_plan
      from public.kcp_create_group_v3(
          'Recovery schedule group',
          'other',
          'Community destination',
          'Pilot',
          'America/Phoenix',
          'Recovery Rider',
          'Level 1'
      ) created;

    perform public.kcp_save_schedule_plan(
        p_plan_id => target_plan,
        p_name => 'Recovery plan',
        p_starts_on => date '2031-01-06',
        p_ends_on => date '2031-01-13',
        p_outbound_label => 'Outbound',
        p_return_label => 'Return',
        p_auto_complete_after_minutes => 30,
        p_sessions => jsonb_build_array(
            jsonb_build_object(
                'name', 'Monday ride',
                'weekday', 1,
                'intervalWeeks', 1,
                'anchorDate', '2031-01-06',
                'outboundEnabled', true,
                'outboundTime', '18:00',
                'returnEnabled', true,
                'returnTime', '19:00',
                'returnDayOffset', 0,
                'displayOrder', 1
            )
        ),
        p_strategy => 'fixed',
        p_cycle_behavior => 'calendar',
        p_anchor_date => date '2031-01-06',
        p_participant_ids => array[stable_participant],
        p_fixed_participant_id => stable_participant
    );

    select public.kcp_publish_schedule_plan(target_plan, 'Recovery identity regression')
      into schedule_version;

    perform public.kcp_transfer_group_membership(
        target_group,
        source_user,
        target_user,
        'stable participant integration test'
    );

    select count(*) into participant_count
    from public.kcp_group_participants participant
    where participant.group_id = target_group
      and participant.status = 'active';

    if participant_count <> 1 then
        raise exception 'Recovery must leave one active stable participant, found %', participant_count;
    end if;

    if not exists (
        select 1
        from public.kcp_group_participants participant
        where participant.id = stable_participant
          and participant.group_id = target_group
          and participant.user_id = target_user
          and participant.status = 'active'
    ) then
        raise exception 'The original stable participant ID was not rebound to the target Auth UUID';
    end if;

    select count(*) into active_owner_count
    from public.kcp_memberships membership
    where membership.group_id = target_group
      and membership.status = 'active'
      and membership.role = 'owner'
      and membership.user_id = target_user;

    if active_owner_count <> 1 then
        raise exception 'Recovered user must be the single active Owner, found %', active_owner_count;
    end if;

    if not exists (
        select 1
        from public.kcp_assignment_policies policy
        where policy.schedule_plan_id = target_plan
          and policy.fixed_participant_id = stable_participant
    ) then
        raise exception 'Fixed assignment policy lost the stable participant';
    end if;

    if exists (
        select 1
        from public.kcp_trips trip
        where trip.group_id = target_group
          and trip.schedule_version = schedule_version
          and (
              trip.scheduled_participant_id <> stable_participant
              or trip.scheduled_driver_id <> target_user
          )
    ) then
        raise exception 'Generated trips did not preserve the participant while rebinding the driver Auth UUID';
    end if;

    if not exists (
        select 1
        from public.kcp_audit_events audit
        where audit.group_id = target_group
          and audit.action = 'stable_participant_identity_rebound'
          and audit.entity_id = stable_participant::text
    ) then
        raise exception 'Stable participant rebinding was not audited';
    end if;
end;
$$;

rollback;

select 'PASS: recovery preserves stable schedule participant identity' as result;
