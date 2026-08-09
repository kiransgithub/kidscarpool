begin;

-- ---------------------------------------------------------------------------
-- Cover escalation and coordinated swaps
-- ---------------------------------------------------------------------------

alter table public.kcp_cover_requests
    add column if not exists respond_by timestamptz,
    add column if not exists escalation_stage text not null default 'open'
        check (escalation_stage in ('open','eligible_drivers','group_admin','unresolved','resolved')),
    add column if not exists escalated_at timestamptz,
    add column if not exists last_escalated_at timestamptz;

create or replace function public.kcp_set_cover_deadlines()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
declare
    scheduled timestamptz;
begin
    select trip.scheduled_time into scheduled from public.kcp_trips trip where trip.id = new.trip_id;
    if new.respond_by is null and scheduled is not null then
        new.respond_by := scheduled - interval '30 minutes';
    end if;
    new.escalation_stage := coalesce(new.escalation_stage, 'open');
    return new;
end;
$$;

drop trigger if exists kcp_cover_request_deadlines on public.kcp_cover_requests;
create trigger kcp_cover_request_deadlines
before insert on public.kcp_cover_requests
for each row execute function public.kcp_set_cover_deadlines();

create table if not exists public.kcp_trip_swap_requests (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    offered_trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    requested_trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    requested_by uuid not null references public.kcp_profiles(id) on delete restrict,
    requested_from uuid not null references public.kcp_profiles(id) on delete restrict,
    note text,
    status text not null default 'pending'
        check (status in ('pending','accepted','rejected','cancelled','expired')),
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    responded_at timestamptz,
    responded_by uuid references public.kcp_profiles(id) on delete set null,
    response_note text,
    unique (offered_trip_id, requested_trip_id, status)
);

create unique index if not exists kcp_pending_swap_offered_trip
    on public.kcp_trip_swap_requests(offered_trip_id)
    where status = 'pending';
create unique index if not exists kcp_pending_swap_requested_trip
    on public.kcp_trip_swap_requests(requested_trip_id)
    where status = 'pending';
create index if not exists kcp_trip_swap_group_created_idx
    on public.kcp_trip_swap_requests(group_id, created_at desc);

alter table public.kcp_trip_swap_requests enable row level security;
revoke all on table public.kcp_trip_swap_requests from public, anon, authenticated;

create or replace function public.kcp_process_cover_escalations(
    p_now timestamptz default now(),
    p_group_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    request record;
    new_stage text;
    eligible_count integer := 0;
    admin_count integer := 0;
    unresolved_count integer := 0;
begin
    for request in
        select cover.*, trip.scheduled_time
        from public.kcp_cover_requests cover
        join public.kcp_trips trip on trip.id = cover.trip_id
        where cover.status = 'open'
          and (p_group_id is null or cover.group_id = p_group_id)
          and trip.started_at is null
          and trip.status = 'cover_requested'
          and trip.scheduled_time is not null
        for update of cover skip locked
    loop
        new_stage := case
            when request.scheduled_time <= p_now + interval '15 minutes' then 'unresolved'
            when request.scheduled_time <= p_now + interval '30 minutes' then 'group_admin'
            when request.scheduled_time <= p_now + interval '60 minutes' then 'eligible_drivers'
            else 'open'
        end;

        if new_stage <> request.escalation_stage then
            update public.kcp_cover_requests
               set escalation_stage = new_stage,
                   escalated_at = coalesce(escalated_at, p_now),
                   last_escalated_at = p_now
             where id = request.id;

            perform public.kcp_write_audit(
                request.group_id, 'cover_escalated', 'cover_request', request.id::text,
                jsonb_build_object(
                    'tripId', request.trip_id,
                    'fromStage', request.escalation_stage,
                    'toStage', new_stage,
                    'scheduledTime', request.scheduled_time
                )
            );

            if new_stage = 'eligible_drivers' then eligible_count := eligible_count + 1; end if;
            if new_stage = 'group_admin' then admin_count := admin_count + 1; end if;
            if new_stage = 'unresolved' then unresolved_count := unresolved_count + 1; end if;
        end if;
    end loop;

    update public.kcp_cover_requests cover
       set escalation_stage = 'resolved'
     where cover.status in ('accepted','cancelled','expired')
       and cover.escalation_stage <> 'resolved'
       and (p_group_id is null or cover.group_id = p_group_id);

    update public.kcp_trip_swap_requests swap
       set status = 'expired', responded_at = p_now
     where swap.status = 'pending'
       and swap.expires_at <= p_now
       and (p_group_id is null or swap.group_id = p_group_id);

    return jsonb_build_object(
        'eligibleDrivers', eligible_count,
        'groupAdmin', admin_count,
        'unresolved', unresolved_count,
        'processedAt', p_now
    );
end;
$$;

create or replace function public.kcp_create_trip_swap(
    p_offered_trip_id uuid,
    p_requested_trip_id uuid,
    p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    offered public.kcp_trips;
    requested public.kcp_trips;
    swap_id uuid;
    offered_driver uuid;
    requested_driver uuid;
begin
    if p_offered_trip_id = p_requested_trip_id then raise exception 'Choose two different rides'; end if;
    select * into offered from public.kcp_trips where id = p_offered_trip_id for update;
    select * into requested from public.kcp_trips where id = p_requested_trip_id for update;
    if offered.id is null or requested.id is null then raise exception 'One of the rides was not found'; end if;
    if offered.group_id <> requested.group_id then raise exception 'Rides must belong to the same group'; end if;
    if not public.kcp_is_member(offered.group_id) then raise exception 'Active group membership required'; end if;
    if offered.started_at is not null or requested.started_at is not null then raise exception 'Started rides cannot be swapped'; end if;
    if offered.status not in ('scheduled','ready','confirmation_due','unconfirmed')
       or requested.status not in ('scheduled','ready','confirmation_due','unconfirmed') then
        raise exception 'Both rides must be awaiting normal driver action';
    end if;
    if offered.scheduled_time is null or requested.scheduled_time is null
       or offered.scheduled_time <= now() or requested.scheduled_time <= now() then
        raise exception 'Only future timed rides can be swapped';
    end if;

    offered_driver := coalesce(offered.actual_driver_id, offered.scheduled_driver_id);
    requested_driver := coalesce(requested.actual_driver_id, requested.scheduled_driver_id);
    if offered_driver <> auth.uid() then raise exception 'You must be the assigned driver of the ride you are offering'; end if;
    if requested_driver is null or requested_driver = auth.uid() then raise exception 'Choose a ride assigned to another driver'; end if;

    insert into public.kcp_trip_swap_requests(
        group_id, offered_trip_id, requested_trip_id, requested_by,
        requested_from, note, expires_at
    ) values (
        offered.group_id, offered.id, requested.id, auth.uid(),
        requested_driver, nullif(trim(p_note), ''),
        least(offered.scheduled_time, requested.scheduled_time) - interval '2 hours'
    ) returning id into swap_id;

    perform public.kcp_write_audit(
        offered.group_id, 'trip_swap_requested', 'trip_swap', swap_id::text,
        jsonb_build_object(
            'offeredTripId', offered.id,
            'requestedTripId', requested.id,
            'requestedFrom', requested_driver,
            'note', nullif(trim(p_note), '')
        )
    );
    return swap_id;
end;
$$;

create or replace function public.kcp_respond_trip_swap(
    p_swap_id uuid,
    p_accept boolean,
    p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    swap public.kcp_trip_swap_requests;
    offered public.kcp_trips;
    requested public.kcp_trips;
    offered_user uuid;
    offered_name text;
    offered_participant uuid;
    requested_user uuid;
    requested_name text;
    requested_participant uuid;
begin
    select * into swap from public.kcp_trip_swap_requests where id = p_swap_id for update;
    if not found then raise exception 'Swap request not found'; end if;
    if swap.status <> 'pending' then raise exception 'This swap request is no longer pending'; end if;
    if swap.expires_at <= now() then
        update public.kcp_trip_swap_requests set status = 'expired', responded_at = now() where id = swap.id;
        raise exception 'This swap request has expired';
    end if;
    if swap.requested_from <> auth.uid() and not public.kcp_is_admin(swap.group_id) then
        raise exception 'Only the requested driver or a group administrator can respond';
    end if;

    select * into offered from public.kcp_trips where id = swap.offered_trip_id for update;
    select * into requested from public.kcp_trips where id = swap.requested_trip_id for update;
    if offered.started_at is not null or requested.started_at is not null then raise exception 'One of the rides has already started'; end if;

    if not p_accept then
        update public.kcp_trip_swap_requests
           set status = 'rejected', responded_at = now(), responded_by = auth.uid(), response_note = nullif(trim(p_note), '')
         where id = swap.id;
        perform public.kcp_write_audit(
            swap.group_id, 'trip_swap_rejected', 'trip_swap', swap.id::text,
            jsonb_build_object('respondedBy', auth.uid(), 'note', nullif(trim(p_note), ''))
        );
        return;
    end if;

    offered_user := offered.scheduled_driver_id;
    offered_name := offered.scheduled_driver_name;
    offered_participant := offered.scheduled_participant_id;
    requested_user := requested.scheduled_driver_id;
    requested_name := requested.scheduled_driver_name;
    requested_participant := requested.scheduled_participant_id;
    if offered_user is null or requested_user is null then raise exception 'Both rides must have assigned drivers'; end if;

    update public.kcp_trips
       set scheduled_driver_id = requested_user,
           scheduled_driver_name = requested_name,
           scheduled_participant_id = requested_participant,
           actual_driver_id = null, actual_driver_name = null, actual_participant_id = null,
           volunteer_assignment = false, status = 'scheduled',
           confirmed_at = null, confirmed_by = null, confirmation_due_at = null,
           unconfirmed_at = null, verification_note = null, updated_at = now()
     where id = offered.id;

    update public.kcp_trips
       set scheduled_driver_id = offered_user,
           scheduled_driver_name = offered_name,
           scheduled_participant_id = offered_participant,
           actual_driver_id = null, actual_driver_name = null, actual_participant_id = null,
           volunteer_assignment = false, status = 'scheduled',
           confirmed_at = null, confirmed_by = null, confirmation_due_at = null,
           unconfirmed_at = null, verification_note = null, updated_at = now()
     where id = requested.id;

    update public.kcp_trip_swap_requests
       set status = 'accepted', responded_at = now(), responded_by = auth.uid(), response_note = nullif(trim(p_note), '')
     where id = swap.id;

    perform public.kcp_write_audit(
        swap.group_id, 'trip_swap_accepted', 'trip_swap', swap.id::text,
        jsonb_build_object(
            'respondedBy', auth.uid(),
            'offeredTripId', offered.id,
            'requestedTripId', requested.id,
            'newOfferedDriver', requested_user,
            'newRequestedDriver', offered_user,
            'confirmationReset', true
        )
    );
end;
$$;

create or replace function public.kcp_cancel_trip_swap(p_swap_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    swap public.kcp_trip_swap_requests;
begin
    select * into swap from public.kcp_trip_swap_requests where id = p_swap_id for update;
    if not found then raise exception 'Swap request not found'; end if;
    if swap.status <> 'pending' then raise exception 'Only a pending swap can be cancelled'; end if;
    if swap.requested_by <> auth.uid() and not public.kcp_is_admin(swap.group_id) then
        raise exception 'Only the requester or a group administrator can cancel this swap';
    end if;
    update public.kcp_trip_swap_requests
       set status = 'cancelled', responded_at = now(), responded_by = auth.uid()
     where id = swap.id;
    perform public.kcp_write_audit(
        swap.group_id, 'trip_swap_cancelled', 'trip_swap', swap.id::text,
        jsonb_build_object('cancelledBy', auth.uid())
    );
end;
$$;

create or replace function public.kcp_my_cover_and_swap_operations(p_limit integer default 300)
returns table(
    operation_type text,
    operation_id uuid,
    group_id uuid,
    group_name text,
    primary_trip_id uuid,
    secondary_trip_id uuid,
    primary_label text,
    secondary_label text,
    primary_time timestamptz,
    secondary_time timestamptz,
    status text,
    escalation_stage text,
    respond_by timestamptz,
    requested_by uuid,
    requested_by_name text,
    requested_from uuid,
    requested_from_name text,
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
    with membership as (
        select member.group_id, member.role
        from public.kcp_memberships member
        where member.user_id = auth.uid() and member.status = 'active'
    ), covers as (
        select
            'cover'::text, cover.id, cover.group_id, group_row.name,
            cover.trip_id, null::uuid,
            coalesce(trip.display_label, 'Ride'), null::text,
            trip.scheduled_time, null::timestamptz,
            cover.status, cover.escalation_stage, cover.respond_by,
            cover.requested_by, requester.parent_name,
            null::uuid, null::text,
            cover.accepted_by, acceptor.parent_name,
            cover.note, cover.created_at,
            cover.status = 'open'
              and cover.requested_by <> auth.uid()
              and exists (
                  select 1 from public.kcp_group_participants participant
                  where participant.group_id = cover.group_id
                    and participant.user_id = auth.uid()
                    and participant.status = 'active'
                    and participant.can_drive
              )
        from membership member
        join public.kcp_cover_requests cover on cover.group_id = member.group_id
        join public.kcp_groups group_row on group_row.id = cover.group_id
        join public.kcp_trips trip on trip.id = cover.trip_id
        left join public.kcp_memberships requester on requester.group_id = cover.group_id and requester.user_id = cover.requested_by
        left join public.kcp_memberships acceptor on acceptor.group_id = cover.group_id and acceptor.user_id = cover.accepted_by
        where cover.status in ('open','accepted')
    ), swaps as (
        select
            'swap'::text, swap.id, swap.group_id, group_row.name,
            swap.offered_trip_id, swap.requested_trip_id,
            coalesce(offered.display_label, 'Ride'), coalesce(requested.display_label, 'Ride'),
            offered.scheduled_time, requested.scheduled_time,
            swap.status, 'open'::text, swap.expires_at,
            swap.requested_by, requester.parent_name,
            swap.requested_from, target.parent_name,
            null::uuid, null::text,
            swap.note, swap.created_at,
            swap.status = 'pending' and swap.requested_from = auth.uid()
        from membership member
        join public.kcp_trip_swap_requests swap on swap.group_id = member.group_id
        join public.kcp_groups group_row on group_row.id = swap.group_id
        join public.kcp_trips offered on offered.id = swap.offered_trip_id
        join public.kcp_trips requested on requested.id = swap.requested_trip_id
        left join public.kcp_memberships requester on requester.group_id = swap.group_id and requester.user_id = swap.requested_by
        left join public.kcp_memberships target on target.group_id = swap.group_id and target.user_id = swap.requested_from
        where swap.status = 'pending'
          and (swap.requested_by = auth.uid() or swap.requested_from = auth.uid() or member.role in ('owner','admin'))
    )
    select operations.*
    from (
        select * from covers
        union all
        select * from swaps
    ) operations
    order by 23 desc, 22 desc
    limit least(greatest(p_limit, 1), 1000);
end;
$$;

-- Add a separate cron job so escalation remains independent of ride-state checks.
do $$
begin
    if exists (select 1 from cron.job where jobname = 'kcp-cover-escalations') then
        perform cron.unschedule('kcp-cover-escalations');
    end if;
    perform cron.schedule(
        'kcp-cover-escalations',
        '*/5 * * * *',
        'select public.kcp_process_cover_escalations(now(), null);'
    );
end;
$$;

revoke all on function public.kcp_process_cover_escalations(timestamptz,uuid) from public, anon, authenticated;
revoke all on function public.kcp_create_trip_swap(uuid,uuid,text) from public, anon;
revoke all on function public.kcp_respond_trip_swap(uuid,boolean,text) from public, anon;
revoke all on function public.kcp_cancel_trip_swap(uuid) from public, anon;
revoke all on function public.kcp_my_cover_and_swap_operations(integer) from public, anon;
grant execute on function public.kcp_create_trip_swap(uuid,uuid,text) to authenticated;
grant execute on function public.kcp_respond_trip_swap(uuid,boolean,text) to authenticated;
grant execute on function public.kcp_cancel_trip_swap(uuid) to authenticated;
grant execute on function public.kcp_my_cover_and_swap_operations(integer) to authenticated;

commit;
