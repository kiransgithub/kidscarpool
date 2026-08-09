begin;

-- ---------------------------------------------------------------------------
-- Role-adaptive invitations
-- ---------------------------------------------------------------------------

alter table public.kcp_memberships
    alter column child_name drop not null,
    alter column grade drop not null;

alter table public.kcp_invitations
    alter column child_name drop not null,
    alter column grade drop not null,
    add column if not exists email text,
    add column if not exists can_drive boolean not null default true,
    add column if not exists updated_at timestamptz not null default now(),
    add column if not exists revoked_at timestamptz,
    add column if not exists revoked_by uuid references public.kcp_profiles(id) on delete set null;

-- Viewer and childless Admin memberships intentionally have no grade. Keep the
-- legacy zero default only when a membership actually includes a child.
create or replace function public.kcp_default_legacy_membership_grade()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
    if nullif(trim(new.child_name), '') is not null then
        new.grade := coalesce(new.grade, 0);
    end if;
    return new;
end;
$$;

create unique index if not exists kcp_pending_invitation_email_per_group
    on public.kcp_invitations(group_id, lower(email))
    where email is not null and status = 'pending';

create or replace function public.kcp_create_invitation_v2(
    p_group_id uuid,
    p_member_name text,
    p_role text,
    p_email text default null,
    p_phone text default null,
    p_child_name text default null,
    p_grade integer default null,
    p_can_drive boolean default true,
    p_expires_in_days integer default 14
)
returns public.kcp_invitations
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result public.kcp_invitations;
    normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
    normalized_email text := nullif(lower(trim(coalesce(p_email,''))), '');
    normalized_child text := nullif(trim(coalesce(p_child_name,'')), '');
    effective_can_drive boolean;
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;
    if p_role not in ('admin','parent','viewer') then raise exception 'Choose Admin, Parent, or Viewer'; end if;
    if length(trim(coalesce(p_member_name,''))) < 1 then raise exception 'Member name is required'; end if;
    if p_role = 'parent' and normalized_child is null then raise exception 'A Parent invitation requires a child or rider'; end if;
    if p_grade is not null and (p_grade < 0 or p_grade > 12) then raise exception 'Grade must be between 0 and 12'; end if;
    if p_expires_in_days < 1 or p_expires_in_days > 90 then raise exception 'Invitation expiry must be between 1 and 90 days'; end if;

    effective_can_drive := case when p_role = 'viewer' then false else coalesce(p_can_drive, false) end;

    if normalized_phone is not null and exists (
        select 1 from public.kcp_memberships member
        where member.group_id = p_group_id
          and member.phone = normalized_phone
          and member.status = 'active'
    ) then
        raise exception 'That phone number is already associated with an active member';
    end if;

    if normalized_email is not null and exists (
        select 1
        from public.kcp_memberships member
        join public.kcp_profiles profile on profile.id = member.user_id
        where member.group_id = p_group_id
          and member.status = 'active'
          and lower(profile.account_email) = normalized_email
    ) then
        raise exception 'That email is already associated with an active member';
    end if;

    insert into public.kcp_invitations(
        group_id, token, invited_parent_name, email, phone,
        child_name, grade, role, can_drive, status, invited_by,
        created_at, updated_at, expires_at
    ) values (
        p_group_id, public.kcp_random_invite_token(), trim(p_member_name),
        normalized_email, normalized_phone, normalized_child, p_grade,
        p_role, effective_can_drive, 'pending', auth.uid(),
        now(), now(), now() + make_interval(days => p_expires_in_days)
    ) returning * into result;

    perform public.kcp_write_audit(
        p_group_id, 'invitation_created', 'invitation', result.id::text,
        jsonb_build_object(
            'memberName', result.invited_parent_name,
            'role', result.role,
            'canDrive', result.can_drive,
            'childIncluded', result.child_name is not null,
            'emailBound', result.email is not null
        )
    );

    return result;
end;
$$;

create or replace function public.kcp_invitation_preview(p_token text)
returns table(
    group_id uuid,
    group_name text,
    group_kind text,
    member_name text,
    role text,
    child_name text,
    can_drive boolean,
    email_bound boolean,
    expires_at timestamptz,
    status text
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    return query
    select invitation.group_id, group_row.name, group_row.group_kind,
           invitation.invited_parent_name, invitation.role,
           invitation.child_name, invitation.can_drive,
           invitation.email is not null, invitation.expires_at,
           case
               when invitation.status = 'pending' and invitation.expires_at <= now() then 'expired'
               else invitation.status
           end
    from public.kcp_invitations invitation
    join public.kcp_groups group_row on group_row.id = invitation.group_id
    where invitation.token = upper(trim(p_token))
    limit 1;
end;
$$;

create or replace function public.kcp_accept_invitation(
    p_token text,
    p_parent_name text,
    p_phone text default null
)
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
#variable_conflict use_column
declare
    invitation public.kcp_invitations;
    normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
    profile public.kcp_profiles;
    auth_user auth.users;
    has_seeded_slot boolean := false;
    participant_id uuid;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into invitation
    from public.kcp_invitations
    where token = upper(trim(p_token))
    for update;

    if not found then raise exception 'Invitation code was not found'; end if;
    if invitation.status <> 'pending' then raise exception 'This invitation is no longer available'; end if;
    if invitation.expires_at <= now() then
        update public.kcp_invitations set status = 'expired', updated_at = now() where id = invitation.id;
        raise exception 'This invitation has expired';
    end if;
    if lower(trim(invitation.invited_parent_name)) <> lower(trim(p_parent_name)) then
        raise exception 'Member name does not match the invitation';
    end if;
    if invitation.phone is not null and normalized_phone is distinct from invitation.phone then
        raise exception 'Phone number does not match the invitation';
    end if;

    select * into auth_user from auth.users where id = auth.uid();
    if invitation.email is not null then
        if auth_user.email is null or auth_user.email_confirmed_at is null then
            raise exception 'Sign in with the invited verified email before accepting this invitation';
        end if;
        if lower(auth_user.email) <> lower(invitation.email) then
            raise exception 'Signed-in email does not match the invitation';
        end if;
    end if;

    insert into public.kcp_profiles(
        id, display_name, phone, account_email, identity_verified_at
    ) values (
        auth.uid(), trim(p_parent_name), coalesce(normalized_phone, invitation.phone),
        case when auth_user.email_confirmed_at is not null then lower(auth_user.email) end,
        auth_user.email_confirmed_at
    )
    on conflict (id) do update
       set display_name = excluded.display_name,
           phone = coalesce(excluded.phone, public.kcp_profiles.phone),
           account_email = coalesce(excluded.account_email, public.kcp_profiles.account_email),
           identity_verified_at = coalesce(public.kcp_profiles.identity_verified_at, excluded.identity_verified_at),
           updated_at = now()
    returning * into profile;

    select exists (
        select 1 from public.kcp_roster_slots roster
        where roster.group_id = invitation.group_id
          and lower(roster.parent_name) = lower(invitation.invited_parent_name)
    ) into has_seeded_slot;

    if has_seeded_slot then
        perform public.kcp_bind_seeded_roster(
            invitation.group_id, auth.uid(), invitation.invited_parent_name, false
        );
    else
        insert into public.kcp_memberships(
            group_id, user_id, parent_name, phone, child_name, grade, role,
            status, invited_by, joined_at, updated_at
        ) values (
            invitation.group_id, auth.uid(), profile.display_name, profile.phone,
            invitation.child_name, invitation.grade, invitation.role,
            'active', invitation.invited_by, now(), now()
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
    end if;

    update public.kcp_group_participants
       set display_name = profile.display_name,
           can_drive = invitation.can_drive and invitation.role <> 'viewer',
           status = 'active',
           source = 'invitation',
           updated_at = now()
     where group_id = invitation.group_id and user_id = auth.uid()
     returning id into participant_id;

    if participant_id is null then
        insert into public.kcp_group_participants(
            group_id, user_id, display_name, can_drive, status, source
        ) values (
            invitation.group_id, auth.uid(), profile.display_name,
            invitation.can_drive and invitation.role <> 'viewer', 'active', 'invitation'
        ) returning id into participant_id;
    end if;

    if invitation.child_name is not null then
        insert into public.kcp_children(
            group_id, participant_id, name, grade_or_level, legacy_grade, status
        ) values (
            invitation.group_id, participant_id, invitation.child_name,
            invitation.grade::text, invitation.grade, 'active'
        )
        on conflict (group_id, participant_id, name) do update
           set grade_or_level = excluded.grade_or_level,
               legacy_grade = excluded.legacy_grade,
               status = 'active',
               updated_at = now();
    end if;

    if invitation.can_drive and invitation.role <> 'viewer' then
        insert into public.kcp_constraints(group_id, user_id, updated_by, effective_from)
        values (invitation.group_id, auth.uid(), auth.uid(), current_date)
        on conflict (group_id, user_id) do nothing;
    else
        delete from public.kcp_constraints
        where group_id = invitation.group_id and user_id = auth.uid();
    end if;

    update public.kcp_invitations
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now(), updated_at = now()
     where id = invitation.id;

    perform public.kcp_write_audit(
        invitation.group_id, 'invitation_accepted', 'invitation', invitation.id::text,
        jsonb_build_object(
            'memberName', profile.display_name,
            'role', invitation.role,
            'canDrive', invitation.can_drive,
            'childIncluded', invitation.child_name is not null
        )
    );

    return query
    select invitation.group_id, group_row.code
    from public.kcp_groups group_row
    where group_row.id = invitation.group_id;
end;
$$;

create or replace function public.kcp_resend_invitation(
    p_invitation_id uuid,
    p_expires_in_days integer default 14
)
returns public.kcp_invitations
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    invitation public.kcp_invitations;
begin
    select * into invitation
    from public.kcp_invitations
    where id = p_invitation_id
    for update;

    if not found then raise exception 'Invitation not found'; end if;
    if not public.kcp_is_admin(invitation.group_id) then raise exception 'Owner or admin role required'; end if;
    if invitation.status = 'accepted' then raise exception 'An accepted invitation cannot be resent'; end if;
    if p_expires_in_days < 1 or p_expires_in_days > 90 then raise exception 'Invitation expiry must be between 1 and 90 days'; end if;

    update public.kcp_invitations
       set token = public.kcp_random_invite_token(),
           status = 'pending',
           expires_at = now() + make_interval(days => p_expires_in_days),
           revoked_at = null,
           revoked_by = null,
           updated_at = now()
     where id = invitation.id
    returning * into invitation;

    perform public.kcp_write_audit(
        invitation.group_id, 'invitation_resent', 'invitation', invitation.id::text,
        jsonb_build_object('role', invitation.role, 'expiresAt', invitation.expires_at)
    );
    return invitation;
end;
$$;

create or replace function public.kcp_revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    invitation public.kcp_invitations;
begin
    select * into invitation from public.kcp_invitations where id = p_invitation_id for update;
    if not found then raise exception 'Invitation not found'; end if;
    if not public.kcp_is_admin(invitation.group_id) then raise exception 'Owner or admin role required'; end if;
    if invitation.status <> 'pending' then raise exception 'Only a pending invitation can be revoked'; end if;

    update public.kcp_invitations
       set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), updated_at = now()
     where id = invitation.id;

    perform public.kcp_write_audit(
        invitation.group_id, 'invitation_revoked', 'invitation', invitation.id::text,
        jsonb_build_object('memberName', invitation.invited_parent_name)
    );
end;
$$;

revoke all on function public.kcp_create_invitation_v2(uuid,text,text,text,text,text,integer,boolean,integer) from public, anon;
revoke all on function public.kcp_invitation_preview(text) from public, anon;
revoke all on function public.kcp_accept_invitation(text,text,text) from public, anon;
revoke all on function public.kcp_resend_invitation(uuid,integer) from public, anon;
revoke all on function public.kcp_revoke_invitation(uuid) from public, anon;

grant execute on function public.kcp_create_invitation_v2(uuid,text,text,text,text,text,integer,boolean,integer) to authenticated;
grant execute on function public.kcp_invitation_preview(text) to authenticated;
grant execute on function public.kcp_accept_invitation(text,text,text) to authenticated;
grant execute on function public.kcp_resend_invitation(uuid,integer) to authenticated;
grant execute on function public.kcp_revoke_invitation(uuid) to authenticated;

commit;
