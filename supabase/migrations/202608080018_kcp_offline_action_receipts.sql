begin;

alter table public.kcp_trip_events
    drop constraint if exists kcp_trip_events_event_type_check;
alter table public.kcp_trip_events
    add constraint kcp_trip_events_event_type_check check (event_type in (
        'driver_confirmed','confirmation_due','trip_started','arrival_reported',
        'completion_due','completion_confirmed','admin_completion_confirmed',
        'marked_unconfirmed','child_picked_up','child_skipped','arrived_destination',
        'issue_reported','trip_cancelled','client_action_applied'
    ));

-- ---------------------------------------------------------------------------
-- Idempotent offline action replay
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_client_action_receipts (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    client_action_id text not null,
    trip_id uuid not null references public.kcp_trips(id) on delete cascade,
    action_type text not null check (action_type in (
        'confirm_trip','start_trip','child_picked_up','child_skipped',
        'arrive_destination','confirm_completion','report_issue'
    )),
    device_timestamp timestamptz,
    result jsonb not null default '{}'::jsonb,
    applied_at timestamptz not null default now(),
    unique (user_id, client_action_id)
);

create index if not exists kcp_client_action_receipts_trip_idx
    on public.kcp_client_action_receipts(trip_id, applied_at);

alter table public.kcp_client_action_receipts enable row level security;
revoke all on table public.kcp_client_action_receipts from public, anon, authenticated;

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
            perform public.kcp_start_trip(trip.id);
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
                trip.id,
                'event:' || trim(p_client_action_id),
                p_device_timestamp
            );
        when 'confirm_completion' then
            perform public.kcp_confirm_trip_completion(trip.id);
        when 'report_issue' then
            note := nullif(trim(p_payload->>'note'),'');
            if note is null then raise exception 'Issue note is required'; end if;
            perform public.kcp_report_trip_issue(
                trip.id,
                coalesce(nullif(trim(p_payload->>'category'),''),'other'),
                note,
                'event:' || trim(p_client_action_id),
                p_device_timestamp
            );
    end case;

    select * into trip from public.kcp_trips where id = p_trip_id;
    result := jsonb_build_object(
        'clientActionId', trim(p_client_action_id),
        'tripId', trip.id,
        'action', p_action,
        'tripStatus', trip.status,
        'appliedAt', now(),
        'deviceTimestamp', p_device_timestamp
    );

    insert into public.kcp_client_action_receipts(
        user_id, client_action_id, trip_id, action_type,
        device_timestamp, result
    ) values (
        auth.uid(), trim(p_client_action_id), trip.id, p_action,
        p_device_timestamp, result
    );

    perform public.kcp_record_trip_event(
        trip.id,
        'client_action_applied',
        auth.uid(),
        child_id,
        'receipt:' || trim(p_client_action_id),
        p_device_timestamp,
        jsonb_build_object('action',p_action,'offlineReplay',true)
    );

    return result;
end;
$$;

create or replace function public.kcp_my_client_action_receipts(p_client_action_ids text[])
returns table(
    client_action_id text,
    trip_id uuid,
    action_type text,
    result jsonb,
    applied_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select receipt.client_action_id, receipt.trip_id, receipt.action_type,
           receipt.result, receipt.applied_at
    from public.kcp_client_action_receipts receipt
    where receipt.user_id = auth.uid()
      and receipt.client_action_id = any(coalesce(p_client_action_ids,'{}'::text[]))
    order by receipt.applied_at;
$$;

revoke all on function public.kcp_apply_offline_trip_action(text,uuid,text,jsonb,timestamptz) from public, anon;
revoke all on function public.kcp_my_client_action_receipts(text[]) from public, anon;
grant execute on function public.kcp_apply_offline_trip_action(text,uuid,text,jsonb,timestamptz) to authenticated;
grant execute on function public.kcp_my_client_action_receipts(text[]) to authenticated;

commit;
