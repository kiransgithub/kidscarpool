begin;

alter table public.kcp_trips
    drop constraint if exists kcp_trips_started_source_check;
alter table public.kcp_trips
    add constraint kcp_trips_started_source_check
    check (started_source is null or started_source in ('manual','admin','legacy_automatic','offline'));

create or replace function public.kcp_start_trip_with_device_time(
    p_trip_id uuid,
    p_device_timestamp timestamptz
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    driver_id uuid;
begin
    if p_device_timestamp is null then raise exception 'Device timestamp is required for offline Start'; end if;
    if p_device_timestamp > now() + interval '5 minutes' then raise exception 'Device timestamp is too far in the future'; end if;

    select * into trip from public.kcp_trips where id = p_trip_id for update;
    if not found then raise exception 'Trip not found'; end if;
    driver_id := coalesce(trip.actual_driver_id, trip.scheduled_driver_id);
    if driver_id <> auth.uid() then raise exception 'Only the assigned driver can start this ride'; end if;
    if trip.status <> 'ready' or trip.confirmed_by <> auth.uid() then
        raise exception 'Confirm the ride before starting';
    end if;
    if trip.scheduled_time is null then raise exception 'Ride time must be confirmed before Start'; end if;
    if p_device_timestamp < trip.scheduled_time - interval '10 minutes'
       or p_device_timestamp > trip.scheduled_time + interval '90 minutes' then
        raise exception 'Offline Start was outside the allowed ride window';
    end if;

    update public.kcp_trips
       set status = 'in_progress',
           started_at = p_device_timestamp,
           started_source = 'offline',
           confirmation_due_at = null,
           unconfirmed_at = null,
           updated_at = now()
     where id = trip.id;

    perform public.kcp_record_trip_event(
        trip.id,'trip_started',auth.uid(),null,null,p_device_timestamp,
        jsonb_build_object('source','offline','syncedAt',now())
    );
    perform public.kcp_write_audit(
        trip.group_id,'trip_started_offline','trip',trip.id::text,
        jsonb_build_object('deviceTimestamp',p_device_timestamp,'syncedAt',now())
    );
end;
$$;

create or replace function public.kcp_apply_offline_trip_action(
    p_client_action_id text,
    p_trip_id uuid,
    p_action text,
    p_payload jsonb default '{}'::jsonb,
    p_device_timestamp timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    existing public.kcp_client_action_receipts;
    trip public.kcp_trips;
    result jsonb;
    child_id uuid;
    note text;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if length(trim(coalesce(p_client_action_id,''))) < 12
       or length(trim(p_client_action_id)) > 200 then
        raise exception 'Client action identifier is invalid';
    end if;
    if p_action not in (
        'confirm_trip','start_trip','child_picked_up','child_skipped',
        'arrive_destination','confirm_completion','report_issue'
    ) then raise exception 'Unknown offline ride action'; end if;

    perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || trim(p_client_action_id), 0));
    select * into existing
    from public.kcp_client_action_receipts receipt
    where receipt.user_id = auth.uid()
      and receipt.client_action_id = trim(p_client_action_id);
    if found then return existing.result; end if;

    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;
    if not public.kcp_is_member(trip.group_id) then raise exception 'Active group membership required'; end if;

    case p_action
        when 'confirm_trip' then
            perform public.kcp_confirm_trip(trip.id);
        when 'start_trip' then
            perform public.kcp_start_trip_with_device_time(trip.id,p_device_timestamp);
        when 'child_picked_up' then
            child_id := nullif(p_payload->>'childId','')::uuid;
            if child_id is null then raise exception 'Child identifier is required'; end if;
            perform public.kcp_mark_child_trip_status(
                trip.id, child_id, 'picked_up',
                'event:' || trim(p_client_action_id),
                nullif(p_payload->>'note',''),
                p_device_timestamp
            );
        when 'child_skipped' then
            child_id := nullif(p_payload->>'childId','')::uuid;
            if child_id is null then raise exception 'Child identifier is required'; end if;
            perform public.kcp_mark_child_trip_status(
                trip.id, child_id, 'skipped',
                'event:' || trim(p_client_action_id),
                nullif(p_payload->>'note',''),
                p_device_timestamp
            );
        when 'arrive_destination' then
            perform public.kcp_report_destination_arrival(
                trip.id,'event:' || trim(p_client_action_id),p_device_timestamp
            );
        when 'confirm_completion' then
            perform public.kcp_confirm_trip_completion(trip.id);
        when 'report_issue' then
            note := nullif(trim(p_payload->>'note'),'');
            if note is null then raise exception 'Issue note is required'; end if;
            perform public.kcp_report_trip_issue(
                trip.id,coalesce(nullif(trim(p_payload->>'category'),''),'other'),note,
                'event:' || trim(p_client_action_id),p_device_timestamp
            );
    end case;

    select * into trip from public.kcp_trips where id = p_trip_id;
    result := jsonb_build_object(
        'clientActionId',trim(p_client_action_id),'tripId',trip.id,
        'action',p_action,'tripStatus',trip.status,
        'appliedAt',now(),'deviceTimestamp',p_device_timestamp
    );

    insert into public.kcp_client_action_receipts(
        user_id,client_action_id,trip_id,action_type,device_timestamp,result
    ) values (
        auth.uid(),trim(p_client_action_id),trip.id,p_action,p_device_timestamp,result
    );

    perform public.kcp_record_trip_event(
        trip.id,'client_action_applied',auth.uid(),child_id,
        'receipt:' || trim(p_client_action_id),p_device_timestamp,
        jsonb_build_object('action',p_action,'offlineReplay',true)
    );
    return result;
end;
$$;

revoke all on function public.kcp_start_trip_with_device_time(uuid,timestamptz) from public, anon, authenticated;
revoke all on function public.kcp_apply_offline_trip_action(text,uuid,text,jsonb,timestamptz) from public, anon;
grant execute on function public.kcp_apply_offline_trip_action(text,uuid,text,jsonb,timestamptz) to authenticated;

commit;
