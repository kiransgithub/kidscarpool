begin;

-- ---------------------------------------------------------------------------
-- RPC: trip lifecycle, volunteering and points
-- ---------------------------------------------------------------------------

create or replace function public.kcp_request_cover(
    p_trip_id uuid,
    p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
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
    if trip.status not in ('scheduled','coverage_needed') then raise exception 'Cover cannot be requested from the current trip status'; end if;

    insert into public.kcp_cover_requests(group_id, trip_id, requested_by, note)
    values (trip.group_id, trip.id, auth.uid(), coalesce(p_note,''))
    returning id into request_id;

    update public.kcp_trips set status = 'cover_requested' where id = trip.id;
    perform public.kcp_write_audit(
        trip.group_id, 'cover_requested', 'trip', trip.id::text,
        jsonb_build_object('note', coalesce(p_note,''))
    );
    return request_id;
end;
$$;

create or replace function public.kcp_accept_cover(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    req public.kcp_cover_requests;
    trip public.kcp_trips;
begin
    select * into req from public.kcp_cover_requests where id = p_request_id for update;
    if not found then raise exception 'Cover request not found'; end if;
    if req.status <> 'open' then raise exception 'This cover request is no longer open'; end if;
    if not public.kcp_is_member(req.group_id) then raise exception 'Active group membership required'; end if;
    if not exists (
        select 1 from public.kcp_memberships m
        where m.group_id = req.group_id and m.user_id = auth.uid()
          and m.status = 'active' and m.role <> 'viewer'
    ) then raise exception 'Only an active driving parent can volunteer'; end if;

    select * into trip from public.kcp_trips where id = req.trip_id for update;
    if trip.scheduled_driver_id = auth.uid() then raise exception 'The assigned driver cannot volunteer for their own cover request'; end if;

    update public.kcp_cover_requests
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = req.id;
    update public.kcp_trips
       set actual_driver_id = auth.uid(), volunteer_assignment = true, status = 'cover_accepted'
     where id = trip.id;

    perform public.kcp_write_audit(
        req.group_id, 'cover_accepted', 'trip', trip.id::text,
        jsonb_build_object('volunteerUserId', auth.uid(), 'pointsOnCompletion', 20)
    );
    return trip.id;
end;
$$;

create or replace function public.kcp_start_trip(p_trip_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    override_enabled boolean;
    started timestamptz := now();
begin
    select t.* into trip
    from public.kcp_trips t
    where t.id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    select g.pilot_time_override into override_enabled
    from public.kcp_groups g where g.id = trip.group_id;

    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id is null then raise exception 'No driver is assigned'; end if;
    if driver_id <> auth.uid() then raise exception 'Only the assigned driver can start this trip'; end if;
    if trip.status not in ('scheduled','cover_accepted') then raise exception 'Trip cannot be started from its current status'; end if;

    if not override_enabled then
        if trip.scheduled_time is null then raise exception 'The trip time has not been confirmed'; end if;
        if started < trip.scheduled_time - interval '30 minutes' then
            raise exception 'Start becomes available 30 minutes before the scheduled time';
        end if;
        if started > trip.scheduled_time + interval '90 minutes' then
            raise exception 'The trip is outside its start window';
        end if;
    end if;

    update public.kcp_trips set status = 'in_progress', started_at = started where id = trip.id;
    perform public.kcp_write_audit(
        trip.group_id, 'trip_started', 'trip', trip.id::text,
        jsonb_build_object('driverUserId', auth.uid())
    );
    return started;
end;
$$;

create or replace function public.kcp_complete_trip(p_trip_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
    override_enabled boolean;
    earned integer;
    reason_value text;
    completed timestamptz := now();
begin
    select t.* into trip
    from public.kcp_trips t
    where t.id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    select g.pilot_time_override into override_enabled
    from public.kcp_groups g where g.id = trip.group_id;

    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id is null then raise exception 'No driver is assigned'; end if;
    if driver_id <> auth.uid() then raise exception 'Only the active driver can complete this trip'; end if;
    if trip.status <> 'in_progress' then raise exception 'Start the trip before completing it'; end if;

    if not override_enabled then
        if trip.scheduled_time is null then raise exception 'The trip time has not been confirmed'; end if;
        if completed < trip.scheduled_time then raise exception 'Completion becomes available at the scheduled time'; end if;
        if trip.started_at is null or completed < trip.started_at + interval '3 minutes' then
            raise exception 'Wait at least 3 minutes after starting before completing the trip';
        end if;
        if completed > trip.scheduled_time + interval '4 hours' then
            raise exception 'The completion window has expired';
        end if;
    end if;

    earned := case
        when trip.volunteer_assignment
          or (trip.actual_driver_id is not null and trip.actual_driver_id <> trip.scheduled_driver_id)
        then 20 else 10 end;
    reason_value := case when earned = 20 then 'volunteer_trip' else 'scheduled_trip' end;

    update public.kcp_trips set status = 'completed', completed_at = completed where id = trip.id;
    insert into public.kcp_points_ledger(group_id, trip_id, user_id, points, reason)
    values (trip.group_id, trip.id, driver_id, earned, reason_value)
    on conflict (trip_id) do nothing;

    perform public.kcp_write_audit(
        trip.group_id, 'trip_completed', 'trip', trip.id::text,
        jsonb_build_object('driverUserId', driver_id, 'points', earned, 'volunteer', earned = 20)
    );
    return earned;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: native migration bridge and health
-- ---------------------------------------------------------------------------

create or replace function public.kcp_save_snapshot(p_group_id uuid, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.kcp_is_member(p_group_id) then raise exception 'Active group membership required'; end if;
    insert into public.kcp_group_snapshots(group_id, snapshot, updated_by)
    values (p_group_id, p_snapshot, auth.uid())
    on conflict (group_id) do update
       set snapshot = excluded.snapshot, updated_by = auth.uid(), updated_at = now();
end;
$$;

create or replace function public.kcp_get_snapshot(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    result jsonb;
begin
    if not public.kcp_is_member(p_group_id) then raise exception 'Active group membership required'; end if;
    select snapshot into result from public.kcp_group_snapshots where group_id = p_group_id;
    return result;
end;
$$;

create or replace function public.kcp_health()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'status','ok',
        'service','kcp-supabase-pilot',
        'version','1.0.0',
        'authenticated', auth.uid() is not null,
        'serverTime', now()
    );
$$;

-- ---------------------------------------------------------------------------
-- Storage bucket for authoritative calendar PDFs
-- ---------------------------------------------------------------------------

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
    'kcp-school-calendars',
    'kcp-school-calendars',
    false,
    10485760,
    array['application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists kcp_calendar_storage_select on storage.objects;
create policy kcp_calendar_storage_select
on storage.objects for select to authenticated
using (
    bucket_id = 'kcp-school-calendars'
    and public.kcp_is_member(public.kcp_storage_group_id(name))
);

drop policy if exists kcp_calendar_storage_insert on storage.objects;
create policy kcp_calendar_storage_insert
on storage.objects for insert to authenticated
with check (
    bucket_id = 'kcp-school-calendars'
    and public.kcp_is_admin(public.kcp_storage_group_id(name))
);

drop policy if exists kcp_calendar_storage_update on storage.objects;
create policy kcp_calendar_storage_update
on storage.objects for update to authenticated
using (
    bucket_id = 'kcp-school-calendars'
    and public.kcp_is_admin(public.kcp_storage_group_id(name))
)
with check (
    bucket_id = 'kcp-school-calendars'
    and public.kcp_is_admin(public.kcp_storage_group_id(name))
);

drop policy if exists kcp_calendar_storage_delete on storage.objects;
create policy kcp_calendar_storage_delete
on storage.objects for delete to authenticated
using (
    bucket_id = 'kcp-school-calendars'
    and public.kcp_is_admin(public.kcp_storage_group_id(name))
);

-- Explicit privileges: tables remain RLS-protected; clients use select and RPC.
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke all on function public.kcp_write_audit(uuid,text,text,text,jsonb) from public, anon;
revoke all on function public.kcp_is_member(uuid) from public, anon;
revoke all on function public.kcp_is_admin(uuid) from public, anon;
grant execute on function public.kcp_is_member(uuid) to authenticated;
grant execute on function public.kcp_is_admin(uuid) to authenticated;

-- Client RPC functions.
grant execute on function public.kcp_upsert_profile(text,text) to authenticated;
grant execute on function public.kcp_create_group(text,text,text,text,text,integer,smallint[],smallint[],text) to authenticated;
grant execute on function public.kcp_list_my_groups() to authenticated;
grant execute on function public.kcp_create_invitation(uuid,text,text,text,integer,text) to authenticated;
grant execute on function public.kcp_accept_invitation(text,text,text) to authenticated;
grant execute on function public.kcp_submit_constraint_request(uuid,smallint[],smallint[],text) to authenticated;
grant execute on function public.kcp_review_constraint_request(uuid,text,text) to authenticated;
grant execute on function public.kcp_set_member_role(uuid,uuid,text) to authenticated;
grant execute on function public.kcp_set_pilot_time_override(uuid,boolean) to authenticated;
grant execute on function public.kcp_register_calendar(uuid,text,text,text,text,text,bigint,text,jsonb) to authenticated;
grant execute on function public.kcp_calendar_analytics(uuid) to authenticated;
grant execute on function public.kcp_generate_schedule(uuid,text) to authenticated;
grant execute on function public.kcp_request_cover(uuid,text) to authenticated;
grant execute on function public.kcp_accept_cover(uuid) to authenticated;
grant execute on function public.kcp_start_trip(uuid) to authenticated;
grant execute on function public.kcp_complete_trip(uuid) to authenticated;
grant execute on function public.kcp_save_snapshot(uuid,jsonb) to authenticated;
grant execute on function public.kcp_get_snapshot(uuid) to authenticated;
grant execute on function public.kcp_health() to authenticated;

commit;
