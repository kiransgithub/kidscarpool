begin;

-- Prevent a late volunteer acceptance from moving a trip backwards after it
-- has already started or completed.
create or replace function public.kcp_accept_cover(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    req public.kcp_cover_requests;
    trip public.kcp_trips;
    volunteer_name text;
begin
    select * into req
    from public.kcp_cover_requests
    where id = p_request_id
    for update;
    if not found then raise exception 'Cover request not found'; end if;
    if req.status <> 'open' then raise exception 'This cover request is no longer open'; end if;
    if not public.kcp_is_member(req.group_id) then
        raise exception 'Active group membership required';
    end if;
    if not exists (
        select 1
        from public.kcp_memberships m
        where m.group_id = req.group_id
          and m.user_id = auth.uid()
          and m.status = 'active'
          and m.role <> 'viewer'
    ) then
        raise exception 'Only an active driving parent can volunteer';
    end if;

    select * into trip
    from public.kcp_trips
    where id = req.trip_id
    for update;
    if not found then raise exception 'Trip not found'; end if;
    if trip.status <> 'cover_requested' then
        raise exception 'This trip is no longer waiting for a volunteer';
    end if;
    if trip.scheduled_driver_id = auth.uid() then
        raise exception 'The assigned driver cannot volunteer for their own cover request';
    end if;

    select display_name into volunteer_name
    from public.kcp_profiles
    where id = auth.uid();

    update public.kcp_cover_requests
       set status = 'accepted',
           accepted_by = auth.uid(),
           accepted_at = now()
     where id = req.id;

    update public.kcp_trips
       set actual_driver_id = auth.uid(),
           actual_driver_name = volunteer_name,
           volunteer_assignment = true,
           status = 'cover_accepted'
     where id = trip.id;

    perform public.kcp_write_audit(
        req.group_id,
        'cover_accepted',
        'trip',
        trip.id::text,
        jsonb_build_object(
            'volunteerUserId', auth.uid(),
            'volunteerName', volunteer_name,
            'requestedByUserId', req.requested_by,
            'pointsOnCompletion', 20
        )
    );

    return trip.id;
end;
$$;

commit;
