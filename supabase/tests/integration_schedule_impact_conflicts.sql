begin;

insert into auth.users(
    id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
)
values
('7c111111-1111-4111-8111-111111111111'::uuid,'authenticated','authenticated','impact.owner@example.com',now(),'{}','{}',now(),now(),false),
('7c222222-2222-4222-8222-222222222222'::uuid,'authenticated','authenticated','impact.driver@example.com',now(),'{}','{}',now(),now(),false);

insert into public.kcp_profiles(id, display_name, account_email, identity_verified_at)
values
('7c111111-1111-4111-8111-111111111111'::uuid,'Impact Owner','impact.owner@example.com',now()),
('7c222222-2222-4222-8222-222222222222'::uuid,'Impact Driver','impact.driver@example.com',now());

select auth.become('7c111111-1111-4111-8111-111111111111'::uuid);

create temporary table impact_fixture(
    primary_group uuid,
    primary_plan uuid,
    primary_owner_participant uuid,
    primary_driver_participant uuid,
    secondary_group uuid,
    secondary_driver_participant uuid,
    primary_token text,
    secondary_token text,
    change_set uuid,
    candidate_ts timestamptz
);

insert into impact_fixture(primary_group, primary_plan, primary_owner_participant, candidate_ts)
select created.group_id, created.draft_plan_id, created.owner_participant_id,
       date_trunc('minute', now() + interval '6 hours')
from public.kcp_create_group_v3(
    'Impact primary group','other','Primary destination','Pilot',
    'UTC','Owner child','Level 1'
) created;

insert into impact_fixture(secondary_group, candidate_ts)
select created.group_id, (select candidate_ts from impact_fixture limit 1)
from public.kcp_create_group_v3(
    'Impact secondary group','other','Secondary destination','Pilot',
    'UTC','Owner second child','Level 1'
) created
where not exists (select 1 from impact_fixture where secondary_group is not null);

-- The second insert created a second fixture row. Collapse its group into the
-- first row and remove the helper row.
update impact_fixture target
set secondary_group = source.secondary_group
from impact_fixture source
where target.primary_group is not null
  and source.primary_group is null
  and source.secondary_group is not null;
delete from impact_fixture where primary_group is null;

with invitation as (
    select public.kcp_create_invitation_v2(
        (select primary_group from impact_fixture), 'Impact Driver', 'parent',
        null, null, 'Driver primary child', 4, true, 14
    ) as row
)
update impact_fixture set primary_token = (select (row).token from invitation);

with invitation as (
    select public.kcp_create_invitation_v2(
        (select secondary_group from impact_fixture), 'Impact Driver', 'parent',
        null, null, 'Driver secondary child', 4, true, 14
    ) as row
)
update impact_fixture set secondary_token = (select (row).token from invitation);

select auth.become('7c222222-2222-4222-8222-222222222222'::uuid);
select * from public.kcp_accept_invitation((select primary_token from impact_fixture),'Impact Driver',null);
select * from public.kcp_accept_invitation((select secondary_token from impact_fixture),'Impact Driver',null);

update impact_fixture fixture
set primary_driver_participant = participant.id
from public.kcp_group_participants participant
where participant.group_id = fixture.primary_group
  and participant.user_id = '7c222222-2222-4222-8222-222222222222'::uuid;
update impact_fixture fixture
set secondary_driver_participant = participant.id
from public.kcp_group_participants participant
where participant.group_id = fixture.secondary_group
  and participant.user_id = '7c222222-2222-4222-8222-222222222222'::uuid;

select auth.become('7c111111-1111-4111-8111-111111111111'::uuid);

-- Current primary ride is assigned to the Owner 30 minutes before the draft
-- candidate. The draft moves it to the invited driver and changes the time.
update public.kcp_groups set current_schedule_version = 1
where id in ((select primary_group from impact_fixture),(select secondary_group from impact_fixture));

insert into public.kcp_schedule_versions(
    group_id, version, status, reason, generated_by, generated_at,
    published_by, published_at, change_summary
)
select primary_group, 1, 'published', 'Current primary schedule',
       auth.uid(), now(), auth.uid(), now(), '{}'::jsonb
from impact_fixture
union all
select secondary_group, 1, 'published', 'Current secondary schedule',
       auth.uid(), now(), auth.uid(), now(), '{}'::jsonb
from impact_fixture;

insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
    status, scheduled_time, time_label, child_names
)
select primary_group, 1, candidate_ts::date, 'morning_drop', 'outbound', 'Primary ride',
       '7c111111-1111-4111-8111-111111111111'::uuid, 'Impact Owner', primary_owner_participant,
       'scheduled', candidate_ts - interval '30 minutes', 'Current time', array['Owner child']::text[]
from impact_fixture;

insert into public.kcp_trips(
    group_id, schedule_version, trip_date, kind, leg_type, display_label,
    scheduled_driver_id, scheduled_driver_name, scheduled_participant_id,
    status, scheduled_time, time_label, child_names
)
select secondary_group, 1, candidate_ts::date, 'morning_drop', 'outbound', 'Secondary conflicting ride',
       '7c222222-2222-4222-8222-222222222222'::uuid, 'Impact Driver', secondary_driver_participant,
       'scheduled', candidate_ts - interval '10 minutes', 'Conflict time', array['Driver secondary child']::text[]
from impact_fixture;

-- Configure one generic candidate occurrence at the same time in the primary
-- group and assign it to the invited driver.
select public.kcp_save_schedule_plan(
    p_plan_id => (select primary_plan from impact_fixture),
    p_name => 'Impact draft',
    p_starts_on => (select candidate_ts::date from impact_fixture),
    p_ends_on => (select candidate_ts::date from impact_fixture),
    p_outbound_label => 'Primary ride',
    p_return_label => 'Return',
    p_auto_complete_after_minutes => 60,
    p_sessions => (
        select jsonb_build_array(jsonb_build_object(
            'name', 'Candidate ride',
            'weekday', extract(isodow from candidate_ts)::integer,
            'intervalWeeks', 1,
            'anchorDate', candidate_ts::date,
            'outboundEnabled', true,
            'outboundTime', to_char(candidate_ts at time zone 'UTC', 'HH24:MI'),
            'returnEnabled', false,
            'returnTime', null,
            'returnDayOffset', 0,
            'displayOrder', 1
        )) from impact_fixture
    ),
    p_strategy => 'fixed',
    p_cycle_behavior => 'calendar',
    p_anchor_date => (select candidate_ts::date from impact_fixture),
    p_participant_ids => array[(select primary_driver_participant from impact_fixture)],
    p_fixed_participant_id => (select primary_driver_participant from impact_fixture)
);

with prepared as (
    select result.change_set_id
    from impact_fixture fixture
    cross join lateral public.kcp_prepare_schedule_change(
        fixture.primary_plan,
        'Move the ride and correct its time'
    ) result
)
update impact_fixture
set change_set = prepared.change_set_id
from prepared;

do $$
declare
    summary jsonb;
    details jsonb;
begin
    select change_set_row.summary into summary
    from public.kcp_schedule_change_sets change_set_row
    where change_set_row.id = (select change_set from impact_fixture);

    if coalesce((summary->>'timeChanged')::integer,0) <> 1
       or coalesce((summary->>'driverChanged')::integer,0) <> 0 then
        -- One matched occurrence is classified by the first changed field. The
        -- affected driver still follows the new participant on the impact row.
        raise exception 'Expected one time-changed ride: %', summary;
    end if;
    if coalesce((summary->>'conflicts')::integer,0) < 1 then
        raise exception 'Cross-group conflict was not detected: %', summary;
    end if;
    if coalesce((summary->>'urgentImpacts')::integer,0) < 1 then
        raise exception 'Change within 24 hours did not require acknowledgement: %', summary;
    end if;

    select public.kcp_schedule_change_details((select change_set from impact_fixture)) into details;
    if jsonb_array_length(details->'impacts') < 2 then
        raise exception 'Impact details are incomplete: %', details;
    end if;

    if not exists (
        select 1 from public.kcp_schedule_acknowledgements acknowledgement
        where acknowledgement.change_set_id = (select change_set from impact_fixture)
          and acknowledgement.user_id = '7c222222-2222-4222-8222-222222222222'::uuid
          and acknowledgement.status = 'pending'
    ) then
        raise exception 'Affected driver acknowledgement was not created';
    end if;
end;
$$;

select public.kcp_publish_schedule_plan_v2(
    (select primary_plan from impact_fixture),
    'Approved impact review',
    (select change_set from impact_fixture)
);

do $$
begin
    if (select status from public.kcp_schedule_change_sets where id = (select change_set from impact_fixture)) <> 'published' then
        raise exception 'Schedule change set was not marked published';
    end if;
    if not exists (
        select 1 from public.kcp_notification_outbox
        where target_user_id = '7c222222-2222-4222-8222-222222222222'::uuid
          and category = 'schedule_changed'
          and payload->>'changeSetId' = (select change_set::text from impact_fixture)
    ) then
        raise exception 'Affected driver schedule-change notification was not queued';
    end if;
end;
$$;

select auth.become('7c222222-2222-4222-8222-222222222222'::uuid);

do $$
begin
    if not exists (
        select 1 from public.kcp_my_schedule_acknowledgements()
        where change_set_id = (select change_set from impact_fixture)
          and status = 'pending'
    ) then
        raise exception 'Affected driver cannot see pending acknowledgement';
    end if;
    if not exists (select 1 from public.kcp_detect_user_conflicts(auth.uid(), now(), now() + interval '1 day')) then
        raise exception 'Published cross-group assignment conflict is not visible to the driver';
    end if;
end;
$$;

select public.kcp_acknowledge_schedule_change(
    (select change_set from impact_fixture),
    'acknowledged',
    'Reviewed both assignments'
);

do $$
begin
    if exists (
        select 1 from public.kcp_my_schedule_acknowledgements()
        where change_set_id = (select change_set from impact_fixture)
          and status = 'pending'
    ) then
        raise exception 'Acknowledged change remained pending';
    end if;
    if (select count(*) from public.kcp_list_schedule_templates(null)) < 5 then
        raise exception 'Generic schedule templates are missing';
    end if;
end;
$$;

rollback;

select 'PASS: templates, impact review, conflicts and acknowledgements verified' as result;
