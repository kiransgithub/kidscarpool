begin;

-- ---------------------------------------------------------------------------
-- Platform-level Super Admin and support operations
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_platform_admins (
    user_id uuid primary key references auth.users(id) on delete cascade,
    role text not null default 'super_admin'
        check (role in ('super_admin','support_admin','support_readonly')),
    status text not null default 'active'
        check (status in ('active','suspended','removed')),
    can_break_glass boolean not null default true,
    created_at timestamptz not null default now(),
    created_by uuid references auth.users(id),
    updated_at timestamptz not null default now()
);

create table if not exists public.kcp_support_cases (
    id uuid primary key default gen_random_uuid(),
    reference_code text not null unique,
    group_id uuid references public.kcp_groups(id) on delete set null,
    reported_by uuid references auth.users(id) on delete set null,
    assigned_to uuid references auth.users(id) on delete set null,
    category text not null default 'general',
    priority text not null default 'normal'
        check (priority in ('low','normal','high','urgent')),
    status text not null default 'open'
        check (status in ('open','investigating','waiting_user','resolved','closed')),
    summary text not null,
    safe_details jsonb not null default '{}'::jsonb,
    resolution text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    resolved_at timestamptz
);

create index if not exists kcp_support_cases_status_idx
    on public.kcp_support_cases(status, priority, created_at desc);
create index if not exists kcp_support_cases_group_idx
    on public.kcp_support_cases(group_id, created_at desc);

create table if not exists public.kcp_client_error_events (
    id uuid primary key default gen_random_uuid(),
    reference_code text not null unique,
    user_id uuid references auth.users(id) on delete set null,
    group_id uuid references public.kcp_groups(id) on delete set null,
    operation text not null,
    client_version text,
    message_code text,
    safe_metadata jsonb not null default '{}'::jsonb,
    technical_message text,
    created_at timestamptz not null default now(),
    resolved_at timestamptz,
    resolved_by uuid references auth.users(id) on delete set null
);

create index if not exists kcp_client_error_events_created_idx
    on public.kcp_client_error_events(created_at desc);
create index if not exists kcp_client_error_events_group_idx
    on public.kcp_client_error_events(group_id, created_at desc);

create table if not exists public.kcp_break_glass_events (
    id uuid primary key default gen_random_uuid(),
    platform_admin_id uuid not null references auth.users(id) on delete restrict,
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    reason text not null,
    opened_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '10 minutes'),
    closed_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    check (length(reason) between 10 and 500)
);

create index if not exists kcp_break_glass_active_idx
    on public.kcp_break_glass_events(platform_admin_id, group_id, expires_at)
    where closed_at is null;

create table if not exists public.kcp_platform_audit_events (
    id bigint generated always as identity primary key,
    actor_id uuid references auth.users(id) on delete set null,
    action text not null,
    entity_type text not null,
    entity_id text,
    details jsonb not null default '{}'::jsonb,
    occurred_at timestamptz not null default now()
);

create index if not exists kcp_platform_audit_occurred_idx
    on public.kcp_platform_audit_events(occurred_at desc);

alter table public.kcp_platform_admins enable row level security;
alter table public.kcp_support_cases enable row level security;
alter table public.kcp_client_error_events enable row level security;
alter table public.kcp_break_glass_events enable row level security;
alter table public.kcp_platform_audit_events enable row level security;

-- Direct table access is intentionally disabled. Trusted RPCs below enforce
-- platform roles and return only the fields needed by the support console.
revoke all on table public.kcp_platform_admins from public, anon, authenticated;
revoke all on table public.kcp_support_cases from public, anon, authenticated;
revoke all on table public.kcp_client_error_events from public, anon, authenticated;
revoke all on table public.kcp_break_glass_events from public, anon, authenticated;
revoke all on table public.kcp_platform_audit_events from public, anon, authenticated;

create or replace function public.kcp_is_platform_admin(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1
        from public.kcp_platform_admins admin
        where admin.user_id = p_user_id
          and admin.status = 'active'
          and admin.role in ('super_admin','support_admin','support_readonly')
    );
$$;

create or replace function public.kcp_platform_role()
returns table(role text, can_break_glass boolean)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select admin.role, admin.can_break_glass
    from public.kcp_platform_admins admin
    where admin.user_id = auth.uid()
      and admin.status = 'active';
$$;

-- Bootstrap helper for the Supabase SQL Editor. Execution is revoked from all
-- browser roles; a project operator runs it once after the chosen account has a
-- verified email identity.
create or replace function public.kcp_bootstrap_platform_admin(
    p_email text,
    p_role text default 'super_admin'
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
    target_user uuid;
begin
    if p_role not in ('super_admin','support_admin','support_readonly') then
        raise exception 'Unsupported platform role';
    end if;

    select auth_user.id into target_user
    from auth.users auth_user
    where lower(auth_user.email) = lower(trim(p_email))
      and auth_user.email_confirmed_at is not null
      and coalesce(auth_user.is_anonymous, false) = false
    order by auth_user.created_at
    limit 1;

    if target_user is null then
        raise exception 'A verified permanent user with that email was not found';
    end if;

    insert into public.kcp_platform_admins(
        user_id, role, status, can_break_glass, created_by, updated_at
    ) values (
        target_user, p_role, 'active', p_role <> 'support_readonly', auth.uid(), now()
    )
    on conflict (user_id) do update
       set role = excluded.role,
           status = 'active',
           can_break_glass = excluded.can_break_glass,
           updated_at = now();

    insert into public.kcp_platform_audit_events(
        actor_id, action, entity_type, entity_id, details
    ) values (
        auth.uid(), 'platform_admin_bootstrapped', 'user', target_user::text,
        jsonb_build_object('role', p_role)
    );

    return target_user;
end;
$$;

create or replace function public.kcp_admin_list_groups(
    p_search text default null,
    p_limit integer default 50,
    p_offset integer default 0
)
returns table(
    group_id uuid,
    group_code text,
    group_name text,
    group_kind text,
    destination_name text,
    term_label text,
    status text,
    owner_name text,
    active_member_count bigint,
    current_schedule_version integer,
    open_cover_count bigint,
    next_trip_at timestamptz,
    last_activity_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin() then raise exception 'Platform administrator role required'; end if;

    return query
    select
        group_row.id,
        group_row.code,
        group_row.name,
        group_row.group_kind,
        group_row.school_name,
        group_row.academic_year,
        group_row.status,
        owner_member.parent_name,
        (select count(*) from public.kcp_memberships member
          where member.group_id = group_row.id and member.status = 'active'),
        group_row.current_schedule_version,
        (select count(*) from public.kcp_cover_requests cover
          where cover.group_id = group_row.id and cover.status = 'open'),
        (select min(trip.scheduled_time) from public.kcp_trips trip
          where trip.group_id = group_row.id
            and trip.status in ('scheduled','cover_requested','cover_accepted','in_progress')
            and trip.scheduled_time >= now()),
        greatest(
            group_row.updated_at,
            coalesce((select max(audit.occurred_at) from public.kcp_audit_events audit
                       where audit.group_id = group_row.id), group_row.updated_at)
        )
    from public.kcp_groups group_row
    left join lateral (
        select member.parent_name
        from public.kcp_memberships member
        where member.group_id = group_row.id
          and member.status = 'active'
          and member.role = 'owner'
        order by member.joined_at
        limit 1
    ) owner_member on true
    where p_search is null
       or trim(p_search) = ''
       or group_row.name ilike '%' || trim(p_search) || '%'
       or group_row.code ilike '%' || trim(p_search) || '%'
       or coalesce(group_row.school_name, '') ilike '%' || trim(p_search) || '%'
    order by last_activity_at desc
    limit least(greatest(p_limit, 1), 200)
    offset greatest(p_offset, 0);
end;
$$;

create or replace function public.kcp_admin_group_overview(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    result jsonb;
begin
    if not public.kcp_is_platform_admin() then raise exception 'Platform administrator role required'; end if;

    select jsonb_build_object(
        'group', to_jsonb(group_row),
        'members', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userId', member.user_id,
                'name', member.parent_name,
                'role', member.role,
                'status', member.status,
                'joinedAt', member.joined_at
            ) order by member.parent_name)
            from public.kcp_memberships member
            where member.group_id = group_row.id
        ), '[]'::jsonb),
        'counts', jsonb_build_object(
            'trips', (select count(*) from public.kcp_trips trip where trip.group_id = group_row.id),
            'openCovers', (select count(*) from public.kcp_cover_requests cover where cover.group_id = group_row.id and cover.status = 'open'),
            'pendingInvitations', (select count(*) from public.kcp_invitations invitation where invitation.group_id = group_row.id and invitation.status = 'pending'),
            'pendingChanges', (select count(*) from public.kcp_constraint_requests request where request.group_id = group_row.id and request.status = 'pending')
        ),
        'nextTrips', coalesce((
            select jsonb_agg(to_jsonb(next_trip) order by next_trip.scheduled_time)
            from (
                select trip.id, trip.scheduled_time, trip.status, trip.display_label,
                       trip.scheduled_driver_name, trip.actual_driver_name
                from public.kcp_trips trip
                where trip.group_id = group_row.id
                  and trip.scheduled_time >= now()
                order by trip.scheduled_time
                limit 10
            ) next_trip
        ), '[]'::jsonb)
    ) into result
    from public.kcp_groups group_row
    where group_row.id = p_group_id;

    if result is null then raise exception 'Group not found'; end if;
    return result;
end;
$$;

create or replace function public.kcp_report_client_error(
    p_operation text,
    p_client_version text default null,
    p_group_id uuid default null,
    p_message_code text default null,
    p_safe_metadata jsonb default '{}'::jsonb,
    p_technical_message text default null
)
returns text
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    reference text := 'KCP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    insert into public.kcp_client_error_events(
        reference_code, user_id, group_id, operation, client_version,
        message_code, safe_metadata, technical_message
    ) values (
        reference, auth.uid(), p_group_id, left(coalesce(nullif(trim(p_operation), ''), 'unknown'), 120),
        nullif(trim(p_client_version), ''), nullif(trim(p_message_code), ''),
        coalesce(p_safe_metadata, '{}'::jsonb), left(p_technical_message, 2000)
    );

    return reference;
end;
$$;

create or replace function public.kcp_admin_list_client_errors(p_limit integer default 100)
returns table(
    reference_code text,
    created_at timestamptz,
    group_id uuid,
    user_id uuid,
    operation text,
    client_version text,
    message_code text,
    safe_metadata jsonb,
    technical_message text,
    resolved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin() then raise exception 'Platform administrator role required'; end if;

    return query
    select event.reference_code, event.created_at, event.group_id, event.user_id,
           event.operation, event.client_version, event.message_code,
           event.safe_metadata, event.technical_message, event.resolved_at
    from public.kcp_client_error_events event
    order by event.created_at desc
    limit least(greatest(p_limit, 1), 500);
end;
$$;

create or replace function public.kcp_admin_open_break_glass(
    p_group_id uuid,
    p_reason text
)
returns table(event_id uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    admin_record public.kcp_platform_admins;
    created public.kcp_break_glass_events;
begin
    select * into admin_record
    from public.kcp_platform_admins admin
    where admin.user_id = auth.uid() and admin.status = 'active';

    if not found or not admin_record.can_break_glass then
        raise exception 'Break-glass permission required';
    end if;
    if length(trim(coalesce(p_reason, ''))) < 10 then
        raise exception 'Provide a specific support reason';
    end if;

    insert into public.kcp_break_glass_events(platform_admin_id, group_id, reason)
    values (auth.uid(), p_group_id, trim(p_reason))
    returning * into created;

    insert into public.kcp_platform_audit_events(actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'break_glass_opened', 'group', p_group_id::text,
            jsonb_build_object('eventId', created.id, 'reason', trim(p_reason), 'expiresAt', created.expires_at));

    return query select created.id, created.expires_at;
end;
$$;

create or replace function public.kcp_admin_close_break_glass(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    target public.kcp_break_glass_events;
begin
    if not public.kcp_is_platform_admin() then raise exception 'Platform administrator role required'; end if;

    update public.kcp_break_glass_events
       set closed_at = coalesce(closed_at, now())
     where id = p_event_id
       and platform_admin_id = auth.uid()
    returning * into target;

    if not found then raise exception 'Active support access was not found'; end if;

    insert into public.kcp_platform_audit_events(actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'break_glass_closed', 'group', target.group_id::text,
            jsonb_build_object('eventId', target.id));
end;
$$;

create or replace function public.kcp_admin_create_support_case(
    p_group_id uuid,
    p_category text,
    p_priority text,
    p_summary text,
    p_safe_details jsonb default '{}'::jsonb
)
returns table(case_id uuid, reference_code text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    reference text := 'CASE-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    created_id uuid;
begin
    if not public.kcp_is_platform_admin() then raise exception 'Platform administrator role required'; end if;
    if length(trim(coalesce(p_summary, ''))) < 5 then raise exception 'Support summary is required'; end if;

    insert into public.kcp_support_cases(
        reference_code, group_id, reported_by, assigned_to, category,
        priority, summary, safe_details
    ) values (
        reference, p_group_id, auth.uid(), auth.uid(),
        coalesce(nullif(trim(p_category), ''), 'general'),
        coalesce(nullif(trim(p_priority), ''), 'normal'),
        trim(p_summary), coalesce(p_safe_details, '{}'::jsonb)
    ) returning id into created_id;

    insert into public.kcp_platform_audit_events(actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'support_case_created', 'support_case', created_id::text,
            jsonb_build_object('referenceCode', reference, 'groupId', p_group_id));

    return query select created_id, reference;
end;
$$;

create or replace function public.kcp_admin_list_support_cases(p_limit integer default 100)
returns table(
    case_id uuid,
    reference_code text,
    group_id uuid,
    category text,
    priority text,
    status text,
    summary text,
    created_at timestamptz,
    updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin() then raise exception 'Platform administrator role required'; end if;

    return query
    select support.id, support.reference_code, support.group_id, support.category,
           support.priority, support.status, support.summary, support.created_at, support.updated_at
    from public.kcp_support_cases support
    order by
        case support.priority when 'urgent' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
        support.created_at desc
    limit least(greatest(p_limit, 1), 500);
end;
$$;

revoke all on function public.kcp_is_platform_admin(uuid) from public, anon;
revoke all on function public.kcp_platform_role() from public, anon;
revoke all on function public.kcp_bootstrap_platform_admin(text,text) from public, anon, authenticated;
revoke all on function public.kcp_admin_list_groups(text,integer,integer) from public, anon;
revoke all on function public.kcp_admin_group_overview(uuid) from public, anon;
revoke all on function public.kcp_report_client_error(text,text,uuid,text,jsonb,text) from public, anon;
revoke all on function public.kcp_admin_list_client_errors(integer) from public, anon;
revoke all on function public.kcp_admin_open_break_glass(uuid,text) from public, anon;
revoke all on function public.kcp_admin_close_break_glass(uuid) from public, anon;
revoke all on function public.kcp_admin_create_support_case(uuid,text,text,text,jsonb) from public, anon;
revoke all on function public.kcp_admin_list_support_cases(integer) from public, anon;

grant execute on function public.kcp_is_platform_admin(uuid) to authenticated;
grant execute on function public.kcp_platform_role() to authenticated;
grant execute on function public.kcp_admin_list_groups(text,integer,integer) to authenticated;
grant execute on function public.kcp_admin_group_overview(uuid) to authenticated;
grant execute on function public.kcp_report_client_error(text,text,uuid,text,jsonb,text) to authenticated;
grant execute on function public.kcp_admin_list_client_errors(integer) to authenticated;
grant execute on function public.kcp_admin_open_break_glass(uuid,text) to authenticated;
grant execute on function public.kcp_admin_close_break_glass(uuid) to authenticated;
grant execute on function public.kcp_admin_create_support_case(uuid,text,text,text,jsonb) to authenticated;
grant execute on function public.kcp_admin_list_support_cases(integer) to authenticated;

commit;
