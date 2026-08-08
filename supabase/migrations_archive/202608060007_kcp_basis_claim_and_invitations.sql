begin;

-- ---------------------------------------------------------------------------
-- Internal binding helper and claim RPC
-- ---------------------------------------------------------------------------

create or replace function public.kcp_bind_seeded_roster(
    p_group_id uuid,
    p_user_id uuid,
    p_roster_name text,
    p_owner boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    profile public.kcp_profiles;
    slot public.kcp_roster_slots;
    group_record public.kcp_groups;
begin
    select * into profile
    from public.kcp_profiles
    where id = p_user_id;
    if not found then raise exception 'Complete the parent profile first'; end if;

    select * into group_record
    from public.kcp_groups
    where id = p_group_id
    for update;
    if not found then raise exception 'Seeded group not found'; end if;

    select * into slot
    from public.kcp_roster_slots
    where group_id = p_group_id
      and lower(parent_name) = lower(trim(p_roster_name))
    for update;
    if not found then raise exception 'Roster entry % was not found', p_roster_name; end if;

    if slot.claimed_user_id is not null and slot.claimed_user_id <> p_user_id then
        raise exception 'The % roster entry has already been claimed', slot.parent_name;
    end if;

    if p_owner then
        if lower(slot.parent_name) <> 'kiran' then
            raise exception 'Only the Kiran roster entry can claim ownership of this seeded pilot';
        end if;
        if group_record.created_by is not null and group_record.created_by <> p_user_id then
            raise exception 'This seeded pilot has already been claimed. Join with an invitation.';
        end if;
        update public.kcp_groups
        set created_by = p_user_id,
            updated_at = now()
        where id = p_group_id;

        update public.kcp_school_calendars
        set uploaded_by = coalesce(uploaded_by, p_user_id)
        where group_id = p_group_id;

        update public.kcp_schedule_versions
        set generated_by = coalesce(generated_by, p_user_id),
            published_by = coalesce(published_by, p_user_id)
        where group_id = p_group_id and version = 1;
    end if;

    insert into public.kcp_memberships(
        group_id, user_id, parent_name, phone, child_name, grade,
        role, status, invited_by, joined_at, updated_at
    ) values (
        p_group_id,
        p_user_id,
        slot.parent_name,
        profile.phone,
        slot.child_name,
        slot.grade,
        case when p_owner then 'owner' else 'parent' end,
        'active',
        case when p_owner then null else group_record.created_by end,
        now(),
        now()
    )
    on conflict (group_id, user_id) do update
    set parent_name = excluded.parent_name,
        phone = coalesce(excluded.phone, public.kcp_memberships.phone),
        child_name = excluded.child_name,
        grade = excluded.grade,
        role = case
            when public.kcp_memberships.role = 'owner' then 'owner'
            else excluded.role
        end,
        status = 'active',
        joined_at = coalesce(public.kcp_memberships.joined_at, now()),
        updated_at = now();

    insert into public.kcp_constraints(
        group_id, user_id, drop_weekdays, pickup_weekdays,
        notes, version, effective_from, updated_by, updated_at
    ) values (
        p_group_id,
        p_user_id,
        array[slot.fixed_weekday, 5]::smallint[],
        array[slot.fixed_weekday, 5]::smallint[],
        concat(slot.parent_name, ' owns ',
               case slot.fixed_weekday
                   when 1 then 'Monday'
                   when 2 then 'Tuesday'
                   when 3 then 'Wednesday'
                   when 4 then 'Thursday'
               end,
               ' and participates in the Friday rotation.'),
        1,
        date '2026-08-10',
        p_user_id,
        now()
    )
    on conflict (group_id, user_id) do update
    set drop_weekdays = excluded.drop_weekdays,
        pickup_weekdays = excluded.pickup_weekdays,
        notes = excluded.notes,
        effective_from = excluded.effective_from,
        updated_by = p_user_id,
        updated_at = now();

    update public.kcp_roster_slots
    set claimed_user_id = p_user_id,
        claimed_at = coalesce(claimed_at, now()),
        updated_at = now()
    where id = slot.id;

    update public.kcp_trips
    set scheduled_driver_id = p_user_id,
        updated_at = now()
    where group_id = p_group_id
      and lower(scheduled_driver_name) = lower(slot.parent_name)
      and scheduled_driver_id is null;

    update public.kcp_trips
    set actual_driver_id = p_user_id,
        updated_at = now()
    where group_id = p_group_id
      and lower(actual_driver_name) = lower(slot.parent_name)
      and actual_driver_id is null;

    if p_owner then
        insert into public.kcp_invitations(
            group_id, token, invited_parent_name, phone, child_name, grade,
            role, status, invited_by, created_at, expires_at
        )
        select
            p_group_id,
            public.kcp_random_invite_token(),
            r.parent_name,
            null,
            r.child_name,
            r.grade,
            'parent',
            'pending',
            p_user_id,
            now(),
            now() + interval '90 days'
        from public.kcp_roster_slots r
        where r.group_id = p_group_id
          and lower(r.parent_name) <> 'kiran'
          and r.claimed_user_id is null
          and not exists (
              select 1
              from public.kcp_invitations i
              where i.group_id = p_group_id
                and lower(i.invited_parent_name) = lower(r.parent_name)
                and i.status in ('pending','accepted')
          );
    end if;

    insert into public.kcp_audit_events(
        group_id, actor_id, action, entity_type, entity_id, details, occurred_at
    )
    select
        p_group_id,
        p_user_id,
        case when p_owner then 'seeded_group_claimed' else 'seeded_roster_claimed' end,
        'membership',
        p_user_id::text,
        jsonb_build_object(
            'parentName', slot.parent_name,
            'childName', slot.child_name,
            'pickupTag', slot.pickup_tag,
            'owner', p_owner
        ),
        now()
    where not exists (
        select 1
        from public.kcp_audit_events a
        where a.group_id = p_group_id
          and a.action = case when p_owner then 'seeded_group_claimed' else 'seeded_roster_claimed' end
          and a.entity_type = 'membership'
          and a.entity_id = p_user_id::text
    );
end;
$$;

revoke all on function public.kcp_bind_seeded_roster(uuid,uuid,text,boolean)
from public, anon, authenticated;

create or replace function public.kcp_claim_basis_pilot()
returns table(group_id uuid, group_code text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    target_group public.kcp_groups;
    profile public.kcp_profiles;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into profile
    from public.kcp_profiles
    where id = auth.uid();
    if not found then raise exception 'Complete your parent profile first'; end if;

    if lower(profile.display_name) not like 'kiran%' then
        raise exception 'The preloaded owner slot is reserved for Kiran. Use an invitation from the group owner.';
    end if;

    select * into target_group
    from public.kcp_groups
    where code = 'KCP-BASIS-2026-27'
    for update;
    if not found then raise exception 'The preloaded BASIS pilot was not found'; end if;

    perform public.kcp_bind_seeded_roster(
        target_group.id,
        auth.uid(),
        'Kiran',
        true
    );

    return query select target_group.id, target_group.code;
end;
$$;

revoke all on function public.kcp_claim_basis_pilot() from public, anon;
grant execute on function public.kcp_claim_basis_pilot() to authenticated;

-- Bind a joined parent to the seeded roster and preloaded schedule.
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
declare
    inv public.kcp_invitations;
    normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
    profile public.kcp_profiles;
    has_seeded_slot boolean := false;
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

    select exists (
        select 1
        from public.kcp_roster_slots r
        where r.group_id = inv.group_id
          and lower(r.parent_name) = lower(inv.invited_parent_name)
    ) into has_seeded_slot;

    if has_seeded_slot then
        perform public.kcp_bind_seeded_roster(
            inv.group_id,
            auth.uid(),
            inv.invited_parent_name,
            false
        );
    else
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
    end if;

    update public.kcp_invitations
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = inv.id;

    perform public.kcp_write_audit(
        inv.group_id, 'invitation_accepted', 'invitation', inv.id::text,
        jsonb_build_object('parentName', profile.display_name)
    );

    return query
    select inv.group_id, g.code
    from public.kcp_groups g
    where g.id = inv.group_id;
end;
$$;

revoke all on function public.kcp_accept_invitation(text,text,text) from public, anon;
grant execute on function public.kcp_accept_invitation(text,text,text) to authenticated;

commit;
