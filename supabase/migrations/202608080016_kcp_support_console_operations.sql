begin;

-- ---------------------------------------------------------------------------
-- Platform support console. Browser code receives no service-role credential;
-- every operation is authorized and audited by a security-definer function.
-- ---------------------------------------------------------------------------

alter table public.kcp_break_glass_events
    add column if not exists expires_at timestamptz,
    add column if not exists closed_at timestamptz,
    add column if not exists closed_by uuid references auth.users(id) on delete set null,
    add column if not exists resource_scope text not null default 'group';

create table if not exists public.kcp_client_heartbeats (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    client_instance_id text not null,
    build_version text not null,
    cache_version text,
    platform text,
    user_agent text,
    active_group_id uuid references public.kcp_groups(id) on delete set null,
    last_seen_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (user_id, client_instance_id)
);

create index if not exists kcp_client_heartbeats_group_seen_idx
    on public.kcp_client_heartbeats(active_group_id, last_seen_at desc);
create index if not exists kcp_client_heartbeats_seen_idx
    on public.kcp_client_heartbeats(last_seen_at desc);

alter table public.kcp_client_heartbeats enable row level security;
revoke all on table public.kcp_client_heartbeats from public, anon, authenticated;

create or replace function public.kcp_mask_support_text(p_value text)
returns text
language sql
immutable
set search_path = public, pg_catalog
as $$
    select case
        when nullif(trim(p_value), '') is null then null
        when length(trim(p_value)) = 1 then '•'
        when length(trim(p_value)) = 2 then left(trim(p_value),1) || '•'
        else left(trim(p_value),1) || repeat('•', greatest(length(trim(p_value)) - 2, 1)) || right(trim(p_value),1)
    end;
$$;

create or replace function public.kcp_register_client_heartbeat(
    p_client_instance_id text,
    p_build_version text,
    p_cache_version text default null,
    p_platform text default null,
    p_user_agent text default null,
    p_active_group_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if length(trim(coalesce(p_client_instance_id,''))) < 8
       or length(trim(coalesce(p_build_version,''))) < 2 then
        raise exception 'Client identity and build version are required';
    end if;
    if p_active_group_id is not null and not public.kcp_is_member(p_active_group_id) then
        p_active_group_id := null;
    end if;

    insert into public.kcp_client_heartbeats(
        user_id, client_instance_id, build_version, cache_version,
        platform, user_agent, active_group_id, last_seen_at
    ) values (
        auth.uid(), left(trim(p_client_instance_id),120), left(trim(p_build_version),80),
        left(nullif(trim(p_cache_version),''),80), left(nullif(trim(p_platform),''),80),
        left(nullif(trim(p_user_agent),''),500), p_active_group_id, now()
    )
    on conflict (user_id, client_instance_id) do update
       set build_version = excluded.build_version,
           cache_version = excluded.cache_version,
           platform = excluded.platform,
           user_agent = excluded.user_agent,
           active_group_id = excluded.active_group_id,
           last_seen_at = now();
end;
$$;

create or replace function public.kcp_support_me()
returns table(
    user_id uuid,
    display_name text,
    account_email text,
    platform_role text
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin('support_admin') then
        raise exception 'Platform support role required';
    end if;
    return query
    select profile.id, profile.display_name, profile.account_email, administrator.role
    from public.kcp_platform_admins administrator
    join public.kcp_profiles profile on profile.id = administrator.user_id
    where administrator.user_id = auth.uid() and administrator.status = 'active';
end;
$$;

create or replace function public.kcp_support_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, supabase_migrations, pg_catalog
as $$
declare
    result jsonb;
begin
    if not public.kcp_is_platform_admin('support_admin') then
        raise exception 'Platform support role required';
    end if;

    select jsonb_build_object(
        'groups', (select count(*) from public.kcp_groups),
        'activeGroups', (select count(*) from public.kcp_groups where status = 'active'),
        'activeMembers', (select count(*) from public.kcp_memberships where status = 'active'),
        'ridesNext24Hours', (
            select count(*) from public.kcp_trips trip
            join public.kcp_groups group_row on group_row.id = trip.group_id
            where trip.schedule_version = group_row.current_schedule_version
              and trip.scheduled_time between now() and now() + interval '24 hours'
              and trip.status not in ('completed','cancelled')
        ),
        'openCovers', (select count(*) from public.kcp_cover_requests where status = 'open'),
        'unconfirmedRides', (select count(*) from public.kcp_trips where status in ('confirmation_due','completion_due','unconfirmed')),
        'openSupportCases', (select count(*) from public.kcp_support_cases where status not in ('resolved','closed')),
        'recentClientErrors', (select count(*) from public.kcp_client_error_events where created_at >= now() - interval '24 hours'),
        'activeClients24Hours', (select count(distinct user_id) from public.kcp_client_heartbeats where last_seen_at >= now() - interval '24 hours'),
        'latestMigration', (
            select max(version)::text from supabase_migrations.schema_migrations
        ),
        'generatedAt', now()
    ) into result;
    return result;
end;
$$;

create or replace function public.kcp_support_groups(
    p_search text default null,
    p_status text default null,
    p_limit integer default 100,
    p_offset integer default 0
)
returns table(
    group_id uuid,
    group_code text,
    group_name text,
    group_kind text,
    group_status text,
    owner_name_masked text,
    owner_user_id uuid,
    active_member_count integer,
    active_driver_count integer,
    viewer_count integer,
    next_trip_time timestamptz,
    next_trip_label text,
    open_cover_count integer,
    unconfirmed_ride_count integer,
    pending_invitation_count integer,
    current_schedule_version integer,
    last_activity_at timestamptz,
    latest_client_build text,
    latest_client_seen_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin('support_admin') then
        raise exception 'Platform support role required';
    end if;

    return query
    select
        group_row.id,
        group_row.code,
        group_row.name,
        group_row.group_kind,
        group_row.status,
        public.kcp_mask_support_text(owner_member.parent_name),
        owner_member.user_id,
        (select count(*)::integer from public.kcp_memberships member where member.group_id = group_row.id and member.status = 'active'),
        (select count(*)::integer from public.kcp_group_participants participant where participant.group_id = group_row.id and participant.status = 'active' and participant.can_drive),
        (select count(*)::integer from public.kcp_memberships member where member.group_id = group_row.id and member.status = 'active' and member.role = 'viewer'),
        next_trip.scheduled_time,
        next_trip.display_label,
        (select count(*)::integer from public.kcp_cover_requests cover where cover.group_id = group_row.id and cover.status = 'open'),
        (select count(*)::integer from public.kcp_trips trip where trip.group_id = group_row.id and trip.status in ('confirmation_due','completion_due','unconfirmed')),
        (select count(*)::integer from public.kcp_invitations invitation where invitation.group_id = group_row.id and invitation.status = 'pending' and invitation.expires_at > now()),
        group_row.current_schedule_version,
        greatest(
            group_row.updated_at,
            coalesce((select max(audit.occurred_at) from public.kcp_audit_events audit where audit.group_id = group_row.id), group_row.updated_at)
        ),
        heartbeat.build_version,
        heartbeat.last_seen_at
    from public.kcp_groups group_row
    left join public.kcp_memberships owner_member
      on owner_member.group_id = group_row.id
     and owner_member.role = 'owner'
     and owner_member.status = 'active'
    left join lateral (
        select trip.scheduled_time,
               coalesce(trip.display_label, case when trip.kind = 'afternoon_pickup' then 'Return' else 'Outbound' end) as display_label
        from public.kcp_trips trip
        where trip.group_id = group_row.id
          and trip.schedule_version = group_row.current_schedule_version
          and trip.status not in ('completed','cancelled')
          and coalesce(trip.scheduled_time, trip.trip_date::timestamptz) >= now()
        order by coalesce(trip.scheduled_time, trip.trip_date::timestamptz)
        limit 1
    ) next_trip on true
    left join lateral (
        select client.build_version, client.last_seen_at
        from public.kcp_client_heartbeats client
        where client.active_group_id = group_row.id
        order by client.last_seen_at desc
        limit 1
    ) heartbeat on true
    where (p_status is null or group_row.status = p_status)
      and (
          nullif(trim(p_search),'') is null
          or group_row.name ilike '%' || trim(p_search) || '%'
          or group_row.code ilike '%' || trim(p_search) || '%'
      )
    order by last_activity_at desc, group_row.name
    limit least(greatest(p_limit,1),500)
    offset greatest(p_offset,0);
end;
$$;

create or replace function public.kcp_support_group_details(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    group_record public.kcp_groups;
    result jsonb;
begin
    if not public.kcp_is_platform_admin('support_admin') then
        raise exception 'Platform support role required';
    end if;
    select * into group_record from public.kcp_groups where id = p_group_id;
    if not found then raise exception 'Group not found'; end if;

    select to_jsonb(group_record)
      - 'created_by'
      || jsonb_build_object(
        'members', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userId', member.user_id,
                'name', public.kcp_mask_support_text(member.parent_name),
                'role', member.role,
                'status', member.status,
                'joinedAt', member.joined_at,
                'canDrive', coalesce(participant.can_drive,false)
            ) order by member.role, member.parent_name)
            from public.kcp_memberships member
            left join public.kcp_group_participants participant
              on participant.group_id = member.group_id and participant.user_id = member.user_id and participant.status = 'active'
            where member.group_id = group_record.id
        ), '[]'::jsonb),
        'scheduleVersions', coalesce((
            select jsonb_agg(jsonb_build_object(
                'version', version.version,
                'status', version.status,
                'reason', version.reason,
                'publishedAt', version.published_at
            ) order by version.version desc)
            from public.kcp_schedule_versions version
            where version.group_id = group_record.id
        ), '[]'::jsonb),
        'openCovers', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', cover.id,
                'tripId', cover.trip_id,
                'status', cover.status,
                'stage', cover.escalation_stage,
                'createdAt', cover.created_at
            ) order by cover.created_at desc)
            from public.kcp_cover_requests cover
            where cover.group_id = group_record.id and cover.status in ('open','accepted')
        ), '[]'::jsonb),
        'recentAudit', coalesce((
            select jsonb_agg(jsonb_build_object(
                'action', audit.action,
                'entityType', audit.entity_type,
                'occurredAt', audit.occurred_at
            ) order by audit.occurred_at desc)
            from (
                select * from public.kcp_audit_events
                where group_id = group_record.id
                order by occurred_at desc
                limit 50
            ) audit
        ), '[]'::jsonb),
        'clients', coalesce((
            select jsonb_agg(jsonb_build_object(
                'build', heartbeat.build_version,
                'cache', heartbeat.cache_version,
                'platform', heartbeat.platform,
                'lastSeenAt', heartbeat.last_seen_at
            ) order by heartbeat.last_seen_at desc)
            from (
                select distinct on (user_id) *
                from public.kcp_client_heartbeats
                where active_group_id = group_record.id
                order by user_id, last_seen_at desc
            ) heartbeat
        ), '[]'::jsonb)
      ) into result;
    return result;
end;
$$;

create or replace function public.kcp_support_open_break_glass(
    p_group_id uuid,
    p_reason text,
    p_minutes integer default 10
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result_id uuid;
begin
    if not public.kcp_is_platform_admin('support_admin') then
        raise exception 'Platform support role required';
    end if;
    if length(trim(coalesce(p_reason,''))) < 10 then
        raise exception 'Provide a specific support reason of at least 10 characters';
    end if;
    if p_minutes < 1 or p_minutes > 30 then raise exception 'Break-glass duration must be 1 to 30 minutes'; end if;
    if not exists (select 1 from public.kcp_groups where id = p_group_id) then raise exception 'Group not found'; end if;

    insert into public.kcp_break_glass_events(
        platform_admin_id, group_id, resource_type, resource_id,
        reason, opened_at, expires_at, resource_scope
    ) values (
        auth.uid(), p_group_id, 'group_sensitive_data', p_group_id::text,
        trim(p_reason), now(), now() + make_interval(mins => p_minutes), 'group'
    ) returning id into result_id;

    perform public.kcp_write_platform_audit(
        'break_glass_opened', 'group', p_group_id::text,
        jsonb_build_object('eventId',result_id,'reason',trim(p_reason),'minutes',p_minutes)
    );
    return result_id;
end;
$$;

create or replace function public.kcp_support_has_break_glass(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select public.kcp_is_platform_admin('support_admin') and exists (
        select 1 from public.kcp_break_glass_events event
        where event.platform_admin_id = auth.uid()
          and event.group_id = p_group_id
          and event.closed_at is null
          and event.expires_at > now()
    );
$$;

create or replace function public.kcp_support_group_sensitive_details(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result jsonb;
begin
    if not public.kcp_support_has_break_glass(p_group_id) then
        raise exception 'Open an audited break-glass session first';
    end if;

    select jsonb_build_object(
        'members', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userId', member.user_id,
                'name', member.parent_name,
                'phone', coalesce(member.phone, profile.phone),
                'email', profile.account_email,
                'role', member.role,
                'status', member.status
            ) order by member.parent_name)
            from public.kcp_memberships member
            left join public.kcp_profiles profile on profile.id = member.user_id
            where member.group_id = p_group_id
        ), '[]'::jsonb),
        'children', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', child.id,
                'name', child.name,
                'pickupTag', child.pickup_tag,
                'pickupAddress', safety.pickup_address,
                'dropoffAddress', safety.dropoff_address,
                'emergencyContact', safety.emergency_contact_name,
                'emergencyPhone', safety.emergency_contact_phone,
                'criticalAlert', safety.critical_alert
            ) order by child.name)
            from public.kcp_children child
            left join public.kcp_child_safety_profiles safety on safety.child_id = child.id
            where child.group_id = p_group_id and child.status = 'active'
        ), '[]'::jsonb)
    ) into result;

    perform public.kcp_write_platform_audit(
        'break_glass_data_viewed', 'group', p_group_id::text,
        jsonb_build_object('scope','members_and_children')
    );
    return result;
end;
$$;

create or replace function public.kcp_support_close_break_glass(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    event public.kcp_break_glass_events;
begin
    select * into event from public.kcp_break_glass_events where id = p_event_id for update;
    if not found or event.platform_admin_id <> auth.uid() then raise exception 'Break-glass session not found'; end if;
    update public.kcp_break_glass_events
       set closed_at = coalesce(closed_at,now()), closed_by = auth.uid()
     where id = event.id;
    perform public.kcp_write_platform_audit(
        'break_glass_closed','group',event.group_id::text,jsonb_build_object('eventId',event.id)
    );
end;
$$;

create or replace function public.kcp_support_set_group_status(
    p_group_id uuid,
    p_status text,
    p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin('support_admin') then raise exception 'Platform support role required'; end if;
    if p_status not in ('active','archived') then raise exception 'Group status must be Active or Archived'; end if;
    if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Provide a support reason'; end if;
    update public.kcp_groups set status = p_status, updated_at = now() where id = p_group_id;
    if not found then raise exception 'Group not found'; end if;
    perform public.kcp_write_platform_audit(
        'support_group_status_changed','group',p_group_id::text,
        jsonb_build_object('status',p_status,'reason',trim(p_reason))
    );
end;
$$;

create or replace function public.kcp_support_transfer_ownership(
    p_group_id uuid,
    p_new_owner_user_id uuid,
    p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    old_owner uuid;
begin
    if not public.kcp_is_platform_admin('support_admin') then raise exception 'Platform support role required'; end if;
    if length(trim(coalesce(p_reason,''))) < 10 then raise exception 'Provide a detailed ownership-transfer reason'; end if;
    select member.user_id into old_owner
    from public.kcp_memberships member
    where member.group_id = p_group_id and member.role = 'owner' and member.status = 'active'
    for update;
    if old_owner is null then raise exception 'Active Owner not found'; end if;
    if not exists (
        select 1 from public.kcp_memberships member
        where member.group_id = p_group_id and member.user_id = p_new_owner_user_id and member.status = 'active'
    ) then raise exception 'New Owner must already be an active group member'; end if;
    if old_owner = p_new_owner_user_id then raise exception 'This member is already the Owner'; end if;

    set constraints kcp_memberships_single_owner_check deferred;
    update public.kcp_memberships
       set role = 'admin', updated_at = now()
     where group_id = p_group_id and user_id = old_owner;
    update public.kcp_memberships
       set role = 'owner', updated_at = now()
     where group_id = p_group_id and user_id = p_new_owner_user_id;

    perform public.kcp_write_platform_audit(
        'support_ownership_transferred','group',p_group_id::text,
        jsonb_build_object('oldOwner',old_owner,'newOwner',p_new_owner_user_id,'reason',trim(p_reason))
    );
    perform public.kcp_write_audit(
        p_group_id,'ownership_transferred_by_support','group',p_group_id::text,
        jsonb_build_object('oldOwner',old_owner,'newOwner',p_new_owner_user_id,'reason',trim(p_reason))
    );
end;
$$;

create or replace function public.kcp_support_reissue_invitation(
    p_invitation_id uuid,
    p_days integer default 14
)
returns table(token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    invitation public.kcp_invitations;
    new_token text;
begin
    if not public.kcp_is_platform_admin('support_admin') then raise exception 'Platform support role required'; end if;
    if p_days < 1 or p_days > 30 then raise exception 'Invitation expiry must be 1 to 30 days'; end if;
    select * into invitation from public.kcp_invitations where id = p_invitation_id for update;
    if not found then raise exception 'Invitation not found'; end if;
    if invitation.status = 'accepted' then raise exception 'Accepted invitations cannot be reissued'; end if;

    new_token := public.kcp_random_invite_token();
    update public.kcp_invitations
       set token = new_token, status = 'pending', expires_at = now() + make_interval(days => p_days),
           accepted_by = null, accepted_at = null
     where id = invitation.id;

    perform public.kcp_write_platform_audit(
        'support_invitation_reissued','invitation',invitation.id::text,
        jsonb_build_object('groupId',invitation.group_id,'days',p_days)
    );
    return query select new_token, now() + make_interval(days => p_days);
end;
$$;

create or replace function public.kcp_support_errors(
    p_reference_code text default null,
    p_group_id uuid default null,
    p_limit integer default 100
)
returns table(
    reference_code text,
    group_id uuid,
    user_id uuid,
    client_version text,
    operation text,
    safe_metadata jsonb,
    created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin('support_admin') then raise exception 'Platform support role required'; end if;
    return query
    select error.reference_code, error.group_id, error.user_id, error.client_version,
           error.operation, error.safe_metadata, error.created_at
    from public.kcp_client_error_events error
    where (nullif(trim(p_reference_code),'') is null or error.reference_code = upper(trim(p_reference_code)))
      and (p_group_id is null or error.group_id = p_group_id)
    order by error.created_at desc
    limit least(greatest(p_limit,1),500);
end;
$$;

revoke all on function public.kcp_mask_support_text(text) from public, anon, authenticated;
revoke all on function public.kcp_register_client_heartbeat(text,text,text,text,text,uuid) from public, anon;
revoke all on function public.kcp_support_me() from public, anon;
revoke all on function public.kcp_support_dashboard() from public, anon;
revoke all on function public.kcp_support_groups(text,text,integer,integer) from public, anon;
revoke all on function public.kcp_support_group_details(uuid) from public, anon;
revoke all on function public.kcp_support_open_break_glass(uuid,text,integer) from public, anon;
revoke all on function public.kcp_support_has_break_glass(uuid) from public, anon;
revoke all on function public.kcp_support_group_sensitive_details(uuid) from public, anon;
revoke all on function public.kcp_support_close_break_glass(uuid) from public, anon;
revoke all on function public.kcp_support_set_group_status(uuid,text,text) from public, anon;
revoke all on function public.kcp_support_transfer_ownership(uuid,uuid,text) from public, anon;
revoke all on function public.kcp_support_reissue_invitation(uuid,integer) from public, anon;
revoke all on function public.kcp_support_errors(text,uuid,integer) from public, anon;

grant execute on function public.kcp_register_client_heartbeat(text,text,text,text,text,uuid) to authenticated;
grant execute on function public.kcp_support_me() to authenticated;
grant execute on function public.kcp_support_dashboard() to authenticated;
grant execute on function public.kcp_support_groups(text,text,integer,integer) to authenticated;
grant execute on function public.kcp_support_group_details(uuid) to authenticated;
grant execute on function public.kcp_support_open_break_glass(uuid,text,integer) to authenticated;
grant execute on function public.kcp_support_has_break_glass(uuid) to authenticated;
grant execute on function public.kcp_support_group_sensitive_details(uuid) to authenticated;
grant execute on function public.kcp_support_close_break_glass(uuid) to authenticated;
grant execute on function public.kcp_support_set_group_status(uuid,text,text) to authenticated;
grant execute on function public.kcp_support_transfer_ownership(uuid,uuid,text) to authenticated;
grant execute on function public.kcp_support_reissue_invitation(uuid,integer) to authenticated;
grant execute on function public.kcp_support_errors(text,uuid,integer) to authenticated;

commit;
