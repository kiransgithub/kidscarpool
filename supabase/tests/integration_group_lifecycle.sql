-- ===========================================================================
-- End-to-end smoke test of the RPC contract that iOS / Android / PWA share.
--
-- Covers: profile -> create group -> invite -> accept -> constraints request
-- -> admin review -> schedule build -> publish -> start/complete -> points
-- -> cover request/accept/withdraw -> owner invariant -> audit immutability
-- -> RLS isolation from a non-member.
--
-- Usage: psql -d kcp -v ON_ERROR_STOP=1 -f this_file
-- ===========================================================================

\set QUIET on
\pset pager off

do $$
declare
    v_owner uuid := gen_random_uuid();
    v_parent uuid := gen_random_uuid();
    v_stranger uuid := gen_random_uuid();
    v_group public.kcp_groups;
    v_group_id uuid;
    v_inv public.kcp_invitations;
    v_plan uuid;
    v_sess uuid;
    v_policy uuid;
    v_owner_pid uuid;
    v_parent_pid uuid;
    v_req uuid;
    v_trip public.kcp_trips;
    v_trip_id uuid;
    v_cover uuid;
    v_trips integer;
    v_points integer;
    v_visible integer;
    v_failed boolean;
begin
    insert into auth.users(id) values (v_owner), (v_parent), (v_stranger);

    -- ---- owner creates a group -------------------------------------------
    perform auth.become(v_owner);
    perform public.kcp_upsert_profile('Owner Parent');
    select created.group_id
      into v_group_id
      from public.kcp_create_group_v3(
          'Soccer Carpool', 'other', 'Community Soccer Field',
          'Fall season', 'America/Phoenix', 'Owner Child', 'Grade 4'
      ) created;
    select * into v_group from public.kcp_groups where id = v_group_id;
    assert v_group.code ~ '^KCP-[A-F0-9]{10}$', 'group code must use the KCP token format';

    v_owner_pid := public.kcp_current_participant_id(v_group.id);
    assert v_owner_pid is not null, 'creator must be an active participant';
    assert (select role from public.kcp_memberships
            where group_id = v_group.id and user_id = v_owner and status = 'active')
           = 'owner', 'creator must be owner';

    -- a fresh group ships with an empty draft plan
    select id into v_plan from public.kcp_schedule_plans
     where group_id = v_group.id and status = 'draft';
    assert v_plan is not null, 'group must be created with a draft plan';

    -- ---- invite a second parent ------------------------------------------
    v_inv := public.kcp_create_invitation_v2(
        p_group_id => v_group.id,
        p_member_name => 'Second Parent',
        p_role => 'parent',
        p_child_name => 'Second Child'
    );

    perform auth.become(v_parent);
    perform public.kcp_upsert_profile('Second Parent');
    perform public.kcp_accept_invitation(v_inv.token, 'Second Parent');
    v_parent_pid := public.kcp_current_participant_id(v_group.id);
    assert v_parent_pid is not null, 'invitee must become an active participant';

    -- ---- constraint request + admin review --------------------------------
    v_req := public.kcp_submit_constraint_request(
        v_group.id, '{1,3,5}'::smallint[], '{1,3}'::smallint[], 'No Tuesdays');
    assert (select status from public.kcp_constraints where id = v_req) = 'pending',
           'submitted constraints start pending';

    perform auth.become(v_parent);
    v_failed := false;
    begin
        perform public.kcp_review_constraint_request(v_req, true);
    exception when others then v_failed := true;
    end;
    assert v_failed, 'a plain parent must not be able to approve constraints';

    perform auth.become(v_owner);
    perform public.kcp_review_constraint_request(v_req, true, 'Approved');
    assert (select status from public.kcp_constraints where id = v_req) = 'approved',
           'admin approval must flip status';
    assert (select count(*) from public.kcp_constraints
            where group_id = v_group.id and participant_id = v_parent_pid
              and status = 'approved') = 1,
           'exactly one approved constraint row per participant';

    -- ---- build a schedule: Mon+Wed, alternating drivers per week ----------
    update public.kcp_schedule_plans
       set starts_on = date '2026-09-07', ends_on = date '2026-10-02',
           outbound_label = 'To practice', return_label = 'Home'
     where id = v_plan;

    insert into public.kcp_recurring_sessions(
        schedule_plan_id, name, weekday, outbound_time, return_time, display_order)
    values (v_plan, 'Monday practice', 1, time '16:30', time '18:00', 1)
    returning id into v_sess;
    insert into public.kcp_recurring_sessions(
        schedule_plan_id, name, weekday, outbound_time, return_time, display_order)
    values (v_plan, 'Wednesday practice', 3, time '16:30', time '18:00', 2);

    insert into public.kcp_assignment_policies(
        schedule_plan_id, strategy, cycle_behavior, anchor_date)
    values (v_plan, 'round_robin_week', 'occurrence', date '2026-09-07')
    returning id into v_policy;
    insert into public.kcp_assignment_policy_members(
        policy_id, participant_id, rotation_position)
    values (v_policy, v_owner_pid, 1), (v_policy, v_parent_pid, 2);

    -- ---- publish -----------------------------------------------------------
    v_trips := public.kcp_publish_schedule_plan(v_plan, 'First publish');
    assert v_trips > 0, 'publishing must create trips';
    assert (select status from public.kcp_schedule_plans where id = v_plan)
           = 'published', 'plan must be published';
    assert (select active_schedule_plan_id from public.kcp_groups
            where id = v_group.id) = v_plan, 'group must point at the live plan';

    -- a whole week belongs to one driver
    assert (select count(distinct scheduled_participant_id) = 1
            from public.kcp_trips t
            join public.kcp_responsibility_blocks b
              on b.id = t.responsibility_block_id
            where t.schedule_plan_id = v_plan
              and b.block_key = (select block_key
                                 from public.kcp_responsibility_blocks
                                 where schedule_plan_id = v_plan
                                 order by block_start limit 1)),
           'a weekly block must have exactly one driver';

    -- ---- trip time gate ----------------------------------------------------
    select * into v_trip from public.kcp_trips
     where schedule_plan_id = v_plan
       and scheduled_participant_id = v_owner_pid
     order by scheduled_time limit 1;
    v_trip_id := v_trip.id;

    v_failed := false;
    begin
        perform public.kcp_start_trip(v_trip_id);   -- scheduled far in future
    exception when others then v_failed := true;
    end;
    assert v_failed, 'a trip must not be startable outside its time window';

    -- pull it into the window, then run the lifecycle
    update public.kcp_trips set scheduled_time = now() where id = v_trip_id;
    perform public.kcp_confirm_trip(v_trip_id);
    perform public.kcp_start_trip(v_trip_id);
    assert (select status from public.kcp_trips where id = v_trip_id)
           = 'in_progress', 'trip must be in progress';
    update public.kcp_trips set started_at = now() - interval '4 minutes'
     where id = v_trip_id;
    perform public.kcp_complete_trip(v_trip_id);
    perform public.kcp_confirm_trip_completion(v_trip_id);
    assert (select status from public.kcp_trips where id = v_trip_id)
           = 'completed', 'trip must be completed';

    select points into v_points from public.kcp_points_ledger
     where trip_id = v_trip_id;
    assert v_points = 10, 'a regular completed trip awards 10 points';

    -- ---- cover request -----------------------------------------------------
    select id into v_trip_id from public.kcp_trips
     where schedule_plan_id = v_plan
       and scheduled_participant_id = v_owner_pid
       and status = 'scheduled'
     order by scheduled_time limit 1;

    v_cover := public.kcp_request_cover(v_trip_id, 'Work conflict');

    v_failed := false;
    begin
        perform public.kcp_accept_cover(v_cover);   -- still acting as owner
    exception when others then v_failed := true;
    end;
    assert v_failed, 'you must not be able to cover your own trip';

    perform auth.become(v_parent);
    perform public.kcp_accept_cover(v_cover);
    assert (select actual_participant_id from public.kcp_trips where id = v_trip_id)
           = v_parent_pid, 'cover must reassign the trip';
    assert (select volunteer_assignment from public.kcp_trips where id = v_trip_id),
           'covered trips are volunteer assignments';

    update public.kcp_trips set scheduled_time = now() where id = v_trip_id;
    perform public.kcp_confirm_trip(v_trip_id);
    perform public.kcp_start_trip(v_trip_id);
    update public.kcp_trips set started_at = now() - interval '4 minutes'
     where id = v_trip_id;
    perform public.kcp_complete_trip(v_trip_id);
    perform public.kcp_confirm_trip_completion(v_trip_id);
    assert (select points from public.kcp_points_ledger where trip_id = v_trip_id)
           = 20, 'a volunteer trip awards 20 points';

    -- ---- withdrawal returns the trip to its original driver ---------------
    select t.id into v_trip_id from public.kcp_trips t
     where t.schedule_plan_id = v_plan
       and t.scheduled_participant_id = v_owner_pid
       and t.status = 'scheduled'
     order by t.scheduled_time limit 1;
    perform auth.become(v_owner);
    v_cover := public.kcp_request_cover(v_trip_id, 'Second conflict');
    perform auth.become(v_parent);
    perform public.kcp_accept_cover(v_cover);
    perform public.kcp_withdraw_cover(v_cover, 'Sick');
    assert (select actual_participant_id from public.kcp_trips where id = v_trip_id)
           is null, 'withdrawal must clear the volunteer';
    assert (select status from public.kcp_cover_requests where id = v_cover)
           = 'withdrawn', 'request must be marked withdrawn';

    -- ---- exactly one active owner is enforced -----------------------------
    perform auth.become(v_owner);
    v_failed := false;
    begin
        update public.kcp_memberships
           set role = 'owner'
         where group_id = v_group.id and user_id = v_parent and status = 'active';
    exception when unique_violation then v_failed := true;
    end;
    assert v_failed, 'a second active owner must be rejected';
    assert (select count(*) from public.kcp_memberships membership
            where membership.group_id = v_group.id
              and membership.role = 'owner' and membership.status = 'active') = 1,
           'exactly one active owner at all times';

    -- ---- audit log is append-only -----------------------------------------
    assert (select count(*) from public.kcp_audit_events
            where group_id = v_group.id) > 0, 'actions must be audited';
    v_failed := false;
    begin
        update public.kcp_audit_events set action = 'tampered'
         where group_id = v_group.id;
    exception when others then v_failed := true;
    end;
    assert v_failed, 'audit events must reject updates';

    v_failed := false;
    begin
        delete from public.kcp_audit_events where group_id = v_group.id;
    exception when others then v_failed := true;
    end;
    assert v_failed, 'audit events must reject deletes';

    raise notice 'PASS: group lifecycle, scheduling, cover, points and audit';
end;
$$;

-- ---- RLS: a non-member must see nothing -----------------------------------
do $$
declare
    v_stranger uuid;
    v_seen integer;
begin
    select id into v_stranger from auth.users
     where id not in (select user_id from public.kcp_group_participants
                      where user_id is not null)
     limit 1;
    perform auth.become(v_stranger);
    perform public.kcp_upsert_profile('Stranger');

    set local role authenticated;
    select count(*) into v_seen from public.kcp_groups;
    assert v_seen = 0, format('non-member saw %s groups', v_seen);
    select count(*) into v_seen from public.kcp_trips;
    assert v_seen = 0, format('non-member saw %s trips', v_seen);
    select count(*) into v_seen from public.kcp_group_participants;
    assert v_seen = 0, format('non-member saw %s participants', v_seen);
    reset role;

    raise notice 'PASS: RLS isolates non-members';
end;
$$;
