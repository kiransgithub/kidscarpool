begin;

-- ---------------------------------------------------------------------------
-- Driver-first trip execution
-- ---------------------------------------------------------------------------

create or replace function public.kcp_driver_trip_snapshot(p_trip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    scope text;
    roster jsonb;
    timeline jsonb;
    group_record public.kcp_groups;
begin
    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;

    scope := public.kcp_trip_roster_access_scope(p_trip_id);
    if scope not in ('assigned_driver','owner_admin') then
        raise exception 'Driver mode is available only to the assigned driver near ride time or a group administrator';
    end if;

    select * into group_record from public.kcp_groups where id = trip.group_id;

    select coalesce(jsonb_agg(
        to_jsonb(roster_row)
        || jsonb_build_object(
            'parent_name', member.parent_name,
            'parent_phone', member.phone,
            'latest_status', latest.event_type,
            'latest_status_at', latest.server_timestamp
        )
        order by roster_row.child_name
    ), '[]'::jsonb)
    into roster
    from public.kcp_get_trip_operational_roster(p_trip_id) roster_row
    left join public.kcp_children child on child.id = roster_row.child_id
    left join public.kcp_group_participants participant on participant.id = child.participant_id
    left join public.kcp_memberships member
      on member.group_id = child.group_id
     and member.user_id = participant.user_id
     and member.status = 'active'
    left join lateral (
        select event.event_type, event.server_timestamp
        from public.kcp_trip_events event
        where event.trip_id = p_trip_id
          and event.child_id = roster_row.child_id
          and event.event_type in ('child_picked_up','child_skipped')
        order by event.server_timestamp desc, event.id desc
        limit 1
    ) latest on true;

    select coalesce(jsonb_agg(jsonb_build_object(
        'eventType', event.event_type,
        'actorName', profile.display_name,
        'childId', event.child_id,
        'serverTimestamp', event.server_timestamp
    ) order by event.server_timestamp, event.id), '[]'::jsonb)
    into timeline
    from public.kcp_trip_events event
    left join public.kcp_profiles profile on profile.id = event.actor_id
    where event.trip_id = p_trip_id;

    return jsonb_build_object(
        'trip', to_jsonb(trip) - 'child_names' - 'notes'
            || jsonb_build_object(
                'child_count', cardinality(trip.child_names),
                'display_label', coalesce(trip.display_label, case when trip.kind = 'afternoon_pickup' then 'Return' else 'Outbound' end)
            ),
        'group', jsonb_build_object(
            'id', group_record.id,
            'name', group_record.name,
            'destination', coalesce(group_record.destination_name, group_record.school_name),
            'timezone', group_record.timezone,
            'safetyRequired', group_record.safety_profiles_required
        ),
        'accessScope', scope,
        'roster', roster,
        'events', timeline
    );
end;
$$;

create or replace function public.kcp_mark_child_trip_status(
    p_trip_id uuid,
    p_child_id uuid,
    p_status text,
    p_client_event_id text default null,
    p_note text default null,
    p_device_timestamp timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    event_type text;
    driver_id uuid;
    child_name text;
    result_id uuid;
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id <> auth.uid() and not public.kcp_is_admin(trip.group_id) then
        raise exception 'Only the active driver or a group administrator can update the child roster';
    end if;
    if trip.status <> 'in_progress' then raise exception 'Start the ride before updating child pickup status'; end if;
    if p_status not in ('picked_up','skipped') then raise exception 'Choose Picked up or Skipped'; end if;

    select child.name into child_name
    from public.kcp_children child
    where child.id = p_child_id
      and child.group_id = trip.group_id
      and child.name = any(trip.child_names)
      and child.status = 'active';
    if child_name is null then raise exception 'Child is not part of this ride'; end if;

    event_type := case when p_status = 'picked_up' then 'child_picked_up' else 'child_skipped' end;
    result_id := public.kcp_record_trip_event(
        trip.id, event_type, auth.uid(), p_child_id,
        p_client_event_id, p_device_timestamp,
        jsonb_build_object('childName', child_name, 'note', nullif(trim(p_note), ''))
    );

    perform public.kcp_write_audit(
        trip.group_id, event_type, 'trip_child', p_child_id::text,
        jsonb_build_object('tripId', trip.id, 'childName', child_name, 'note', nullif(trim(p_note), ''))
    );
    return result_id;
end;
$$;

create or replace function public.kcp_report_destination_arrival(
    p_trip_id uuid,
    p_client_event_id text default null,
    p_device_timestamp timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    required_count integer;
    accounted_count integer;
    group_required boolean;
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id <> auth.uid() then raise exception 'Only the active driver can report destination arrival'; end if;
    if trip.status <> 'in_progress' then raise exception 'Ride must be in progress'; end if;

    select safety_profiles_required into group_required from public.kcp_groups where id = trip.group_id;
    required_count := cardinality(trip.child_names);
    select count(*) into accounted_count
    from unnest(trip.child_names) child_name
    where exists (
        select 1
        from public.kcp_children child
        join lateral (
            select event.event_type
            from public.kcp_trip_events event
            where event.trip_id = trip.id
              and event.child_id = child.id
              and event.event_type in ('child_picked_up','child_skipped')
            order by event.server_timestamp desc, event.id desc
            limit 1
        ) latest on true
        where child.group_id = trip.group_id
          and child.name = child_name
          and child.status = 'active'
    );

    if group_required and accounted_count < required_count then
        raise exception 'Account for every child as Picked up or Skipped before reporting destination arrival';
    end if;

    perform public.kcp_record_trip_event(
        trip.id, 'arrived_destination', auth.uid(), null,
        p_client_event_id, p_device_timestamp,
        jsonb_build_object('accountedChildren', accounted_count, 'expectedChildren', required_count)
    );

    return public.kcp_complete_trip(trip.id);
end;
$$;

create or replace function public.kcp_report_trip_issue(
    p_trip_id uuid,
    p_category text,
    p_note text,
    p_client_event_id text default null,
    p_device_timestamp timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    result_id uuid;
begin
    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;
    if not public.kcp_is_member(trip.group_id) then raise exception 'Active group membership required'; end if;
    if length(trim(coalesce(p_note,''))) < 3 then raise exception 'Describe the ride issue'; end if;

    result_id := public.kcp_record_trip_event(
        trip.id, 'issue_reported', auth.uid(), null,
        p_client_event_id, p_device_timestamp,
        jsonb_build_object(
            'category', coalesce(nullif(trim(p_category), ''), 'other'),
            'note', trim(p_note)
        )
    );
    perform public.kcp_write_audit(
        trip.group_id, 'trip_issue_reported', 'trip', trip.id::text,
        jsonb_build_object('category', coalesce(nullif(trim(p_category), ''), 'other'), 'note', trim(p_note))
    );
    return result_id;
end;
$$;

revoke all on function public.kcp_driver_trip_snapshot(uuid) from public, anon;
revoke all on function public.kcp_mark_child_trip_status(uuid,uuid,text,text,text,timestamptz) from public, anon;
revoke all on function public.kcp_report_destination_arrival(uuid,text,timestamptz) from public, anon;
revoke all on function public.kcp_report_trip_issue(uuid,text,text,text,timestamptz) from public, anon;
grant execute on function public.kcp_driver_trip_snapshot(uuid) to authenticated;
grant execute on function public.kcp_mark_child_trip_status(uuid,uuid,text,text,text,timestamptz) to authenticated;
grant execute on function public.kcp_report_destination_arrival(uuid,text,timestamptz) to authenticated;
grant execute on function public.kcp_report_trip_issue(uuid,text,text,text,timestamptz) to authenticated;

commit;
