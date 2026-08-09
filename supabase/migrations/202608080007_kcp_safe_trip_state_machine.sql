begin;

-- ---------------------------------------------------------------------------
-- Safe trip state machine: time passage never proves child transport occurred.
-- ---------------------------------------------------------------------------

do $$
begin
    if exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_trips'::regclass
          and conname = 'kcp_trips_status_check'
    ) then
        alter table public.kcp_trips drop constraint kcp_trips_status_check;
    end if;
end;
$$;

alter table public.kcp_trips
    add constraint kcp_trips_status_check
    check (status in (
        'scheduled','coverage_needed','cover_requested','cover_accepted',
        'confirmation_due','ready','in_progress','completion_due',
        'completed','unconfirmed','cancelled'
    ));

alter table public.kcp_trips
    add column if not exists confirmed_at timestamptz,
    add column if not exists confirmed_by uuid references public.kcp_profiles(id) on delete set null,
    add column if not exists confirmation_due_at timestamptz,
    add column if not exists completion_due_at timestamptz,
    add column if not exists unconfirmed_at timestamptz,
    add column if not exists verification_note text;

update public.kcp_trips set started_source = 'legacy_automatic' where started_source = 'automatic';
update public.kcp_trips set completed_source = 'legacy_automatic' where completed_source = 'automatic';

alter table public.kcp_trips drop constraint if exists kcp_trips_started_source_check;
alter table public.kcp_trips drop constraint if exists kcp_trips_completed_source_check;
alter table public.kcp_trips
    add constraint kcp_trips_started_source_check
    check (started_source is null or started_source in ('manual','admin','legacy_automatic')),
    add constraint kcp_trips_completed_source_check
    check (completed_source is null or completed_source in ('manual','admin','legacy_automatic'));

create table if not exists public.kcp_trip_events (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    event_type text not null check (event_type in (
        'driver_confirmed','confirmation_due','trip_started','arrival_reported',
        'completion_due','completion_confirmed','admin_completion_confirmed',
        'marked_unconfirmed','child_picked_up','child_skipped','arrived_destination',
        'issue_reported','trip_cancelled'
    )),
    actor_id uuid references public.kcp_profiles(id) on delete set null,
    child_id uuid references public.kcp_children(id) on delete set null,
    client_event_id text unique,
    device_timestamp timestamptz,
    server_timestamp timestamptz not null default now(),
    metadata jsonb not null default '{}'::jsonb
);

create index if not exists kcp_trip_events_trip_idx
    on public.kcp_trip_events(trip_id, server_timestamp, id);

alter table public.kcp_trip_events enable row level security;
revoke all on table public.kcp_trip_events from public, anon, authenticated;

drop trigger if exists kcp_trip_events_no_mutation on public.kcp_trip_events;
create trigger kcp_trip_events_no_mutation
before update or delete on public.kcp_trip_events
for each row execute function public.kcp_forbid_audit_mutation();

create or replace function public.kcp_record_trip_event(
    p_trip_id uuid,
    p_event_type text,
    p_actor_id uuid default null,
    p_child_id uuid default null,
    p_client_event_id text default null,
    p_device_timestamp timestamptz default null,
    p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip_group uuid;
    result_id uuid;
begin
    select trip.group_id into trip_group from public.kcp_trips trip where trip.id = p_trip_id;
    if trip_group is null then raise exception 'Trip not found'; end if;

    insert into public.kcp_trip_events(
        group_id, trip_id, event_type, actor_id, child_id,
        client_event_id, device_timestamp, metadata
    ) values (
        trip_group, p_trip_id, p_event_type, p_actor_id, p_child_id,
        nullif(trim(p_client_event_id), ''), p_device_timestamp,
        coalesce(p_metadata, '{}'::jsonb)
    )
    on conflict (client_event_id) do update
       set client_event_id = excluded.client_event_id
    returning id into result_id;
    return result_id;
end;
$$;

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
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    if trip.status <> 'completed' or trip.completed_at is null then
        raise exception 'Points require a confirmed completed trip';
    end if;

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

create or replace function public.kcp_confirm_trip(p_trip_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    confirmed timestamptz := now();
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id <> auth.uid() then raise exception 'Only the assigned driver can confirm this ride'; end if;
    if trip.status not in ('scheduled','cover_accepted','confirmation_due','unconfirmed') then
        raise exception 'Ride cannot be confirmed from its current status';
    end if;
    if trip.started_at is not null then raise exception 'This ride has already started'; end if;
    if trip.scheduled_time is null then raise exception 'Confirm the ride time first'; end if;
    if confirmed < trip.scheduled_time - interval '24 hours' then
        raise exception 'Driver confirmation opens 24 hours before the ride';
    end if;
    if confirmed > trip.scheduled_time + interval '90 minutes' then
        raise exception 'The driver confirmation window has closed';
    end if;

    update public.kcp_trips
       set status = 'ready', confirmed_at = confirmed, confirmed_by = auth.uid(),
           confirmation_due_at = null, unconfirmed_at = null
     where id = trip.id;

    perform public.kcp_record_trip_event(
        trip.id, 'driver_confirmed', auth.uid(), null, null, null,
        jsonb_build_object('scheduledTime', trip.scheduled_time)
    );
    perform public.kcp_write_audit(
        trip.group_id, 'trip_driver_confirmed', 'trip', trip.id::text,
        jsonb_build_object('driverUserId', auth.uid(), 'scheduledTime', trip.scheduled_time)
    );
    return confirmed;
end;
$$;

create or replace function public.kcp_start_trip(p_trip_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    started timestamptz := now();
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id is null then raise exception 'No driver is assigned'; end if;
    if driver_id <> auth.uid() then raise exception 'Only the assigned driver can start this ride'; end if;
    if trip.status <> 'ready' then
        if trip.status in ('scheduled','cover_accepted','confirmation_due') then
            raise exception 'Confirm the ride before starting it';
        end if;
        raise exception 'Ride cannot be started from its current status';
    end if;
    if not public.kcp_can_start_trip_at(trip.scheduled_time, started) then
        if started < trip.scheduled_time - interval '10 minutes' then
            raise exception 'Start becomes available 10 minutes before the scheduled time';
        end if;
        raise exception 'The manual start window has closed';
    end if;

    update public.kcp_trips
       set status = 'in_progress', started_at = started, started_source = 'manual'
     where id = trip.id;
    perform public.kcp_record_trip_event(trip.id, 'trip_started', auth.uid());
    perform public.kcp_write_audit(
        trip.group_id, 'trip_started', 'trip', trip.id::text,
        jsonb_build_object('driverUserId', auth.uid(), 'source', 'manual')
    );
    return started;
end;
$$;

-- Driver reports arrival. This does not yet prove completion and awards no points.
create or replace function public.kcp_complete_trip(p_trip_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    arrived timestamptz := now();
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id <> auth.uid() then raise exception 'Only the active driver can report arrival'; end if;
    if trip.status <> 'in_progress' then raise exception 'Start the ride before reporting arrival'; end if;
    if trip.started_at is null or arrived < trip.started_at + interval '3 minutes' then
        raise exception 'Wait at least 3 minutes after starting before reporting arrival';
    end if;

    update public.kcp_trips
       set status = 'completion_due', completion_due_at = arrived
     where id = trip.id;
    perform public.kcp_record_trip_event(trip.id, 'arrival_reported', auth.uid());
    perform public.kcp_write_audit(
        trip.group_id, 'trip_arrival_reported', 'trip', trip.id::text,
        jsonb_build_object('driverUserId', auth.uid())
    );
    return 0;
end;
$$;

create or replace function public.kcp_confirm_trip_completion(p_trip_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    earned integer;
    completed timestamptz := now();
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id <> auth.uid() then raise exception 'Only the active driver can confirm completion'; end if;
    if trip.status not in ('completion_due','unconfirmed') or trip.started_at is null then
        raise exception 'Report arrival before confirming completion';
    end if;

    update public.kcp_trips
       set status = 'completed', completed_at = completed,
           completed_source = 'manual', unconfirmed_at = null,
           verification_note = 'Confirmed by active driver'
     where id = trip.id;
    earned := public.kcp_award_confirmed_trip_points(trip.id);
    perform public.kcp_record_trip_event(
        trip.id, 'completion_confirmed', auth.uid(), null, null, null,
        jsonb_build_object('points', earned)
    );
    perform public.kcp_write_audit(
        trip.group_id, 'trip_completion_confirmed', 'trip', trip.id::text,
        jsonb_build_object('driverUserId', auth.uid(), 'points', earned)
    );
    return earned;
end;
$$;

create or replace function public.kcp_admin_confirm_trip_completion(
    p_trip_id uuid,
    p_note text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    earned integer;
begin
    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    if not public.kcp_is_admin(trip.group_id) then raise exception 'Owner or admin role required'; end if;
    if length(trim(coalesce(p_note,''))) < 5 then raise exception 'Provide the reason for administrative confirmation'; end if;
    if trip.status not in ('in_progress','completion_due','unconfirmed') then
        raise exception 'Ride is not awaiting completion confirmation';
    end if;
    if coalesce(trip.actual_driver_id, trip.scheduled_driver_id) is null then raise exception 'No driver is assigned'; end if;

    update public.kcp_trips
       set status = 'completed', completed_at = now(), completed_source = 'admin',
           completion_due_at = coalesce(completion_due_at, now()),
           unconfirmed_at = null, verification_note = trim(p_note)
     where id = trip.id;
    earned := public.kcp_award_confirmed_trip_points(trip.id);
    perform public.kcp_record_trip_event(
        trip.id, 'admin_completion_confirmed', auth.uid(), null, null, null,
        jsonb_build_object('points', earned, 'note', trim(p_note))
    );
    perform public.kcp_write_audit(
        trip.group_id, 'trip_admin_completion_confirmed', 'trip', trip.id::text,
        jsonb_build_object('adminUserId', auth.uid(), 'points', earned, 'note', trim(p_note))
    );
    return earned;
end;
$$;

create or replace function public.kcp_process_trip_lifecycle(
    p_now timestamptz default now(),
    p_group_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip_record record;
    confirmation_due_count integer := 0;
    completion_due_count integer := 0;
    unconfirmed_count integer := 0;
begin
    -- Scheduled time reached without driver confirmation.
    for trip_record in
        select trip.* from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        where group_row.auto_lifecycle_enabled
          and (p_group_id is null or trip.group_id = p_group_id)
          and trip.status in ('scheduled','cover_accepted')
          and trip.scheduled_time is not null
          and trip.scheduled_time <= p_now
          and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) is not null
        for update of trip skip locked
    loop
        update public.kcp_trips
           set status = 'confirmation_due', confirmation_due_at = p_now
         where id = trip_record.id;
        perform public.kcp_record_trip_event(
            trip_record.id, 'confirmation_due', null, null, null, null,
            jsonb_build_object('scheduledTime', trip_record.scheduled_time)
        );
        confirmation_due_count := confirmation_due_count + 1;
    end loop;

    -- Confirmed but never started, or confirmation remained unanswered.
    for trip_record in
        select trip.* from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        where group_row.auto_lifecycle_enabled
          and (p_group_id is null or trip.group_id = p_group_id)
          and trip.status in ('ready','confirmation_due')
          and trip.scheduled_time is not null
          and trip.scheduled_time + interval '30 minutes' <= p_now
        for update of trip skip locked
    loop
        update public.kcp_trips
           set status = 'unconfirmed', unconfirmed_at = p_now
         where id = trip_record.id;
        perform public.kcp_record_trip_event(
            trip_record.id, 'marked_unconfirmed', null, null, null, null,
            jsonb_build_object('priorStatus', trip_record.status, 'reason', 'Ride was not started or confirmed')
        );
        unconfirmed_count := unconfirmed_count + 1;
    end loop;

    -- Time suggests an in-progress ride may have arrived; request confirmation.
    for trip_record in
        select trip.*, group_row.auto_complete_after_minutes
        from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        where group_row.auto_lifecycle_enabled
          and (p_group_id is null or trip.group_id = p_group_id)
          and trip.status = 'in_progress'
          and trip.scheduled_time is not null
          and p_now >= greatest(coalesce(trip.started_at, trip.scheduled_time), trip.scheduled_time)
              + make_interval(mins => group_row.auto_complete_after_minutes)
        for update of trip skip locked
    loop
        update public.kcp_trips
           set status = 'completion_due', completion_due_at = p_now
         where id = trip_record.id;
        perform public.kcp_record_trip_event(
            trip_record.id, 'completion_due', null, null, null, null,
            jsonb_build_object('reason', 'Expected duration elapsed; explicit completion required')
        );
        completion_due_count := completion_due_count + 1;
    end loop;

    -- No completion confirmation after a two-hour grace period.
    for trip_record in
        select trip.* from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        where group_row.auto_lifecycle_enabled
          and (p_group_id is null or trip.group_id = p_group_id)
          and trip.status = 'completion_due'
          and trip.completion_due_at + interval '2 hours' <= p_now
        for update of trip skip locked
    loop
        update public.kcp_trips
           set status = 'unconfirmed', unconfirmed_at = p_now
         where id = trip_record.id;
        perform public.kcp_record_trip_event(
            trip_record.id, 'marked_unconfirmed', null, null, null, null,
            jsonb_build_object('priorStatus', 'completion_due', 'reason', 'Completion was not explicitly confirmed')
        );
        unconfirmed_count := unconfirmed_count + 1;
    end loop;

    return jsonb_build_object(
        'confirmationDue', confirmation_due_count,
        'completionDue', completion_due_count,
        'unconfirmed', unconfirmed_count,
        'completed', 0,
        'pointsAwarded', 0,
        'processedAt', p_now,
        'groupId', p_group_id
    );
end;
$$;

create or replace function public.kcp_trip_event_timeline(p_trip_id uuid)
returns table(
    event_type text,
    actor_name text,
    server_timestamp timestamptz,
    metadata jsonb
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    trip_group uuid;
    member_role text;
begin
    select trip.group_id into trip_group from public.kcp_trips trip where trip.id = p_trip_id;
    if trip_group is null then raise exception 'Trip not found'; end if;
    select member.role into member_role
    from public.kcp_memberships member
    where member.group_id = trip_group and member.user_id = auth.uid() and member.status = 'active';
    if member_role is null then raise exception 'Active group membership required'; end if;

    return query
    select event.event_type, profile.display_name, event.server_timestamp,
           case when member_role in ('owner','admin') then event.metadata else '{}'::jsonb end
    from public.kcp_trip_events event
    left join public.kcp_profiles profile on profile.id = event.actor_id
    where event.trip_id = p_trip_id
    order by event.server_timestamp, event.id;
end;
$$;

revoke all on function public.kcp_record_trip_event(uuid,text,uuid,uuid,text,timestamptz,jsonb) from public, anon, authenticated;
revoke all on function public.kcp_award_confirmed_trip_points(uuid) from public, anon, authenticated;
revoke all on function public.kcp_confirm_trip(uuid) from public, anon;
revoke all on function public.kcp_start_trip(uuid) from public, anon;
revoke all on function public.kcp_complete_trip(uuid) from public, anon;
revoke all on function public.kcp_confirm_trip_completion(uuid) from public, anon;
revoke all on function public.kcp_admin_confirm_trip_completion(uuid,text) from public, anon;
revoke all on function public.kcp_process_trip_lifecycle(timestamptz,uuid) from public, anon, authenticated;
revoke all on function public.kcp_trip_event_timeline(uuid) from public, anon;

grant execute on function public.kcp_confirm_trip(uuid) to authenticated;
grant execute on function public.kcp_start_trip(uuid) to authenticated;
grant execute on function public.kcp_complete_trip(uuid) to authenticated;
grant execute on function public.kcp_confirm_trip_completion(uuid) to authenticated;
grant execute on function public.kcp_admin_confirm_trip_completion(uuid,text) to authenticated;
grant execute on function public.kcp_trip_event_timeline(uuid) to authenticated;

commit;
