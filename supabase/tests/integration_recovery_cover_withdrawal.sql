-- End-to-end recovery and cover-withdrawal regression suite.
-- Runs against a fresh local Supabase database and rolls back all test data.

begin;

-- Create real disposable Auth rows because recovery intentionally exercises
-- the same auth.users -> kcp_profiles foreign key path used in production.
insert into auth.users(
    id, aud, role, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, is_anonymous
)
values
    (
        '31111111-1111-4111-8111-111111111111'::uuid,
        'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb,
        now(), now(), true
    ),
    (
        '32222222-2222-4222-8222-222222222222'::uuid,
        'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb,
        now(), now(), true
    ),
    (
        '33333333-3333-4333-8333-333333333333'::uuid,
        'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb,
        now(), now(), true
    );

insert into public.kcp_profiles(id, display_name, phone)
values
    ('31111111-1111-4111-8111-111111111111'::uuid, 'Kiran', '6025550131'),
    ('32222222-2222-4222-8222-222222222222'::uuid, 'Kiran', '6025550131'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'Kiran', '6025550131');

do $$
declare
    v_source constant uuid := '31111111-1111-4111-8111-111111111111'::uuid;
    v_recovered constant uuid := '32222222-2222-4222-8222-222222222222'::uuid;
    v_restored constant uuid := '33333333-3333-4333-8333-333333333333'::uuid;
    v_group_id uuid;
    v_recovery_code text;
    v_source_device_secret text;
    v_device_secret text;
    v_trip_id uuid;
    v_request_id uuid;
    v_status text;
    v_claim_state text;
    v_error_seen boolean := false;
begin
    select g.id into v_group_id
    from public.kcp_groups g
    where g.code = 'KCP-BASIS-2026-27';
    if v_group_id is null then raise exception 'Canonical BASIS group missing'; end if;

    perform public.kcp_bind_seeded_roster(v_group_id, v_source, 'Kiran', true);

    perform set_config('request.jwt.claim.sub', v_source::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    select created.device_secret
      into v_source_device_secret
      from public.kcp_create_device_link(v_group_id, 'Previous Kiran device') created;

    select issued.recovery_code
      into v_recovery_code
      from public.kcp_issue_roster_recovery_code(
          'KCP-BASIS-2026-27',
          'Kiran',
          30
      ) issued;
    if v_recovery_code is null then raise exception 'Recovery code was not issued'; end if;

    perform set_config('request.jwt.claim.sub', v_recovered::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);

    perform public.kcp_recover_seeded_roster(
        'KCP-BASIS-2026-27',
        'Kiran',
        v_recovery_code
    );

    if not exists (
        select 1 from public.kcp_memberships m
        where m.group_id = v_group_id
          and m.user_id = v_recovered
          and m.role = 'owner'
          and m.status = 'active'
    ) then
        raise exception 'Recovered Kiran membership was not activated';
    end if;

    if exists (
        select 1 from public.kcp_memberships m
        where m.group_id = v_group_id
          and m.user_id = v_source
          and m.status = 'active'
    ) then
        raise exception 'Previous Kiran identity remained active after recovery';
    end if;

    if not exists (
        select 1 from public.kcp_device_links dl
        where dl.group_id = v_group_id
          and dl.user_id = v_source
          and dl.revoked_at is not null
    ) then
        raise exception 'Previous device credential was not revoked during recovery';
    end if;

    if (select r.claimed_user_id from public.kcp_roster_slots r
        where r.group_id = v_group_id and lower(r.parent_name) = 'kiran') <> v_recovered then
        raise exception 'Roster claim did not move to the recovered identity';
    end if;

    if (select g.created_by from public.kcp_groups g where g.id = v_group_id) <> v_recovered then
        raise exception 'Group ownership did not move to the recovered identity';
    end if;

    select s.claim_state into v_claim_state
    from public.kcp_seeded_pilot_status() s;
    if v_claim_state <> 'current_user' then
        raise exception 'Seeded status expected current_user after recovery, found %', v_claim_state;
    end if;

    select created.device_secret
      into v_device_secret
      from public.kcp_create_device_link(v_group_id, 'Integration test device') created;
    if length(v_device_secret) < 40 then
        raise exception 'Remembered-device secret is unexpectedly short';
    end if;

    perform set_config('request.jwt.claim.sub', v_restored::text, true);
    perform public.kcp_restore_device_link(v_device_secret);

    if not exists (
        select 1 from public.kcp_memberships m
        where m.group_id = v_group_id
          and m.user_id = v_restored
          and m.role = 'owner'
          and m.status = 'active'
    ) then
        raise exception 'Remembered-device restoration did not activate the replacement identity';
    end if;

    if exists (
        select 1 from public.kcp_memberships m
        where m.group_id = v_group_id
          and m.user_id = v_recovered
          and m.status = 'active'
    ) then
        raise exception 'Recovered identity remained active after remembered-device restoration';
    end if;

    if not exists (
        select 1 from public.kcp_device_links dl
        where dl.group_id = v_group_id
          and dl.user_id = v_restored
          and dl.revoked_at is null
          and dl.last_used_at is not null
    ) then
        raise exception 'Transferred remembered-device credential was not reactivated for the replacement identity';
    end if;

    if exists (
        select 1 from public.kcp_device_links dl
        where dl.group_id = v_group_id
          and dl.user_id = v_recovered
          and dl.revoked_at is null
    ) then
        raise exception 'Other recovered-device credentials remained active after identity transfer';
    end if;

    if not exists (
        select 1 from public.kcp_trips t
        where t.group_id = v_group_id
          and t.scheduled_driver_name = 'Kiran'
          and t.scheduled_driver_id = v_restored
    ) then
        raise exception 'Scheduled Kiran trips were not rebound to the restored identity';
    end if;

    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind,
        scheduled_driver_id, scheduled_driver_name,
        status, scheduled_time, time_label, child_names
    ) values (
        v_group_id, 9100, current_date + 10, 'morning_drop',
        v_restored, 'Kiran',
        'cover_requested', now() + interval '10 days', '7:00 AM',
        array['Thanishka','Kavish','Saanvi','Ishi']::text[]
    ) returning id into v_trip_id;

    insert into public.kcp_cover_requests(
        group_id, trip_id, requested_by, note, status
    ) values (
        v_group_id, v_trip_id, v_restored,
        'Testing a change of mind', 'open'
    ) returning id into v_request_id;

    perform public.kcp_withdraw_cover(v_request_id, 'Driver is available again');

    select t.status into v_status
    from public.kcp_trips t where t.id = v_trip_id;
    if v_status <> 'scheduled' then
        raise exception 'Withdrawn cover should restore scheduled status, found %', v_status;
    end if;

    if not exists (
        select 1 from public.kcp_cover_requests r
        where r.id = v_request_id
          and r.status = 'cancelled'
          and r.cancelled_by = v_restored
          and r.cancelled_at is not null
    ) then
        raise exception 'Cover request was not recorded as cancelled by the requester';
    end if;

    if not exists (
        select 1 from public.kcp_audit_events a
        where a.group_id = v_group_id
          and a.action = 'cover_request_withdrawn'
          and a.entity_id = v_request_id::text
    ) then
        raise exception 'Cover withdrawal audit event is missing';
    end if;

    update public.kcp_cover_requests r
       set status = 'accepted',
           accepted_by = v_source,
           accepted_at = now()
     where r.id = v_request_id;
    update public.kcp_trips t
       set status = 'cover_accepted',
           actual_driver_id = v_source,
           actual_driver_name = 'Other Driver',
           volunteer_assignment = true
     where t.id = v_trip_id;

    begin
        perform public.kcp_withdraw_cover(v_request_id, 'Too late');
    exception when others then
        v_error_seen := position('Only an open cover request' in sqlerrm) > 0;
    end;

    if not v_error_seen then
        raise exception 'Accepted coverage was incorrectly withdrawable';
    end if;
end;
$$;

rollback;

select 'PASS: seeded recovery, remembered-device restoration and cover withdrawal verified' as result;
