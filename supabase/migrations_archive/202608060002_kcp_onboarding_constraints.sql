begin;

-- ---------------------------------------------------------------------------
-- RPC: profile and group onboarding
-- ---------------------------------------------------------------------------

create or replace function public.kcp_upsert_profile(
    p_display_name text,
    p_phone text default null
)
returns public.kcp_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
    result public.kcp_profiles;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    insert into public.kcp_profiles(id, display_name, phone)
    values (auth.uid(), trim(p_display_name), nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), ''))
    on conflict (id) do update
       set display_name = excluded.display_name,
           phone = coalesce(excluded.phone, public.kcp_profiles.phone),
           updated_at = now()
    returning * into result;

    return result;
end;
$$;

create or replace function public.kcp_create_group(
    p_name text,
    p_school_name text,
    p_school_key text,
    p_academic_year text,
    p_child_name text,
    p_grade integer,
    p_drop_weekdays smallint[] default array[1,2,3,4,5]::smallint[],
    p_pickup_weekdays smallint[] default array[1,2,3,4,5]::smallint[],
    p_notes text default ''
)
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public
as $$
declare
    new_group public.kcp_groups;
    profile public.kcp_profiles;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    select * into profile from public.kcp_profiles where id = auth.uid();
    if not found then raise exception 'Complete your parent profile first'; end if;

    insert into public.kcp_groups(
        code, name, school_key, school_name, academic_year, created_by
    ) values (
        public.kcp_random_code('KCP'), trim(p_name), trim(p_school_key),
        trim(p_school_name), trim(p_academic_year), auth.uid()
    ) returning * into new_group;

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade,
        role, status, joined_at
    ) values (
        new_group.id, auth.uid(), profile.display_name, profile.phone,
        trim(p_child_name), p_grade, 'owner', 'active', now()
    );

    insert into public.kcp_constraints(
        group_id, user_id, drop_weekdays, pickup_weekdays, notes,
        updated_by, effective_from
    ) values (
        new_group.id, auth.uid(), coalesce(p_drop_weekdays, '{}'::smallint[]),
        coalesce(p_pickup_weekdays, '{}'::smallint[]), coalesce(p_notes,''),
        auth.uid(), current_date
    );

    perform public.kcp_write_audit(
        new_group.id, 'group_created', 'group', new_group.id::text,
        jsonb_build_object('name', new_group.name, 'code', new_group.code)
    );

    return query select new_group.id, new_group.code;
end;
$$;

create or replace function public.kcp_list_my_groups()
returns table(
    group_id uuid,
    group_code text,
    group_name text,
    school_name text,
    academic_year text,
    role text,
    child_name text,
    grade integer,
    active_member_count bigint,
    pending_invitation_count bigint,
    pending_constraint_count bigint,
    calendar_registered boolean,
    current_schedule_version integer,
    pilot_time_override boolean,
    last_activity_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select
        g.id,
        g.code,
        g.name,
        g.school_name,
        g.academic_year,
        me.role,
        me.child_name,
        me.grade,
        (select count(*) from public.kcp_memberships m where m.group_id = g.id and m.status = 'active'),
        (select count(*) from public.kcp_invitations i where i.group_id = g.id and i.status = 'pending' and i.expires_at > now()),
        (select count(*) from public.kcp_constraint_requests r where r.group_id = g.id and r.status = 'pending'),
        exists(select 1 from public.kcp_school_calendars c where c.group_id = g.id),
        g.current_schedule_version,
        g.pilot_time_override,
        greatest(
            g.updated_at,
            coalesce((select max(a.occurred_at) from public.kcp_audit_events a where a.group_id = g.id), g.updated_at)
        ) as last_activity_at
    from public.kcp_memberships me
    join public.kcp_groups g on g.id = me.group_id
    where me.user_id = auth.uid()
      and me.status = 'active'
      and g.status = 'active'
    order by 15 desc;
$$;

create or replace function public.kcp_create_invitation(
    p_group_id uuid,
    p_parent_name text,
    p_phone text,
    p_child_name text,
    p_grade integer,
    p_role text default 'parent'
)
returns public.kcp_invitations
language plpgsql
security definer
set search_path = public
as $$
declare
    result public.kcp_invitations;
    normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;
    if p_role not in ('admin','parent','viewer') then raise exception 'Invalid invitation role'; end if;

    if normalized_phone is not null and exists (
        select 1 from public.kcp_memberships m
        where m.group_id = p_group_id and m.phone = normalized_phone and m.status = 'active'
    ) then
        raise exception 'That phone number is already associated with an active member of this group';
    end if;

    insert into public.kcp_invitations(
        group_id, token, invited_parent_name, phone, child_name, grade, role, invited_by
    ) values (
        p_group_id, public.kcp_random_invite_token(), trim(p_parent_name),
        normalized_phone, trim(p_child_name), p_grade, p_role, auth.uid()
    ) returning * into result;

    perform public.kcp_write_audit(
        p_group_id, 'invitation_created', 'invitation', result.id::text,
        jsonb_build_object('parentName', result.invited_parent_name, 'role', result.role)
    );
    return result;
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
set search_path = public
as $$
declare
    inv public.kcp_invitations;
    normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
    profile public.kcp_profiles;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into inv
    from public.kcp_invitations
    where token = upper(trim(p_token))
    for update;

    if not found then raise exception 'Invitation code was not found'; end if;
    if inv.status <> 'pending' then raise exception 'This invitation is no longer available'; end if;
    if inv.expires_at <= now() then
        update public.kcp_invitations set status = 'expired' where id = inv.id;
        raise exception 'This invitation has expired';
    end if;
    if lower(trim(inv.invited_parent_name)) <> lower(trim(p_parent_name)) then
        raise exception 'Parent name does not match the invitation';
    end if;
    if inv.phone is not null and normalized_phone is distinct from inv.phone then
        raise exception 'Phone number does not match the invitation';
    end if;

    insert into public.kcp_profiles(id, display_name, phone)
    values (auth.uid(), trim(p_parent_name), coalesce(normalized_phone, inv.phone))
    on conflict (id) do update
       set display_name = excluded.display_name,
           phone = coalesce(excluded.phone, public.kcp_profiles.phone),
           updated_at = now()
    returning * into profile;

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade, role,
        status, invited_by, joined_at
    ) values (
        inv.group_id, auth.uid(), profile.display_name, profile.phone,
        inv.child_name, inv.grade, inv.role, 'active', inv.invited_by, now()
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

    insert into public.kcp_constraints(group_id, user_id, updated_by, effective_from)
    values (inv.group_id, auth.uid(), auth.uid(), current_date)
    on conflict (group_id, user_id) do nothing;

    update public.kcp_invitations
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = inv.id;

    perform public.kcp_write_audit(
        inv.group_id, 'invitation_accepted', 'invitation', inv.id::text,
        jsonb_build_object('parentName', profile.display_name)
    );

    return query
    select inv.group_id, g.code from public.kcp_groups g where g.id = inv.group_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: constraints and administration
-- ---------------------------------------------------------------------------

create or replace function public.kcp_submit_constraint_request(
    p_group_id uuid,
    p_drop_weekdays smallint[],
    p_pickup_weekdays smallint[],
    p_notes text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    current_constraint public.kcp_constraints;
    request_id uuid;
begin
    if not public.kcp_is_member(p_group_id) then raise exception 'Active group membership required'; end if;
    if not (coalesce(p_drop_weekdays, '{}'::smallint[]) <@ array[1,2,3,4,5]::smallint[])
       or not (coalesce(p_pickup_weekdays, '{}'::smallint[]) <@ array[1,2,3,4,5]::smallint[]) then
        raise exception 'Weekdays must be between Monday (1) and Friday (5)';
    end if;

    select * into current_constraint
    from public.kcp_constraints
    where group_id = p_group_id and user_id = auth.uid();

    if not found then
        insert into public.kcp_constraints(group_id, user_id, updated_by, effective_from)
        values (p_group_id, auth.uid(), auth.uid(), current_date)
        returning * into current_constraint;
    end if;

    insert into public.kcp_constraint_requests(
        group_id, user_id,
        previous_drop_weekdays, previous_pickup_weekdays,
        requested_drop_weekdays, requested_pickup_weekdays,
        notes, base_version
    ) values (
        p_group_id, auth.uid(),
        current_constraint.drop_weekdays, current_constraint.pickup_weekdays,
        coalesce(p_drop_weekdays, '{}'::smallint[]),
        coalesce(p_pickup_weekdays, '{}'::smallint[]),
        coalesce(p_notes,''), current_constraint.version
    ) returning id into request_id;

    perform public.kcp_write_audit(
        p_group_id, 'constraint_request_submitted', 'constraint_request', request_id::text,
        jsonb_build_object('baseVersion', current_constraint.version)
    );
    return request_id;
end;
$$;

create or replace function public.kcp_review_constraint_request(
    p_request_id uuid,
    p_decision text,
    p_review_note text default ''
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    req public.kcp_constraint_requests;
    new_version integer;
begin
    select * into req
    from public.kcp_constraint_requests
    where id = p_request_id
    for update;

    if not found then raise exception 'Constraint request not found'; end if;
    if not public.kcp_is_admin(req.group_id) then raise exception 'Owner or admin role required'; end if;
    if req.status <> 'pending' then raise exception 'Constraint request has already been reviewed'; end if;
    if p_decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected'; end if;

    if p_decision = 'approved' then
        update public.kcp_constraints
           set drop_weekdays = req.requested_drop_weekdays,
               pickup_weekdays = req.requested_pickup_weekdays,
               notes = req.notes,
               version = version + 1,
               effective_from = current_date,
               updated_by = auth.uid(),
               updated_at = now()
         where group_id = req.group_id and user_id = req.user_id
         returning version into new_version;
    else
        select version into new_version
        from public.kcp_constraints
        where group_id = req.group_id and user_id = req.user_id;
    end if;

    update public.kcp_constraint_requests
       set status = p_decision,
           reviewed_at = now(),
           reviewed_by = auth.uid(),
           review_note = nullif(trim(p_review_note),'')
     where id = req.id;

    perform public.kcp_write_audit(
        req.group_id, 'constraint_request_' || p_decision,
        'constraint_request', req.id::text,
        jsonb_build_object('reviewNote', coalesce(p_review_note,''), 'constraintVersion', new_version)
    );
    return new_version;
end;
$$;

create or replace function public.kcp_set_member_role(
    p_group_id uuid,
    p_member_user_id uuid,
    p_role text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_role text;
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;
    if p_role not in ('admin','parent','viewer') then raise exception 'Invalid member role'; end if;

    select role into target_role from public.kcp_memberships
    where group_id = p_group_id and user_id = p_member_user_id and status = 'active';
    if not found then raise exception 'Active member not found'; end if;
    if target_role = 'owner' then raise exception 'The owner role cannot be changed here'; end if;

    update public.kcp_memberships
       set role = p_role, updated_at = now()
     where group_id = p_group_id and user_id = p_member_user_id;

    perform public.kcp_write_audit(
        p_group_id, 'member_role_changed', 'membership', p_member_user_id::text,
        jsonb_build_object('previousRole', target_role, 'newRole', p_role)
    );
end;
$$;

create or replace function public.kcp_set_pilot_time_override(
    p_group_id uuid,
    p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;
    update public.kcp_groups set pilot_time_override = p_enabled where id = p_group_id;
    perform public.kcp_write_audit(
        p_group_id, 'pilot_time_override_changed', 'group', p_group_id::text,
        jsonb_build_object('enabled', p_enabled)
    );
end;
$$;


commit;
