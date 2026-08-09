begin;

-- ---------------------------------------------------------------------------
-- Child absence and separate-pickup workflow
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_child_absence_reports (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    child_id uuid not null references public.kcp_children(id) on delete cascade,
    trip_id uuid references public.kcp_trips(id) on delete cascade,
    starts_on date not null,
    ends_on date not null,
    reason text not null check (reason in (
        'absent','picked_up_separately','student_hours',
        'after_school_activity','appointment','other'
    )),
    note text,
    notify_driver boolean not null default true,
    status text not null default 'active' check (status in ('active','cancelled','expired')),
    reported_by uuid not null references public.kcp_profiles(id) on delete restrict,
    created_at timestamptz not null default now(),
    cancelled_at timestamptz,
    cancelled_by uuid references public.kcp_profiles(id) on delete set null,
    cancellation_reason text,
    check (ends_on >= starts_on),
    check (ends_on - starts_on <= 180)
);

create unique index if not exists kcp_active_trip_absence_unique
    on public.kcp_child_absence_reports(child_id, trip_id)
    where trip_id is not null and status = 'active';
create index if not exists kcp_child_absence_group_dates_idx
    on public.kcp_child_absence_reports(group_id, starts_on, ends_on)
    where status = 'active';
create index if not exists kcp_child_absence_child_dates_idx
    on public.kcp_child_absence_reports(child_id, starts_on, ends_on)
    where status = 'active';

alter table public.kcp_child_absence_reports enable row level security;
revoke all on table public.kcp_child_absence_reports from public, anon, authenticated;

create or replace function public.kcp_can_report_for_child(p_child_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1
        from public.kcp_children child
        join public.kcp_group_participants participant on participant.id = child.participant_id
        where child.id = p_child_id
          and child.status = 'active'
          and (
              participant.user_id = auth.uid()
              or public.kcp_is_admin(child.group_id)
          )
    );
$$;

create or replace function public.kcp_my_children()
returns table(
    child_id uuid,
    group_id uuid,
    group_name text,
    child_name text,
    grade_or_level text
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    return query
    select child.id, child.group_id, group_row.name, child.name, child.grade_or_level
    from public.kcp_children child
    join public.kcp_group_participants participant on participant.id = child.participant_id
    join public.kcp_groups group_row on group_row.id = child.group_id
    where participant.user_id = auth.uid()
      and participant.status = 'active'
      and child.status = 'active'
    order by group_row.name, child.name;
end;
$$;

create or replace function public.kcp_report_child_absence(
    p_child_id uuid,
    p_trip_id uuid default null,
    p_starts_on date default current_date,
    p_ends_on date default current_date,
    p_reason text default 'absent',
    p_note text default null,
    p_notify_driver boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    child public.kcp_children;
    trip public.kcp_trips;
    report_id uuid;
begin
    if not public.kcp_can_report_for_child(p_child_id) then raise exception 'Child reporting access required'; end if;
    select * into child from public.kcp_children where id = p_child_id;
    if p_reason not in ('absent','picked_up_separately','student_hours','after_school_activity','appointment','other') then
        raise exception 'Choose a valid absence or separate-pickup reason';
    end if;
    if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on or p_ends_on - p_starts_on > 180 then
        raise exception 'Choose a valid date or date range';
    end if;

    if p_trip_id is not null then
        select * into trip from public.kcp_trips where id = p_trip_id;
        if not found or trip.group_id <> child.group_id or not (child.name = any(trip.child_names)) then
            raise exception 'The selected child is not part of this ride';
        end if;
        if trip.started_at is not null or trip.status in ('in_progress','completion_due','completed','cancelled') then
            raise exception 'This ride has already started or closed';
        end if;
        p_starts_on := trip.trip_date;
        p_ends_on := trip.trip_date;
    end if;

    insert into public.kcp_child_absence_reports(
        group_id, child_id, trip_id, starts_on, ends_on, reason,
        note, notify_driver, status, reported_by
    ) values (
        child.group_id, child.id, p_trip_id, p_starts_on, p_ends_on,
        p_reason, nullif(trim(p_note), ''), p_notify_driver, 'active', auth.uid()
    )
    on conflict (child_id, trip_id) where trip_id is not null and status = 'active'
    do update set
        reason = excluded.reason,
        note = excluded.note,
        notify_driver = excluded.notify_driver,
        reported_by = auth.uid(),
        created_at = now()
    returning id into report_id;

    perform public.kcp_write_audit(
        child.group_id, 'child_absence_reported', 'child_absence', report_id::text,
        jsonb_build_object(
            'childId', child.id,
            'childName', child.name,
            'tripId', p_trip_id,
            'startsOn', p_starts_on,
            'endsOn', p_ends_on,
            'reason', p_reason,
            'notifyDriver', p_notify_driver
        )
    );
    return report_id;
end;
$$;

create or replace function public.kcp_cancel_child_absence(
    p_report_id uuid,
    p_reason text default 'Plans changed'
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    report public.kcp_child_absence_reports;
begin
    select * into report
    from public.kcp_child_absence_reports
    where id = p_report_id
    for update;
    if not found then raise exception 'Absence report not found'; end if;
    if report.status <> 'active' then raise exception 'Only an active report can be cancelled'; end if;
    if report.reported_by <> auth.uid() and not public.kcp_is_admin(report.group_id) then
        raise exception 'Only the reporting parent or a group administrator can cancel this report';
    end if;
    if report.trip_id is not null and exists (
        select 1 from public.kcp_trips trip
        where trip.id = report.trip_id and trip.started_at is not null
    ) then
        raise exception 'The ride has already started';
    end if;

    update public.kcp_child_absence_reports
       set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
           cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Plans changed')
     where id = report.id;

    perform public.kcp_write_audit(
        report.group_id, 'child_absence_cancelled', 'child_absence', report.id::text,
        jsonb_build_object('reason', coalesce(nullif(trim(p_reason), ''), 'Plans changed'))
    );
end;
$$;

create or replace function public.kcp_my_absence_reports(p_include_past boolean default false)
returns table(
    report_id uuid,
    group_id uuid,
    group_name text,
    child_id uuid,
    child_name text,
    trip_id uuid,
    trip_label text,
    trip_time timestamptz,
    starts_on date,
    ends_on date,
    reason text,
    note text,
    notify_driver boolean,
    status text,
    reported_by uuid,
    created_at timestamptz,
    can_cancel boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    return query
    select report.id, report.group_id, group_row.name, report.child_id, child.name,
           report.trip_id, coalesce(trip.display_label, case when trip.kind = 'afternoon_pickup' then 'Return' else 'Outbound' end),
           trip.scheduled_time, report.starts_on, report.ends_on, report.reason,
           report.note, report.notify_driver, report.status, report.reported_by,
           report.created_at,
           report.status = 'active'
             and (report.reported_by = auth.uid() or public.kcp_is_admin(report.group_id))
             and coalesce(trip.started_at is null, true)
    from public.kcp_child_absence_reports report
    join public.kcp_children child on child.id = report.child_id
    join public.kcp_groups group_row on group_row.id = report.group_id
    left join public.kcp_trips trip on trip.id = report.trip_id
    join public.kcp_memberships member
      on member.group_id = report.group_id
     and member.user_id = auth.uid()
     and member.status = 'active'
    where (
        public.kcp_is_admin(report.group_id)
        or report.reported_by = auth.uid()
        or exists (
            select 1 from public.kcp_group_participants participant
            where participant.id = child.participant_id and participant.user_id = auth.uid()
        )
        or coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = auth.uid()
    )
      and (p_include_past or report.ends_on >= current_date)
    order by report.starts_on, report.created_at;
end;
$$;

create or replace function public.kcp_trip_absence_reports(p_trip_id uuid)
returns table(
    report_id uuid,
    child_id uuid,
    child_name text,
    reason text,
    note text,
    reported_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    member_role text;
begin
    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;
    select member.role into member_role
    from public.kcp_memberships member
    where member.group_id = trip.group_id and member.user_id = auth.uid() and member.status = 'active';
    if member_role is null or member_role = 'viewer' then raise exception 'Operational ride access required'; end if;

    return query
    select report.id, child.id, child.name, report.reason, report.note, report.created_at
    from public.kcp_child_absence_reports report
    join public.kcp_children child on child.id = report.child_id
    where report.group_id = trip.group_id
      and report.status = 'active'
      and child.name = any(trip.child_names)
      and (
          report.trip_id = trip.id
          or (report.trip_id is null and trip.trip_date between report.starts_on and report.ends_on)
      )
      and (
          member_role in ('owner','admin')
          or coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = auth.uid()
          or exists (
              select 1 from public.kcp_group_participants participant
              where participant.id = child.participant_id and participant.user_id = auth.uid()
          )
      )
    order by child.name;
end;
$$;

-- Preserve the driver snapshot while enriching each child with an active
-- absence/separate-pickup report for this ride.
do $$
begin
    if to_regprocedure('public.kcp_driver_trip_snapshot_base(uuid)') is null
       and to_regprocedure('public.kcp_driver_trip_snapshot(uuid)') is not null then
        execute 'alter function public.kcp_driver_trip_snapshot(uuid) rename to kcp_driver_trip_snapshot_base';
    end if;
end;
$$;

create or replace function public.kcp_driver_trip_snapshot(p_trip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    base jsonb;
    enriched jsonb;
begin
    base := public.kcp_driver_trip_snapshot_base(p_trip_id);
    select coalesce(jsonb_agg(
        child_json || jsonb_build_object(
            'absence_report_id', absence.report_id,
            'absence_reason', absence.reason,
            'absence_note', absence.note,
            'latest_status', case when absence.report_id is not null then 'child_skipped' else child_json->>'latest_status' end
        )
        order by child_json->>'child_name'
    ), '[]'::jsonb)
    into enriched
    from jsonb_array_elements(coalesce(base->'roster', '[]'::jsonb)) child_json
    left join lateral (
        select report.report_id, report.reason, report.note
        from public.kcp_trip_absence_reports(p_trip_id) report
        where report.child_id = (child_json->>'child_id')::uuid
        limit 1
    ) absence on true;

    return jsonb_set(base, '{roster}', enriched, true);
end;
$$;

revoke all on function public.kcp_can_report_for_child(uuid) from public, anon;
revoke all on function public.kcp_my_children() from public, anon;
revoke all on function public.kcp_report_child_absence(uuid,uuid,date,date,text,text,boolean) from public, anon;
revoke all on function public.kcp_cancel_child_absence(uuid,text) from public, anon;
revoke all on function public.kcp_my_absence_reports(boolean) from public, anon;
revoke all on function public.kcp_trip_absence_reports(uuid) from public, anon;
revoke all on function public.kcp_driver_trip_snapshot(uuid) from public, anon;
grant execute on function public.kcp_my_children() to authenticated;
grant execute on function public.kcp_report_child_absence(uuid,uuid,date,date,text,text,boolean) to authenticated;
grant execute on function public.kcp_cancel_child_absence(uuid,text) to authenticated;
grant execute on function public.kcp_my_absence_reports(boolean) to authenticated;
grant execute on function public.kcp_trip_absence_reports(uuid) to authenticated;
grant execute on function public.kcp_driver_trip_snapshot(uuid) to authenticated;

commit;
