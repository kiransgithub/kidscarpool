begin;

-- ---------------------------------------------------------------------------
-- Trip-scoped child roster privacy
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_sensitive_access_events (
    id bigint generated always as identity primary key,
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    trip_id uuid references public.kcp_trips(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    access_scope text not null check (access_scope in ('owner_admin','assigned_driver','own_child','platform_break_glass')),
    resource_type text not null default 'trip_operational_roster',
    reason text,
    accessed_at timestamptz not null default now()
);

create index if not exists kcp_sensitive_access_events_group_idx
    on public.kcp_sensitive_access_events(group_id, accessed_at desc);

alter table public.kcp_sensitive_access_events enable row level security;
revoke all on table public.kcp_sensitive_access_events from public, anon, authenticated;

-- Child master rows contain pickup tags, so ordinary group membership is too
-- broad. Direct reads are limited to the owning family and group administrators.
drop policy if exists kcp_children_member_select on public.kcp_children;
drop policy if exists kcp_children_private_select on public.kcp_children;
create policy kcp_children_private_select
on public.kcp_children for select to authenticated
using (
    public.kcp_is_admin(group_id)
    or exists (
        select 1
        from public.kcp_group_participants participant
        where participant.id = participant_id
          and participant.user_id = auth.uid()
          and participant.status = 'active'
    )
);

-- Prevent a browser from selecting the sensitive trip child list or free-form
-- operational notes directly. The role-aware RPC below is the application path.
revoke select on table public.kcp_trips from authenticated;
do $$
declare
    safe_columns text;
begin
    select string_agg(quote_ident(attribute.attname), ', ' order by attribute.attnum)
      into safe_columns
      from pg_attribute attribute
     where attribute.attrelid = 'public.kcp_trips'::regclass
       and attribute.attnum > 0
       and not attribute.attisdropped
       and attribute.attname not in ('child_names','notes');

    execute format('grant select (%s) on public.kcp_trips to authenticated', safe_columns);
end;
$$;

create or replace function public.kcp_group_trips(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    membership_role text;
    current_version integer;
    result jsonb;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select member.role into membership_role
    from public.kcp_memberships member
    where member.group_id = p_group_id
      and member.user_id = auth.uid()
      and member.status = 'active';
    if membership_role is null then raise exception 'Active group membership required'; end if;

    select group_row.current_schedule_version into current_version
    from public.kcp_groups group_row where group_row.id = p_group_id;

    select coalesce(jsonb_agg(
        to_jsonb(trip)
        || jsonb_build_object(
            'child_names', case when membership_role = 'viewer' then '[]'::jsonb else to_jsonb(trip.child_names) end,
            'notes', case when membership_role = 'viewer' then '' else trip.notes end
        )
        order by trip.trip_date, trip.scheduled_time nulls last, trip.kind, trip.id
    ), '[]'::jsonb)
    into result
    from public.kcp_trips trip
    where trip.group_id = p_group_id
      and trip.schedule_version = current_version;

    return result;
end;
$$;

create or replace function public.kcp_trip_roster_access_scope(p_trip_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    member_role text;
    is_driver boolean;
    in_window boolean;
    owns_child boolean;
begin
    if auth.uid() is null then return 'none'; end if;
    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then return 'none'; end if;

    select member.role into member_role
    from public.kcp_memberships member
    where member.group_id = trip.group_id
      and member.user_id = auth.uid()
      and member.status = 'active';
    if member_role is null or member_role = 'viewer' then return 'none'; end if;
    if member_role in ('owner','admin') then return 'owner_admin'; end if;

    is_driver := auth.uid() in (trip.scheduled_driver_id, trip.actual_driver_id);
    in_window := trip.status = 'in_progress'
      or (
          trip.scheduled_time is not null
          and now() >= trip.scheduled_time - interval '60 minutes'
          and now() <= coalesce(trip.completed_at + interval '2 hours', trip.scheduled_time + interval '8 hours')
      );
    if is_driver and in_window then return 'assigned_driver'; end if;

    select exists (
        select 1
        from public.kcp_children child
        join public.kcp_group_participants participant on participant.id = child.participant_id
        where child.group_id = trip.group_id
          and child.name = any(trip.child_names)
          and participant.user_id = auth.uid()
          and child.status = 'active'
    ) into owns_child;
    if owns_child then return 'own_child'; end if;
    return 'none';
end;
$$;

create or replace function public.kcp_get_trip_operational_roster(p_trip_id uuid)
returns table(
    child_id uuid,
    child_name text,
    pickup_tag text,
    pickup_address text,
    dropoff_address text,
    authorized_pickup_people jsonb,
    emergency_contact_name text,
    emergency_contact_phone text,
    seat_requirement text,
    critical_alert text,
    pickup_instructions text,
    access_scope text
)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    scope text;
begin
    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;

    scope := public.kcp_trip_roster_access_scope(p_trip_id);
    if scope = 'none' then
        raise exception 'Operational roster is available only to the assigned driver near ride time, the child parent, or a group administrator';
    end if;

    insert into public.kcp_sensitive_access_events(
        group_id, trip_id, user_id, access_scope, resource_type, reason
    ) values (
        trip.group_id, trip.id, auth.uid(), scope,
        'trip_operational_roster',
        case scope
            when 'assigned_driver' then 'Assigned driver opened imminent/current trip'
            when 'own_child' then 'Parent opened own child details'
            else 'Group administrator operational review'
        end
    );

    return query
    select
        child.id,
        child.name,
        child.pickup_tag,
        profile.pickup_address,
        profile.dropoff_address,
        coalesce(profile.authorized_pickup_people, '[]'::jsonb),
        profile.emergency_contact_name,
        profile.emergency_contact_phone,
        coalesce(profile.seat_requirement, 'none'),
        profile.critical_alert,
        profile.pickup_instructions,
        scope
    from unnest(trip.child_names) with ordinality trip_child(child_name, position)
    join public.kcp_children child
      on child.group_id = trip.group_id
     and child.name = trip_child.child_name
     and child.status = 'active'
    join public.kcp_group_participants participant on participant.id = child.participant_id
    left join public.kcp_child_safety_profiles profile on profile.child_id = child.id
    where scope in ('owner_admin','assigned_driver')
       or participant.user_id = auth.uid()
    order by trip_child.position;
end;
$$;

-- Recreate the all-group agenda so Viewer results contain no child list.
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
        group_row.id, group_row.code, group_row.name, group_row.group_kind,
        membership.role, trip.id, trip.trip_date, trip.scheduled_time,
        trip.time_label,
        coalesce(trip.leg_type, case when trip.kind = 'afternoon_pickup' then 'return' else 'outbound' end),
        coalesce(trip.display_label, case when trip.kind = 'afternoon_pickup' then 'Return' else 'Outbound' end),
        trip.status, trip.scheduled_driver_id, trip.scheduled_driver_name,
        trip.actual_driver_id, trip.actual_driver_name,
        case when membership.role = 'viewer' then '{}'::text[] else trip.child_names end,
        trip.volunteer_assignment,
        case when membership.role = 'viewer' then '' else trip.notes end
    from public.kcp_memberships membership
    join public.kcp_groups group_row on group_row.id = membership.group_id and group_row.status = 'active'
    join public.kcp_trips trip on trip.group_id = group_row.id and trip.schedule_version = group_row.current_schedule_version
    where membership.user_id = auth.uid()
      and membership.status = 'active'
      and (
          trip.scheduled_time between p_from and p_to
          or (trip.scheduled_time is null and trip.trip_date between p_from::date and p_to::date)
          or trip.status = 'in_progress'
      )
    order by case when trip.status = 'in_progress' then 0 else 1 end,
             coalesce(trip.scheduled_time, trip.trip_date::timestamptz), trip.id
    limit least(greatest(p_limit, 1), 1000);
end;
$$;

revoke all on function public.kcp_group_trips(uuid) from public, anon;
revoke all on function public.kcp_trip_roster_access_scope(uuid) from public, anon;
revoke all on function public.kcp_get_trip_operational_roster(uuid) from public, anon;
revoke all on function public.kcp_my_agenda(timestamptz,timestamptz,integer) from public, anon;
grant execute on function public.kcp_group_trips(uuid) to authenticated;
grant execute on function public.kcp_trip_roster_access_scope(uuid) to authenticated;
grant execute on function public.kcp_get_trip_operational_roster(uuid) to authenticated;
grant execute on function public.kcp_my_agenda(timestamptz,timestamptz,integer) to authenticated;

commit;
