begin;

-- ---------------------------------------------------------------------------
-- Durable pilot access, seeded-owner recovery and cover withdrawal
-- ---------------------------------------------------------------------------

alter table public.kcp_cover_requests
    add column if not exists cancelled_at timestamptz;

alter table public.kcp_cover_requests
    add column if not exists cancelled_by uuid references public.kcp_profiles(id);

alter table public.kcp_cover_requests
    add column if not exists cancellation_reason text;

create table if not exists public.kcp_device_links (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    user_id uuid not null references public.kcp_profiles(id) on delete cascade,
    secret_hash text not null unique,
    label text not null default 'Remembered device',
    created_at timestamptz not null default now(),
    last_used_at timestamptz,
    revoked_at timestamptz
);

create index if not exists kcp_device_links_user_group_idx
    on public.kcp_device_links(user_id, group_id, revoked_at);

create table if not exists public.kcp_recovery_challenges (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    roster_parent_name text not null,
    claimed_user_id uuid not null references public.kcp_profiles(id),
    secret_hash text not null unique,
    issued_at timestamptz not null default now(),
    expires_at timestamptz not null,
    used_at timestamptz,
    used_by uuid references public.kcp_profiles(id)
);

create index if not exists kcp_recovery_challenges_lookup_idx
    on public.kcp_recovery_challenges(group_id, roster_parent_name, expires_at)
    where used_at is null;

alter table public.kcp_device_links enable row level security;
alter table public.kcp_recovery_challenges enable row level security;

-- No direct table policies are intentionally created. Device secrets and
-- challenge hashes are accessible only through the SECURITY DEFINER RPCs below.
revoke all on public.kcp_device_links from public, anon, authenticated;
revoke all on public.kcp_recovery_challenges from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Internal helper: move one group membership to a replacement Auth identity.
-- Historical audit actors remain unchanged; operational ownership and active
-- records move to the replacement identity.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_transfer_group_membership(
    p_group_id uuid,
    p_source_user_id uuid,
    p_target_user_id uuid,
    p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_source_profile public.kcp_profiles;
    v_source_membership public.kcp_memberships;
begin
    if p_source_user_id is null or p_target_user_id is null then
        raise exception 'Both source and target users are required';
    end if;

    if p_source_user_id = p_target_user_id then
        return;
    end if;

    select p.*
      into v_source_profile
      from public.kcp_profiles p
     where p.id = p_source_user_id;
    if not found then
        raise exception 'The previous profile no longer exists';
    end if;

    select m.*
      into v_source_membership
      from public.kcp_memberships m
     where m.group_id = p_group_id
       and m.user_id = p_source_user_id
       and m.status = 'active'
     for update;
    if not found then
        raise exception 'The previous active group membership no longer exists';
    end if;

    if exists (
        select 1
          from public.kcp_memberships m
         where m.group_id = p_group_id
           and m.user_id = p_target_user_id
           and m.status = 'active'
    ) then
        raise exception 'The current account already has an active membership in this group';
    end if;

    insert into public.kcp_profiles(id, display_name, phone)
    values (
        p_target_user_id,
        v_source_profile.display_name,
        v_source_profile.phone
    )
    on conflict (id) do update
       set display_name = excluded.display_name,
           phone = coalesce(excluded.phone, public.kcp_profiles.phone),
           updated_at = now();

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade,
        role, status, invited_by, joined_at, updated_at
    ) values (
        v_source_membership.group_id,
        p_target_user_id,
        v_source_membership.parent_name,
        v_source_membership.phone,
        v_source_membership.child_name,
        v_source_membership.grade,
        v_source_membership.role,
        'active',
        v_source_membership.invited_by,
        coalesce(v_source_membership.joined_at, now()),
        now()
    )
    on conflict (group_id, user_id) do update
       set parent_name = excluded.parent_name,
           phone = excluded.phone,
           child_name = excluded.child_name,
           grade = excluded.grade,
           role = excluded.role,
           status = 'active',
           invited_by = excluded.invited_by,
           joined_at = coalesce(public.kcp_memberships.joined_at, excluded.joined_at),
           updated_at = now();

    -- Avoid the partial unique index if a half-completed target account already
    -- submitted a request before recovery.
    update public.kcp_constraint_requests r
       set status = 'withdrawn',
           reviewed_at = now(),
           review_note = concat_ws(' ', r.review_note, 'Superseded during account recovery.')
     where r.group_id = p_group_id
       and r.user_id = p_target_user_id
       and r.status = 'pending';

    insert into public.kcp_constraints(
        group_id, user_id, drop_weekdays, pickup_weekdays, notes,
        version, effective_from, updated_by, updated_at
    )
    select
        c.group_id,
        p_target_user_id,
        c.drop_weekdays,
        c.pickup_weekdays,
        c.notes,
        c.version,
        c.effective_from,
        p_target_user_id,
        now()
    from public.kcp_constraints c
    where c.group_id = p_group_id
      and c.user_id = p_source_user_id
    on conflict (group_id, user_id) do update
       set drop_weekdays = excluded.drop_weekdays,
           pickup_weekdays = excluded.pickup_weekdays,
           notes = excluded.notes,
           version = greatest(public.kcp_constraints.version, excluded.version),
           effective_from = excluded.effective_from,
           updated_by = p_target_user_id,
           updated_at = now();

    delete from public.kcp_constraints c
     where c.group_id = p_group_id
       and c.user_id = p_source_user_id;

    update public.kcp_constraint_requests r
       set user_id = p_target_user_id
     where r.group_id = p_group_id
       and r.user_id = p_source_user_id;

    update public.kcp_trips t
       set scheduled_driver_id = p_target_user_id
     where t.group_id = p_group_id
       and t.scheduled_driver_id = p_source_user_id;

    update public.kcp_trips t
       set actual_driver_id = p_target_user_id
     where t.group_id = p_group_id
       and t.actual_driver_id = p_source_user_id;

    update public.kcp_cover_requests r
       set requested_by = p_target_user_id
     where r.group_id = p_group_id
       and r.requested_by = p_source_user_id;

    update public.kcp_cover_requests r
       set accepted_by = p_target_user_id
     where r.group_id = p_group_id
       and r.accepted_by = p_source_user_id;

    update public.kcp_cover_requests r
       set cancelled_by = p_target_user_id
     where r.group_id = p_group_id
       and r.cancelled_by = p_source_user_id;

    update public.kcp_points_ledger p
       set user_id = p_target_user_id
     where p.group_id = p_group_id
       and p.user_id = p_source_user_id;

    update public.kcp_roster_slots r
       set claimed_user_id = p_target_user_id,
           updated_at = now()
     where r.group_id = p_group_id
       and r.claimed_user_id = p_source_user_id;

    update public.kcp_invitations i
       set accepted_by = p_target_user_id
     where i.group_id = p_group_id
       and i.accepted_by = p_source_user_id;

    update public.kcp_groups g
       set created_by = p_target_user_id,
           updated_at = now()
     where g.id = p_group_id
       and g.created_by = p_source_user_id;

    update public.kcp_group_snapshots s
       set updated_by = p_target_user_id,
           updated_at = now()
     where s.group_id = p_group_id
       and s.updated_by = p_source_user_id;

    update public.kcp_memberships m
       set status = 'removed',
           updated_at = now()
     where m.group_id = p_group_id
       and m.user_id = p_source_user_id;

    insert into public.kcp_audit_events(
        group_id, actor_id, action, entity_type, entity_id, details
    ) values (
        p_group_id,
        p_target_user_id,
        'membership_identity_transferred',
        'membership',
        p_target_user_id::text,
        jsonb_build_object(
            'sourceUserId', p_source_user_id,
            'targetUserId', p_target_user_id,
            'parentName', v_source_membership.parent_name,
            'role', v_source_membership.role,
            'reason', coalesce(p_reason, 'account recovery')
        )
    );
end;
$$;

revoke all on function public.kcp_transfer_group_membership(uuid,uuid,uuid,text)
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Remembered-device credential. The plaintext secret is returned only once;
-- the database stores a SHA-256 hash.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_create_device_link(
    p_group_id uuid,
    p_label text default 'Remembered device'
)
returns table(group_id uuid, device_secret text)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_secret text;
    v_secret_hash text;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;

    v_secret := upper(
        replace(gen_random_uuid()::text, '-', '') ||
        replace(gen_random_uuid()::text, '-', '')
    );
    v_secret_hash := encode(extensions.digest(v_secret, 'sha256'), 'hex');

    insert into public.kcp_device_links(
        group_id, user_id, secret_hash, label
    ) values (
        p_group_id,
        auth.uid(),
        v_secret_hash,
        coalesce(nullif(trim(p_label), ''), 'Remembered device')
    );

    -- Retain at most five active device links for one user/group.
    update public.kcp_device_links dl
       set revoked_at = now()
     where dl.id in (
         select old.id
           from public.kcp_device_links old
          where old.group_id = p_group_id
            and old.user_id = auth.uid()
            and old.revoked_at is null
          order by old.created_at desc
          offset 5
     );

    return query select p_group_id, v_secret;
end;
$$;

create or replace function public.kcp_restore_device_link(p_secret text)
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_link public.kcp_device_links;
    v_hash text;
    v_source_user_id uuid;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if nullif(trim(p_secret), '') is null then raise exception 'Device recovery secret is required'; end if;

    v_hash := encode(
        extensions.digest(upper(regexp_replace(trim(p_secret), '[^A-Z0-9]', '', 'g')), 'sha256'),
        'hex'
    );

    select dl.*
      into v_link
      from public.kcp_device_links dl
     where dl.secret_hash = v_hash
       and dl.revoked_at is null
     for update;
    if not found then
        raise exception 'This remembered-device credential is invalid or revoked';
    end if;

    v_source_user_id := v_link.user_id;

    if v_source_user_id <> auth.uid() then
        perform public.kcp_transfer_group_membership(
            v_link.group_id,
            v_source_user_id,
            auth.uid(),
            'remembered device recovery'
        );

        update public.kcp_device_links dl
           set revoked_at = now()
         where dl.group_id = v_link.group_id
           and dl.user_id = v_source_user_id
           and dl.id <> v_link.id
           and dl.revoked_at is null;
    end if;

    update public.kcp_device_links dl
       set user_id = auth.uid(),
           last_used_at = now()
     where dl.id = v_link.id;

    return query
    select g.id, g.code
      from public.kcp_groups g
     where g.id = v_link.group_id;
end;
$$;

revoke all on function public.kcp_create_device_link(uuid,text) from public, anon;
revoke all on function public.kcp_restore_device_link(text) from public, anon;
grant execute on function public.kcp_create_device_link(uuid,text) to authenticated;
grant execute on function public.kcp_restore_device_link(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Seeded pilot status and project-owner-issued one-time recovery code.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_seeded_pilot_status()
returns table(
    group_id uuid,
    group_code text,
    group_name text,
    roster_parent_name text,
    claim_state text,
    claimed_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select
        g.id,
        g.code,
        g.name,
        r.parent_name,
        case
            when r.claimed_user_id is null then 'available'
            when r.claimed_user_id = auth.uid() then 'current_user'
            else 'another_device'
        end,
        r.claimed_at
    from public.kcp_groups g
    join public.kcp_roster_slots r on r.group_id = g.id
    where g.code = 'KCP-BASIS-2026-27'
      and lower(r.parent_name) = 'kiran'
    limit 1;
$$;

create or replace function public.kcp_issue_roster_recovery_code(
    p_group_code text,
    p_parent_name text,
    p_valid_minutes integer default 30
)
returns table(recovery_code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_group_id uuid;
    v_claimed_user_id uuid;
    v_code text;
    v_hash text;
    v_expires_at timestamptz;
begin
    if p_valid_minutes not between 5 and 1440 then
        raise exception 'Recovery code lifetime must be between 5 and 1440 minutes';
    end if;

    select g.id, r.claimed_user_id
      into v_group_id, v_claimed_user_id
      from public.kcp_groups g
      join public.kcp_roster_slots r on r.group_id = g.id
     where g.code = upper(trim(p_group_code))
       and lower(r.parent_name) = lower(trim(p_parent_name))
     for update of r;
    if not found then raise exception 'Group or roster entry was not found'; end if;
    if v_claimed_user_id is null then
        raise exception 'This roster entry is not claimed and does not require recovery';
    end if;

    update public.kcp_recovery_challenges c
       set used_at = coalesce(c.used_at, now())
     where c.group_id = v_group_id
       and lower(c.roster_parent_name) = lower(trim(p_parent_name))
       and c.used_at is null;

    v_code := 'REC-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
        || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    v_hash := encode(
        extensions.digest(upper(regexp_replace(v_code, '[^A-Z0-9]', '', 'g')), 'sha256'),
        'hex'
    );
    v_expires_at := now() + make_interval(mins => p_valid_minutes);

    insert into public.kcp_recovery_challenges(
        group_id, roster_parent_name, claimed_user_id,
        secret_hash, expires_at
    ) values (
        v_group_id,
        trim(p_parent_name),
        v_claimed_user_id,
        v_hash,
        v_expires_at
    );

    insert into public.kcp_audit_events(
        group_id, actor_id, action, entity_type, entity_id, details
    ) values (
        v_group_id,
        null,
        'roster_recovery_code_issued',
        'roster_slot',
        trim(p_parent_name),
        jsonb_build_object('expiresAt', v_expires_at)
    );

    return query select v_code, v_expires_at;
end;
$$;

create or replace function public.kcp_recover_seeded_roster(
    p_group_code text,
    p_parent_name text,
    p_recovery_code text
)
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_group public.kcp_groups;
    v_slot public.kcp_roster_slots;
    v_profile public.kcp_profiles;
    v_challenge public.kcp_recovery_challenges;
    v_hash text;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select p.* into v_profile
    from public.kcp_profiles p
    where p.id = auth.uid();
    if not found then raise exception 'Complete the parent profile first'; end if;

    if lower(trim(v_profile.display_name)) <> lower(trim(p_parent_name)) then
        raise exception 'The current parent profile does not match the roster entry';
    end if;

    select g.* into v_group
    from public.kcp_groups g
    where g.code = upper(trim(p_group_code))
    for update;
    if not found then raise exception 'Carpool group was not found'; end if;

    select r.* into v_slot
    from public.kcp_roster_slots r
    where r.group_id = v_group.id
      and lower(r.parent_name) = lower(trim(p_parent_name))
    for update;
    if not found then raise exception 'Roster entry was not found'; end if;
    if v_slot.claimed_user_id is null then
        raise exception 'This roster entry is not claimed; load it normally instead';
    end if;

    v_hash := encode(
        extensions.digest(
            upper(regexp_replace(trim(p_recovery_code), '[^A-Z0-9]', '', 'g')),
            'sha256'
        ),
        'hex'
    );

    select c.* into v_challenge
    from public.kcp_recovery_challenges c
    where c.group_id = v_group.id
      and lower(c.roster_parent_name) = lower(trim(p_parent_name))
      and c.secret_hash = v_hash
      and c.used_at is null
      and c.expires_at > now()
    for update;
    if not found then
        raise exception 'Recovery code is invalid, expired, or already used';
    end if;

    if v_slot.claimed_user_id <> auth.uid() then
        perform public.kcp_transfer_group_membership(
            v_group.id,
            v_slot.claimed_user_id,
            auth.uid(),
            'one-time roster recovery code'
        );
    end if;

    update public.kcp_recovery_challenges c
       set used_at = now(),
           used_by = auth.uid()
     where c.id = v_challenge.id;

    insert into public.kcp_audit_events(
        group_id, actor_id, action, entity_type, entity_id, details
    ) values (
        v_group.id,
        auth.uid(),
        'seeded_roster_recovered',
        'roster_slot',
        v_slot.parent_name,
        jsonb_build_object(
            'previousUserId', v_slot.claimed_user_id,
            'newUserId', auth.uid()
        )
    );

    return query select v_group.id, v_group.code;
end;
$$;

revoke all on function public.kcp_seeded_pilot_status() from public, anon;
revoke all on function public.kcp_issue_roster_recovery_code(text,text,integer)
from public, anon, authenticated;
revoke all on function public.kcp_recover_seeded_roster(text,text,text)
from public, anon;
grant execute on function public.kcp_seeded_pilot_status() to authenticated;
grant execute on function public.kcp_issue_roster_recovery_code(text,text,integer) to service_role;
grant execute on function public.kcp_recover_seeded_roster(text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Invitation acceptance doubles as a manual recovery path. An accepted invite
-- may be entered again with the same parent name/phone to move that one group
-- membership to a replacement anonymous Auth identity.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_accept_invitation(
    p_token text,
    p_parent_name text,
    p_phone text default null
)
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
#variable_conflict use_column
declare
    v_inv public.kcp_invitations;
    v_normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
    v_profile public.kcp_profiles;
    v_has_seeded_slot boolean := false;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select i.* into v_inv
    from public.kcp_invitations i
    where i.token = upper(trim(p_token))
    for update;
    if not found then raise exception 'Invitation code was not found'; end if;

    if lower(trim(v_inv.invited_parent_name)) <> lower(trim(p_parent_name)) then
        raise exception 'Parent name does not match the invitation';
    end if;
    if v_inv.phone is not null and v_normalized_phone is distinct from v_inv.phone then
        raise exception 'Phone number does not match the invitation';
    end if;

    insert into public.kcp_profiles(id, display_name, phone)
    values (
        auth.uid(),
        trim(p_parent_name),
        coalesce(v_normalized_phone, v_inv.phone)
    )
    on conflict (id) do update
       set display_name = excluded.display_name,
           phone = coalesce(excluded.phone, public.kcp_profiles.phone),
           updated_at = now()
    returning * into v_profile;

    if v_inv.status = 'accepted' then
        if v_inv.accepted_by is null then
            raise exception 'Accepted invitation has no linked member; ask an admin to issue a new invitation';
        end if;

        if v_inv.accepted_by <> auth.uid() then
            perform public.kcp_transfer_group_membership(
                v_inv.group_id,
                v_inv.accepted_by,
                auth.uid(),
                'accepted invitation reused for account recovery'
            );
        end if;

        update public.kcp_invitations i
           set accepted_by = auth.uid(),
               accepted_at = now()
         where i.id = v_inv.id;

        perform public.kcp_write_audit(
            v_inv.group_id,
            'invitation_access_restored',
            'invitation',
            v_inv.id::text,
            jsonb_build_object('parentName', v_profile.display_name)
        );

        return query
        select g.id, g.code
        from public.kcp_groups g
        where g.id = v_inv.group_id;
        return;
    end if;

    if v_inv.status <> 'pending' then
        raise exception 'This invitation is no longer available';
    end if;
    if v_inv.expires_at <= now() then
        update public.kcp_invitations i
           set status = 'expired'
         where i.id = v_inv.id;
        raise exception 'This invitation has expired';
    end if;

    select exists (
        select 1
        from public.kcp_roster_slots r
        where r.group_id = v_inv.group_id
          and lower(r.parent_name) = lower(v_inv.invited_parent_name)
    ) into v_has_seeded_slot;

    if v_has_seeded_slot then
        perform public.kcp_bind_seeded_roster(
            v_inv.group_id,
            auth.uid(),
            v_inv.invited_parent_name,
            false
        );
    else
        insert into public.kcp_memberships(
            group_id, user_id, parent_name, phone, child_name, grade, role,
            status, invited_by, joined_at
        ) values (
            v_inv.group_id,
            auth.uid(),
            v_profile.display_name,
            v_profile.phone,
            v_inv.child_name,
            v_inv.grade,
            v_inv.role,
            'active',
            v_inv.invited_by,
            now()
        )
        on conflict (group_id, user_id) do update
           set parent_name = excluded.parent_name,
               phone = excluded.phone,
               child_name = excluded.child_name,
               grade = excluded.grade,
               role = excluded.role,
               status = 'active',
               joined_at = coalesce(public.kcp_memberships.joined_at, now()),
               updated_at = now();

        insert into public.kcp_constraints(
            group_id, user_id, updated_by, effective_from
        ) values (
            v_inv.group_id,
            auth.uid(),
            auth.uid(),
            current_date
        )
        on conflict (group_id, user_id) do nothing;
    end if;

    update public.kcp_invitations i
       set status = 'accepted',
           accepted_by = auth.uid(),
           accepted_at = now()
     where i.id = v_inv.id;

    perform public.kcp_write_audit(
        v_inv.group_id,
        'invitation_accepted',
        'invitation',
        v_inv.id::text,
        jsonb_build_object('parentName', v_profile.display_name)
    );

    return query
    select g.id, g.code
    from public.kcp_groups g
    where g.id = v_inv.group_id;
end;
$$;

revoke all on function public.kcp_accept_invitation(text,text,text) from public, anon;
grant execute on function public.kcp_accept_invitation(text,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Withdraw an open cover request and return the trip to its assigned driver.
-- Once another parent has accepted, the requester may not silently revoke it.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_withdraw_cover(
    p_request_id uuid,
    p_reason text default 'Driver is available again'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
#variable_conflict use_variable
declare
    v_request public.kcp_cover_requests;
    v_trip public.kcp_trips;
    v_restored_status text;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select r.* into v_request
    from public.kcp_cover_requests r
    where r.id = p_request_id
    for update;
    if not found then raise exception 'Cover request was not found'; end if;

    if v_request.status <> 'open' then
        raise exception 'Only an open cover request can be withdrawn';
    end if;
    if v_request.requested_by <> auth.uid()
       and not public.kcp_is_admin(v_request.group_id) then
        raise exception 'Only the requester or a group admin can withdraw this cover request';
    end if;

    select t.* into v_trip
    from public.kcp_trips t
    where t.id = v_request.trip_id
    for update;
    if not found then raise exception 'Trip was not found'; end if;
    if v_trip.status <> 'cover_requested' then
        raise exception 'The trip is no longer waiting for coverage';
    end if;

    v_restored_status := case
        when v_trip.scheduled_driver_id is null then 'coverage_needed'
        else 'scheduled'
    end;

    update public.kcp_cover_requests r
       set status = 'cancelled',
           cancelled_at = now(),
           cancelled_by = auth.uid(),
           cancellation_reason = coalesce(nullif(trim(p_reason), ''), 'Driver is available again')
     where r.id = v_request.id;

    update public.kcp_trips t
       set status = v_restored_status,
           actual_driver_id = null,
           actual_driver_name = null,
           volunteer_assignment = false
     where t.id = v_trip.id;

    perform public.kcp_write_audit(
        v_request.group_id,
        'cover_request_withdrawn',
        'cover_request',
        v_request.id::text,
        jsonb_build_object(
            'tripId', v_trip.id,
            'restoredStatus', v_restored_status,
            'reason', coalesce(nullif(trim(p_reason), ''), 'Driver is available again')
        )
    );

    return v_trip.id;
end;
$$;

revoke all on function public.kcp_withdraw_cover(uuid,text) from public, anon;
grant execute on function public.kcp_withdraw_cover(uuid,text) to authenticated;

commit;
