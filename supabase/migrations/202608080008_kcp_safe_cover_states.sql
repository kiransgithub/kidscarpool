begin;

alter table public.kcp_cover_requests
    add column if not exists prior_trip_status text,
    add column if not exists released_at timestamptz,
    add column if not exists released_by uuid references public.kcp_profiles(id) on delete set null,
    add column if not exists release_reason text;

create or replace function public.kcp_request_cover(
    p_trip_id uuid,
    p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    request_id uuid;
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    if not public.kcp_is_member(trip.group_id) then raise exception 'Active group membership required'; end if;
    if trip.scheduled_driver_id <> auth.uid() and not public.kcp_is_admin(trip.group_id) then
        raise exception 'Only the assigned driver or an admin can request cover';
    end if;
    if trip.started_at is not null or trip.status in ('in_progress','completion_due','completed','cancelled') then
        raise exception 'Cover cannot be requested after the ride has started';
    end if;
    if trip.status not in ('scheduled','coverage_needed','ready','confirmation_due','unconfirmed') then
        raise exception 'Cover cannot be requested from the current ride status';
    end if;

    insert into public.kcp_cover_requests(
        group_id, trip_id, requested_by, note, prior_trip_status
    ) values (
        trip.group_id, trip.id, auth.uid(), coalesce(p_note,''), trip.status
    ) returning id into request_id;

    update public.kcp_trips
       set status = 'cover_requested'
     where id = trip.id;

    perform public.kcp_write_audit(
        trip.group_id, 'cover_requested', 'trip', trip.id::text,
        jsonb_build_object(
            'note', coalesce(p_note,''),
            'priorStatus', trip.status,
            'driverConfirmed', trip.confirmed_at is not null
        )
    );
    return request_id;
end;
$$;

create or replace function public.kcp_accept_cover(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    request public.kcp_cover_requests;
    trip public.kcp_trips;
    volunteer_name text;
    volunteer_participant uuid;
    group_requires_safety boolean;
    capacity record;
begin
    select * into request
    from public.kcp_cover_requests
    where id = p_request_id
    for update;
    if not found then raise exception 'Cover request not found'; end if;
    if request.status <> 'open' then raise exception 'This cover request is no longer open'; end if;
    if not public.kcp_is_member(request.group_id) then raise exception 'Active group membership required'; end if;

    select participant.id, profile.display_name
      into volunteer_participant, volunteer_name
      from public.kcp_group_participants participant
      join public.kcp_profiles profile on profile.id = participant.user_id
     where participant.group_id = request.group_id
       and participant.user_id = auth.uid()
       and participant.status = 'active'
       and participant.can_drive
     limit 1;
    if volunteer_participant is null then
        raise exception 'Only an active driving member can volunteer';
    end if;

    select * into trip from public.kcp_trips where id = request.trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    if trip.status <> 'cover_requested' then raise exception 'This ride is no longer waiting for a volunteer'; end if;
    if trip.scheduled_driver_id = auth.uid() then raise exception 'The assigned driver cannot volunteer for their own cover request'; end if;

    select safety_profiles_required into group_requires_safety
      from public.kcp_groups where id = request.group_id;
    if group_requires_safety then
        select * into capacity
        from public.kcp_trip_capacity_status(trip.id, volunteer_participant);
        if capacity is null or not capacity.eligible then
            raise exception '%', coalesce(capacity.message, 'Complete driving readiness before volunteering');
        end if;
    end if;

    update public.kcp_cover_requests
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = request.id;

    update public.kcp_trips
       set actual_driver_id = auth.uid(),
           actual_driver_name = volunteer_name,
           actual_participant_id = volunteer_participant,
           volunteer_assignment = true,
           status = 'cover_accepted',
           confirmed_at = null,
           confirmed_by = null,
           confirmation_due_at = null,
           unconfirmed_at = null,
           verification_note = null
     where id = trip.id;

    perform public.kcp_write_audit(
        request.group_id, 'cover_accepted', 'trip', trip.id::text,
        jsonb_build_object(
            'volunteerUserId', auth.uid(),
            'volunteerName', volunteer_name,
            'requestedByUserId', request.requested_by,
            'confirmationRequired', true,
            'pointsOnConfirmedCompletion', 20
        )
    );
    return trip.id;
end;
$$;

create or replace function public.kcp_withdraw_cover(
    p_request_id uuid,
    p_reason text default 'Driver is available again'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    request public.kcp_cover_requests;
    trip public.kcp_trips;
    restored_status text;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    select * into request from public.kcp_cover_requests where id = p_request_id for update;
    if not found then raise exception 'Cover request was not found'; end if;
    if request.status <> 'open' then raise exception 'Only an open cover request can be withdrawn'; end if;
    if request.requested_by <> auth.uid() and not public.kcp_is_admin(request.group_id) then
        raise exception 'Only the requester or a group admin can withdraw this cover request';
    end if;

    select * into trip from public.kcp_trips where id = request.trip_id for update;
    if not found then raise exception 'Trip was not found'; end if;
    if trip.status <> 'cover_requested' then raise exception 'The ride is no longer waiting for coverage'; end if;

    restored_status := case
        when trip.scheduled_driver_id is null then 'coverage_needed'
        when request.prior_trip_status in ('scheduled','ready','confirmation_due','unconfirmed')
            then request.prior_trip_status
        else 'scheduled'
    end;

    update public.kcp_cover_requests
       set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
           cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Driver is available again')
     where id = request.id;

    update public.kcp_trips
       set status = restored_status,
           actual_driver_id = null,
           actual_driver_name = null,
           actual_participant_id = null,
           volunteer_assignment = false
     where id = trip.id;

    perform public.kcp_write_audit(
        request.group_id, 'cover_request_withdrawn', 'cover_request', request.id::text,
        jsonb_build_object(
            'tripId', trip.id,
            'restoredStatus', restored_status,
            'reason', coalesce(nullif(trim(p_reason), ''), 'Driver is available again')
        )
    );
    return trip.id;
end;
$$;

-- Once accepted, the volunteer can release the ride or a group administrator
-- can coordinate reassignment. The original requester cannot silently undo it.
create or replace function public.kcp_release_accepted_cover(
    p_request_id uuid,
    p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    request public.kcp_cover_requests;
    trip public.kcp_trips;
begin
    select * into request from public.kcp_cover_requests where id = p_request_id for update;
    if not found then raise exception 'Cover request was not found'; end if;
    if request.status <> 'accepted' then raise exception 'Only an accepted cover can be released'; end if;
    if request.accepted_by <> auth.uid() and not public.kcp_is_admin(request.group_id) then
        raise exception 'Only the volunteer or a group admin can release an accepted cover';
    end if;
    if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Provide a reason for releasing this ride'; end if;

    select * into trip from public.kcp_trips where id = request.trip_id for update;
    if not found then raise exception 'Trip was not found'; end if;
    if trip.started_at is not null or trip.status in ('in_progress','completion_due','completed') then
        raise exception 'An accepted cover cannot be released after the ride has started';
    end if;

    update public.kcp_cover_requests
       set status = 'cancelled', released_at = now(), released_by = auth.uid(),
           release_reason = trim(p_reason), cancellation_reason = trim(p_reason),
           cancelled_at = now(), cancelled_by = auth.uid()
     where id = request.id;

    update public.kcp_trips
       set status = 'coverage_needed',
           actual_driver_id = null,
           actual_driver_name = null,
           actual_participant_id = null,
           volunteer_assignment = false,
           confirmed_at = null,
           confirmed_by = null,
           confirmation_due_at = null,
           unconfirmed_at = null
     where id = trip.id;

    perform public.kcp_write_audit(
        request.group_id, 'accepted_cover_released', 'cover_request', request.id::text,
        jsonb_build_object('tripId', trip.id, 'releasedBy', auth.uid(), 'reason', trim(p_reason))
    );
    return trip.id;
end;
$$;

revoke all on function public.kcp_request_cover(uuid,text) from public, anon;
revoke all on function public.kcp_accept_cover(uuid) from public, anon;
revoke all on function public.kcp_withdraw_cover(uuid,text) from public, anon;
revoke all on function public.kcp_release_accepted_cover(uuid,text) from public, anon;
grant execute on function public.kcp_request_cover(uuid,text) to authenticated;
grant execute on function public.kcp_accept_cover(uuid) to authenticated;
grant execute on function public.kcp_withdraw_cover(uuid,text) to authenticated;
grant execute on function public.kcp_release_accepted_cover(uuid,text) to authenticated;

commit;
