begin;

-- ---------------------------------------------------------------------------
-- Personal agenda and request feed across every active group membership
-- ---------------------------------------------------------------------------

create or replace function public.kcp_my_agenda(
    p_from timestamptz default now() - interval '1 day',
    p_to timestamptz default now() + interval '60 days',
    p_limit integer default 250
)
returns table(
    group_id uuid,
    group_code text,
    group_name text,
    group_kind text,
    group_role text,
    trip_id uuid,
    trip_date date,
    scheduled_time timestamptz,
    time_label text,
    leg_type text,
    display_label text,
    status text,
    scheduled_driver_id uuid,
    scheduled_driver_name text,
    actual_driver_id uuid,
    actual_driver_name text,
    child_names text[],
    volunteer_assignment boolean,
    notes text
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if p_to <= p_from then raise exception 'Agenda end must be after start'; end if;

    return query
    select
        group_row.id,
        group_row.code,
        group_row.name,
        group_row.group_kind,
        membership.role,
        trip.id,
        trip.trip_date,
        trip.scheduled_time,
        trip.time_label,
        coalesce(trip.leg_type,
            case when trip.kind = 'afternoon_pickup' then 'return' else 'outbound' end),
        coalesce(trip.display_label,
            case when trip.kind = 'afternoon_pickup' then 'Return' else 'Outbound' end),
        trip.status,
        trip.scheduled_driver_id,
        trip.scheduled_driver_name,
        trip.actual_driver_id,
        trip.actual_driver_name,
        trip.child_names,
        trip.volunteer_assignment,
        trip.notes
    from public.kcp_memberships membership
    join public.kcp_groups group_row
      on group_row.id = membership.group_id
     and group_row.status = 'active'
    join public.kcp_trips trip
      on trip.group_id = group_row.id
     and trip.schedule_version = group_row.current_schedule_version
    where membership.user_id = auth.uid()
      and membership.status = 'active'
      and (
          trip.scheduled_time between p_from and p_to
          or (
              trip.scheduled_time is null
              and trip.trip_date between p_from::date and p_to::date
          )
          or trip.status = 'in_progress'
      )
    order by
        case when trip.status = 'in_progress' then 0 else 1 end,
        coalesce(trip.scheduled_time, trip.trip_date::timestamptz),
        trip.id
    limit least(greatest(p_limit, 1), 1000);
end;
$$;

create or replace function public.kcp_my_requests(p_limit integer default 200)
returns table(
    request_type text,
    request_id uuid,
    group_id uuid,
    group_name text,
    trip_id uuid,
    trip_date date,
    scheduled_time timestamptz,
    display_label text,
    status text,
    requested_by uuid,
    requested_by_name text,
    accepted_by uuid,
    accepted_by_name text,
    note text,
    created_at timestamptz,
    requires_my_action boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    return query
    with memberships as (
        select member.group_id, member.role
        from public.kcp_memberships member
        where member.user_id = auth.uid()
          and member.status = 'active'
    ), cover_rows as (
        select
            'cover'::text as request_type,
            cover.id as request_id,
            cover.group_id,
            group_row.name as group_name,
            cover.trip_id,
            trip.trip_date,
            trip.scheduled_time,
            coalesce(trip.display_label,
                case when trip.kind = 'afternoon_pickup' then 'Return' else 'Outbound' end) as display_label,
            cover.status,
            cover.requested_by,
            requester.parent_name as requested_by_name,
            cover.accepted_by,
            acceptor.parent_name as accepted_by_name,
            cover.note,
            cover.created_at,
            (
                cover.status = 'open'
                and cover.requested_by <> auth.uid()
                and coalesce(trip.scheduled_driver_id, trip.actual_driver_id) is distinct from auth.uid()
                and exists (
                    select 1 from public.kcp_group_participants participant
                    where participant.group_id = cover.group_id
                      and participant.user_id = auth.uid()
                      and participant.status = 'active'
                      and participant.can_drive
                )
            ) as requires_my_action
        from memberships membership
        join public.kcp_cover_requests cover on cover.group_id = membership.group_id
        join public.kcp_groups group_row on group_row.id = cover.group_id
        join public.kcp_trips trip on trip.id = cover.trip_id
        left join public.kcp_memberships requester
          on requester.group_id = cover.group_id and requester.user_id = cover.requested_by
        left join public.kcp_memberships acceptor
          on acceptor.group_id = cover.group_id and acceptor.user_id = cover.accepted_by
        where cover.status in ('open','accepted')
          and (
              cover.status = 'open'
              or cover.requested_by = auth.uid()
              or cover.accepted_by = auth.uid()
          )
    ), constraint_rows as (
        select
            'availability'::text,
            request.id,
            request.group_id,
            group_row.name,
            null::uuid,
            null::date,
            null::timestamptz,
            'Availability change'::text,
            request.status,
            request.user_id,
            requester.parent_name,
            request.reviewed_by,
            reviewer.parent_name,
            request.notes,
            request.submitted_at,
            (membership.role in ('owner','admin') and request.user_id <> auth.uid())
        from memberships membership
        join public.kcp_constraint_requests request on request.group_id = membership.group_id
        join public.kcp_groups group_row on group_row.id = request.group_id
        left join public.kcp_memberships requester
          on requester.group_id = request.group_id and requester.user_id = request.user_id
        left join public.kcp_memberships reviewer
          on reviewer.group_id = request.group_id and reviewer.user_id = request.reviewed_by
        where request.status = 'pending'
          and (request.user_id = auth.uid() or membership.role in ('owner','admin'))
    )
    select * from cover_rows
    union all
    select * from constraint_rows
    order by requires_my_action desc, created_at desc
    limit least(greatest(p_limit, 1), 1000);
end;
$$;

revoke all on function public.kcp_my_agenda(timestamptz,timestamptz,integer) from public, anon;
revoke all on function public.kcp_my_requests(integer) from public, anon;
grant execute on function public.kcp_my_agenda(timestamptz,timestamptz,integer) to authenticated;
grant execute on function public.kcp_my_requests(integer) to authenticated;

commit;
