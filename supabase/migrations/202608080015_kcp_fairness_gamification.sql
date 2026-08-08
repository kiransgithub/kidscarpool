begin;

-- ---------------------------------------------------------------------------
-- Workload fairness is operational; points are optional gamification.
-- ---------------------------------------------------------------------------

alter table public.kcp_groups
    add column if not exists points_enabled boolean not null default true,
    add column if not exists public_leaderboard_enabled boolean not null default true,
    add column if not exists fairness_time_weight numeric(6,3) not null default 0.250
        check (fairness_time_weight between 0 and 10),
    add column if not exists fairness_child_weight numeric(6,3) not null default 0.050
        check (fairness_child_weight between 0 and 10);

create or replace function public.kcp_set_participation_settings(
    p_group_id uuid,
    p_points_enabled boolean,
    p_public_leaderboard_enabled boolean,
    p_fairness_time_weight numeric default 0.250,
    p_fairness_child_weight numeric default 0.050
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or Admin role required';
    end if;
    if p_fairness_time_weight < 0 or p_fairness_time_weight > 10
       or p_fairness_child_weight < 0 or p_fairness_child_weight > 10 then
        raise exception 'Fairness weights must be between 0 and 10';
    end if;

    update public.kcp_groups
       set points_enabled = p_points_enabled,
           public_leaderboard_enabled = p_public_leaderboard_enabled,
           fairness_time_weight = p_fairness_time_weight,
           fairness_child_weight = p_fairness_child_weight,
           updated_at = now()
     where id = p_group_id;

    perform public.kcp_write_audit(
        p_group_id, 'participation_settings_updated', 'group', p_group_id::text,
        jsonb_build_object(
            'pointsEnabled', p_points_enabled,
            'publicLeaderboardEnabled', p_public_leaderboard_enabled,
            'timeWeight', p_fairness_time_weight,
            'childWeight', p_fairness_child_weight
        )
    );
end;
$$;

create or replace function public.kcp_group_fairness(p_group_id uuid)
returns table(
    user_id uuid,
    parent_name text,
    membership_role text,
    upcoming_assigned integer,
    completed_rides integer,
    volunteer_rides integer,
    cancelled_rides integer,
    estimated_minutes integer,
    children_transported integer,
    fairness_units numeric,
    participation_share numeric,
    balance_delta numeric,
    points integer,
    points_visible boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    caller_role text;
    group_record public.kcp_groups;
begin
    select member.role into caller_role
    from public.kcp_memberships member
    where member.group_id = p_group_id
      and member.user_id = auth.uid()
      and member.status = 'active';
    if caller_role is null then raise exception 'Active group membership required'; end if;
    if caller_role = 'viewer' then return; end if;

    select * into group_record from public.kcp_groups where id = p_group_id;

    return query
    with drivers as (
        select member.user_id, member.parent_name, member.role
        from public.kcp_memberships member
        join public.kcp_group_participants participant
          on participant.group_id = member.group_id
         and participant.user_id = member.user_id
         and participant.status = 'active'
         and participant.can_drive
        where member.group_id = p_group_id
          and member.status = 'active'
          and member.role <> 'viewer'
    ), raw_metrics as (
        select
            driver.user_id,
            driver.parent_name,
            driver.role,
            count(*) filter (
                where trip.schedule_version = group_record.current_schedule_version
                  and trip.status in (
                      'scheduled','coverage_needed','cover_requested','cover_accepted',
                      'confirmation_due','ready','in_progress','completion_due','unconfirmed'
                  )
                  and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = driver.user_id
                  and coalesce(trip.scheduled_time, trip.trip_date::timestamptz) >= now()
            )::integer as upcoming_assigned,
            count(*) filter (
                where trip.status = 'completed'
                  and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = driver.user_id
            )::integer as completed_rides,
            count(*) filter (
                where trip.status = 'completed'
                  and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = driver.user_id
                  and (
                      trip.volunteer_assignment
                      or (
                          trip.actual_driver_id is not null
                          and trip.scheduled_driver_id is not null
                          and trip.actual_driver_id <> trip.scheduled_driver_id
                      )
                  )
            )::integer as volunteer_rides,
            count(*) filter (
                where trip.status = 'cancelled'
                  and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = driver.user_id
            )::integer as cancelled_rides,
            coalesce(sum(group_record.auto_complete_after_minutes) filter (
                where trip.status = 'completed'
                  and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = driver.user_id
            ), 0)::integer as estimated_minutes,
            coalesce(sum(cardinality(trip.child_names)) filter (
                where trip.status = 'completed'
                  and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = driver.user_id
            ), 0)::integer as children_transported,
            coalesce((
                select sum(ledger.points)::integer
                from public.kcp_points_ledger ledger
                where ledger.group_id = p_group_id and ledger.user_id = driver.user_id
            ), 0) as points
        from drivers driver
        left join public.kcp_trips trip on trip.group_id = p_group_id
        group by driver.user_id, driver.parent_name, driver.role
    ), weighted as (
        select raw_metrics.*,
               round(
                   raw_metrics.completed_rides::numeric
                   + (raw_metrics.estimated_minutes::numeric / 60.0) * group_record.fairness_time_weight
                   + raw_metrics.children_transported::numeric * group_record.fairness_child_weight,
                   3
               ) as units
        from raw_metrics
    ), totals as (
        select weighted.*,
               coalesce(sum(weighted.units) over (), 0) as total_units,
               coalesce(avg(weighted.units) over (), 0) as average_units
        from weighted
    )
    select
        totals.user_id,
        totals.parent_name,
        totals.role,
        totals.upcoming_assigned,
        totals.completed_rides,
        totals.volunteer_rides,
        totals.cancelled_rides,
        totals.estimated_minutes,
        totals.children_transported,
        totals.units,
        case when totals.total_units = 0 then 0
             else round(totals.units / totals.total_units * 100, 1) end,
        round(totals.units - totals.average_units, 3),
        case
            when group_record.points_enabled
             and (
                 group_record.public_leaderboard_enabled
                 or caller_role in ('owner','admin')
                 or totals.user_id = auth.uid()
             ) then totals.points
            else 0
        end,
        group_record.points_enabled
          and (
              group_record.public_leaderboard_enabled
              or caller_role in ('owner','admin')
              or totals.user_id = auth.uid()
          )
    from totals
    where group_record.public_leaderboard_enabled
       or caller_role in ('owner','admin')
       or totals.user_id = auth.uid()
    order by totals.units desc, totals.parent_name;
end;
$$;

create or replace function public.kcp_my_fairness_summary()
returns table(
    group_id uuid,
    group_name text,
    completed_rides integer,
    volunteer_rides integer,
    upcoming_assigned integer,
    estimated_minutes integer,
    children_transported integer,
    fairness_units numeric,
    points integer,
    points_enabled boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    membership record;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    for membership in
        select member.group_id, group_row.name
        from public.kcp_memberships member
        join public.kcp_groups group_row on group_row.id = member.group_id
        where member.user_id = auth.uid()
          and member.status = 'active'
          and member.role <> 'viewer'
          and group_row.status = 'active'
    loop
        return query
        select membership.group_id, membership.name,
               fairness.completed_rides, fairness.volunteer_rides,
               fairness.upcoming_assigned, fairness.estimated_minutes,
               fairness.children_transported, fairness.fairness_units,
               fairness.points, group_row.points_enabled
        from public.kcp_group_fairness(membership.group_id) fairness
        join public.kcp_groups group_row on group_row.id = membership.group_id
        where fairness.user_id = auth.uid();
    end loop;
end;
$$;

-- Replace the point awarder created by the safe trip state machine. Completion
-- remains auditable even when a group disables gamification.
create or replace function public.kcp_award_confirmed_trip_points(p_trip_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    earned integer;
    reason_value text;
    enabled boolean;
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    if trip.status <> 'completed' or trip.completed_at is null then
        raise exception 'Points require a confirmed completed trip';
    end if;

    select group_row.points_enabled into enabled
    from public.kcp_groups group_row where group_row.id = trip.group_id;
    if not enabled then return 0; end if;

    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id is null then raise exception 'No driver is assigned'; end if;
    earned := case
        when trip.volunteer_assignment
          or (trip.actual_driver_id is not null and trip.actual_driver_id <> trip.scheduled_driver_id)
        then 20 else 10 end;
    reason_value := case when earned = 20 then 'volunteer_trip' else 'scheduled_trip' end;

    insert into public.kcp_points_ledger(group_id, trip_id, user_id, points, reason)
    values (trip.group_id, trip.id, driver_id, earned, reason_value)
    on conflict (trip_id) do nothing;
    return earned;
end;
$$;

revoke all on function public.kcp_set_participation_settings(uuid,boolean,boolean,numeric,numeric) from public, anon;
revoke all on function public.kcp_group_fairness(uuid) from public, anon;
revoke all on function public.kcp_my_fairness_summary() from public, anon;
revoke all on function public.kcp_award_confirmed_trip_points(uuid) from public, anon, authenticated;
grant execute on function public.kcp_set_participation_settings(uuid,boolean,boolean,numeric,numeric) to authenticated;
grant execute on function public.kcp_group_fairness(uuid) to authenticated;
grant execute on function public.kcp_my_fairness_summary() to authenticated;

commit;
