begin;

-- ---------------------------------------------------------------------------
-- Trip lifecycle: 10-minute manual start gate + automatic progression
-- ---------------------------------------------------------------------------

alter table public.kcp_trips
    add column if not exists started_source text;

alter table public.kcp_trips
    add column if not exists completed_source text;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_trips'::regclass
          and conname = 'kcp_trips_started_source_check'
    ) then
        alter table public.kcp_trips
            add constraint kcp_trips_started_source_check
            check (started_source is null or started_source in ('manual','automatic'));
    end if;

    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.kcp_trips'::regclass
          and conname = 'kcp_trips_completed_source_check'
    ) then
        alter table public.kcp_trips
            add constraint kcp_trips_completed_source_check
            check (completed_source is null or completed_source in ('manual','automatic'));
    end if;
end;
$$;

create or replace function public.kcp_can_start_trip_at(
    p_scheduled_time timestamptz,
    p_now timestamptz default now()
)
returns boolean
language sql
stable
set search_path = public, pg_catalog
as $$
    select p_scheduled_time is not null
       and p_now >= p_scheduled_time - interval '10 minutes'
       and p_now <= p_scheduled_time + interval '90 minutes';
$$;

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
    select t.* into trip
    from public.kcp_trips t
    where t.id = p_trip_id
    for update;
    if not found then raise exception 'Trip not found'; end if;

    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id is null then raise exception 'No driver is assigned'; end if;
    if driver_id <> auth.uid() then
        raise exception 'Only the assigned driver can start this trip';
    end if;
    if trip.status not in ('scheduled','cover_accepted') then
        raise exception 'Trip cannot be started from its current status';
    end if;
    if trip.scheduled_time is null then
        raise exception 'Confirm the trip time before starting';
    end if;
    if not public.kcp_can_start_trip_at(trip.scheduled_time, started) then
        if started < trip.scheduled_time - interval '10 minutes' then
            raise exception 'Start becomes available 10 minutes before the scheduled time';
        end if;
        raise exception 'The manual start window has closed';
    end if;

    update public.kcp_trips
       set status = 'in_progress',
           started_at = started,
           started_source = 'manual'
     where id = trip.id;

    perform public.kcp_write_audit(
        trip.group_id,
        'trip_started',
        'trip',
        trip.id::text,
        jsonb_build_object(
            'driverUserId', auth.uid(),
            'source', 'manual',
            'scheduledTime', trip.scheduled_time
        )
    );

    return started;
end;
$$;

create or replace function public.kcp_complete_trip(p_trip_id uuid)
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
    completed timestamptz := now();
begin
    select t.* into trip
    from public.kcp_trips t
    where t.id = p_trip_id
    for update;
    if not found then raise exception 'Trip not found'; end if;

    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id is null then raise exception 'No driver is assigned'; end if;
    if driver_id <> auth.uid() then
        raise exception 'Only the active driver can complete this trip';
    end if;
    if trip.status <> 'in_progress' then
        raise exception 'Start the trip before completing it';
    end if;
    if trip.scheduled_time is null then
        raise exception 'Confirm the trip time before completing it';
    end if;
    if completed < trip.scheduled_time then
        raise exception 'Completion becomes available at the scheduled time';
    end if;
    if trip.started_at is null or completed < trip.started_at + interval '3 minutes' then
        raise exception 'Wait at least 3 minutes after starting before completing the trip';
    end if;
    if completed > trip.scheduled_time + interval '4 hours' then
        raise exception 'The manual completion window has expired';
    end if;

    earned := case
        when trip.volunteer_assignment
          or (trip.actual_driver_id is not null and trip.actual_driver_id <> trip.scheduled_driver_id)
        then 20 else 10 end;
    reason_value := case when earned = 20 then 'volunteer_trip' else 'scheduled_trip' end;

    update public.kcp_trips
       set status = 'completed',
           completed_at = completed,
           completed_source = 'manual'
     where id = trip.id;

    insert into public.kcp_points_ledger(
        group_id, trip_id, user_id, points, reason
    ) values (
        trip.group_id, trip.id, driver_id, earned, reason_value
    )
    on conflict (trip_id) do nothing;

    perform public.kcp_write_audit(
        trip.group_id,
        'trip_completed',
        'trip',
        trip.id::text,
        jsonb_build_object(
            'driverUserId', driver_id,
            'points', earned,
            'volunteer', earned = 20,
            'source', 'manual'
        )
    );

    return earned;
end;
$$;

-- Internal processor used by Supabase Cron and the member-scoped refresh RPC.
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
    driver_id uuid;
    earned integer;
    reason_value text;
    started_count integer := 0;
    completed_count integer := 0;
begin
    for trip_record in
        select
            t.*,
            g.auto_complete_after_minutes,
            g.auto_lifecycle_enabled
        from public.kcp_trips t
        join public.kcp_groups g on g.id = t.group_id
        where g.auto_lifecycle_enabled
          and (p_group_id is null or t.group_id = p_group_id)
          and t.status in ('scheduled','cover_accepted')
          and t.scheduled_time is not null
          and t.scheduled_time <= p_now
          and coalesce(t.actual_driver_id, t.scheduled_driver_id) is not null
        for update of t skip locked
    loop
        driver_id := coalesce(trip_record.actual_driver_id, trip_record.scheduled_driver_id);

        update public.kcp_trips
           set status = 'in_progress',
               started_at = coalesce(started_at, trip_record.scheduled_time),
               started_source = coalesce(started_source, 'automatic')
         where id = trip_record.id;

        insert into public.kcp_audit_events(
            group_id, actor_id, action, entity_type, entity_id, details
        ) values (
            trip_record.group_id,
            null,
            'trip_auto_started',
            'trip',
            trip_record.id::text,
            jsonb_build_object(
                'driverUserId', driver_id,
                'scheduledTime', trip_record.scheduled_time,
                'processedAt', p_now
            )
        );

        started_count := started_count + 1;
    end loop;

    for trip_record in
        select
            t.*,
            g.auto_complete_after_minutes
        from public.kcp_trips t
        join public.kcp_groups g on g.id = t.group_id
        where g.auto_lifecycle_enabled
          and (p_group_id is null or t.group_id = p_group_id)
          and t.status = 'in_progress'
          and t.scheduled_time is not null
          and coalesce(t.actual_driver_id, t.scheduled_driver_id) is not null
          and p_now >= greatest(
              coalesce(t.started_at, t.scheduled_time),
              t.scheduled_time
          ) + make_interval(mins => g.auto_complete_after_minutes)
        for update of t skip locked
    loop
        driver_id := coalesce(trip_record.actual_driver_id, trip_record.scheduled_driver_id);
        earned := case
            when trip_record.volunteer_assignment
              or (
                  trip_record.actual_driver_id is not null
                  and trip_record.actual_driver_id <> trip_record.scheduled_driver_id
              )
            then 20 else 10 end;
        reason_value := case when earned = 20 then 'volunteer_trip' else 'scheduled_trip' end;

        update public.kcp_trips
           set status = 'completed',
               completed_at = p_now,
               completed_source = 'automatic'
         where id = trip_record.id;

        insert into public.kcp_points_ledger(
            group_id, trip_id, user_id, points, reason
        ) values (
            trip_record.group_id,
            trip_record.id,
            driver_id,
            earned,
            reason_value
        )
        on conflict (trip_id) do nothing;

        insert into public.kcp_audit_events(
            group_id, actor_id, action, entity_type, entity_id, details
        ) values (
            trip_record.group_id,
            null,
            'trip_auto_completed',
            'trip',
            trip_record.id::text,
            jsonb_build_object(
                'driverUserId', driver_id,
                'points', earned,
                'volunteer', earned = 20,
                'autoCompleteAfterMinutes', trip_record.auto_complete_after_minutes,
                'processedAt', p_now
            )
        );

        completed_count := completed_count + 1;
    end loop;

    return jsonb_build_object(
        'started', started_count,
        'completed', completed_count,
        'processedAt', p_now,
        'groupId', p_group_id
    );
end;
$$;

create or replace function public.kcp_sync_group_lifecycle(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;
    return public.kcp_process_trip_lifecycle(now(), p_group_id);
end;
$$;

revoke all on function public.kcp_process_trip_lifecycle(timestamptz,uuid)
from public, anon, authenticated;

revoke all on function public.kcp_sync_group_lifecycle(uuid)
from public, anon;

grant execute on function public.kcp_sync_group_lifecycle(uuid)
to authenticated;

-- Realtime keeps the requester informed when another parent accepts coverage.
do $$
declare
    target_table text;
begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        foreach target_table in array array[
            'kcp_trips',
            'kcp_cover_requests',
            'kcp_points_ledger',
            'kcp_constraint_requests',
            'kcp_memberships',
            'kcp_invitations'
        ] loop
            if not exists (
                select 1
                from pg_publication_tables
                where pubname = 'supabase_realtime'
                  and schemaname = 'public'
                  and tablename = target_table
            ) then
                execute format(
                    'alter publication supabase_realtime add table public.%I',
                    target_table
                );
            end if;
        end loop;
    end if;
end;
$$;

-- Supabase Cron runs the lifecycle processor every minute even when no parent
-- has the app open. A named schedule overwrites a previous job with the same
-- name, so reapplying the migration cannot create duplicates.
create extension if not exists pg_cron;

select cron.schedule(
    'kcp-auto-trip-lifecycle',
    '* * * * *',
    $job$select public.kcp_process_trip_lifecycle(now(), null);$job$
);

-- Migration-time boundary checks for the 10-minute rule.
do $$
declare
    scheduled timestamptz := timestamptz '2026-08-10 07:00:00-07';
begin
    if public.kcp_can_start_trip_at(scheduled, scheduled - interval '10 minutes 1 second') then
        raise exception 'Start gate opened earlier than 10 minutes';
    end if;
    if not public.kcp_can_start_trip_at(scheduled, scheduled - interval '10 minutes') then
        raise exception 'Start gate did not open exactly 10 minutes before';
    end if;
    if not public.kcp_can_start_trip_at(scheduled, scheduled + interval '90 minutes') then
        raise exception 'Start gate closed before the allowed late boundary';
    end if;
    if public.kcp_can_start_trip_at(scheduled, scheduled + interval '90 minutes 1 second') then
        raise exception 'Start gate remained open after the late boundary';
    end if;
end;
$$;

commit;
