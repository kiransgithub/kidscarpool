begin;

-- Owners can stage a driving parent before schedule setup. Child details are
-- optional because the owner may know the driver before knowing every rider.
create or replace function public.kcp_create_driver_invitation(
    p_group_id uuid,
    p_member_name text,
    p_email text,
    p_phone text default null,
    p_child_name text default null,
    p_grade_or_level text default null,
    p_expires_in_days integer default 14
)
returns public.kcp_invitations
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result public.kcp_invitations;
    normalized_email text := nullif(lower(trim(coalesce(p_email,''))), '');
    normalized_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
    normalized_child text := nullif(trim(coalesce(p_child_name,'')), '');
    legacy_grade integer;
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;
    if nullif(trim(coalesce(p_member_name,'')), '') is null then raise exception 'Driver name is required'; end if;
    if normalized_email is null then raise exception 'Driver email is required so KCP can deliver the invitation'; end if;
    if p_expires_in_days not between 1 and 90 then raise exception 'Invitation expiry must be between 1 and 90 days'; end if;

    begin
        legacy_grade := nullif(regexp_replace(coalesce(p_grade_or_level,''), '[^0-9]', '', 'g'), '')::integer;
        if legacy_grade not between 0 and 12 then legacy_grade := null; end if;
    exception when others then
        legacy_grade := null;
    end;

    if exists (
        select 1 from public.kcp_invitations invitation
        where invitation.group_id = p_group_id
          and lower(invitation.email) = normalized_email
          and invitation.status = 'pending'
    ) then raise exception 'That driver already has a pending invitation'; end if;

    insert into public.kcp_invitations(
        group_id, token, invited_parent_name, email, phone, child_name, grade,
        role, can_drive, status, invited_by, created_at, updated_at, expires_at
    ) values (
        p_group_id, public.kcp_random_invite_token(), trim(p_member_name),
        normalized_email, normalized_phone, normalized_child, legacy_grade,
        'parent', true, 'pending', auth.uid(), now(), now(),
        now() + make_interval(days => p_expires_in_days)
    ) returning * into result;

    perform public.kcp_write_audit(
        p_group_id, 'driver_invitation_created', 'invitation', result.id::text,
        jsonb_build_object('memberName', result.invited_parent_name, 'emailBound', true,
                           'childIncluded', result.child_name is not null)
    );
    return result;
end;
$$;

create or replace function public.kcp_decline_invitation(p_token text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
    invitation public.kcp_invitations;
    signed_in_email text;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    select * into invitation from public.kcp_invitations
     where token = upper(trim(p_token)) for update;
    if not found then raise exception 'Invitation code was not found'; end if;
    if invitation.status <> 'pending' then raise exception 'This invitation is no longer available'; end if;

    select lower(email) into signed_in_email from auth.users where id = auth.uid();
    if invitation.email is not null and signed_in_email is distinct from lower(invitation.email) then
        raise exception 'Sign in with the invited email before declining this invitation';
    end if;

    update public.kcp_invitations
       set status = 'declined', updated_at = now()
     where id = invitation.id;
    perform public.kcp_write_audit(
        invitation.group_id, 'invitation_declined', 'invitation', invitation.id::text,
        jsonb_build_object('memberName', invitation.invited_parent_name)
    );
end;
$$;

-- The owner can preview and inspect a draft at any time, but assignments are
-- not published while a driving invitation is awaiting a decision.
create or replace function public.kcp_publish_schedule_plan_v3(
    p_plan_id uuid,
    p_reason text,
    p_change_set_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    plan public.kcp_schedule_plans;
    pending_drivers integer;
begin
    select * into plan from public.kcp_schedule_plans where id = p_plan_id;
    if not found then raise exception 'Schedule plan not found'; end if;
    if not public.kcp_is_admin(plan.group_id) then raise exception 'Owner or admin role required'; end if;

    select count(*) into pending_drivers
      from public.kcp_invitations invitation
     where invitation.group_id = plan.group_id
       and invitation.status = 'pending'
       and invitation.can_drive;
    if pending_drivers > 0 then
        raise exception 'All invited drivers must accept or decline before the schedule can be published';
    end if;

    return public.kcp_publish_schedule_plan_v2(p_plan_id, p_reason, p_change_set_id);
end;
$$;

revoke all on function public.kcp_create_driver_invitation(uuid,text,text,text,text,text,integer) from public, anon;
revoke all on function public.kcp_decline_invitation(text) from public, anon;
revoke all on function public.kcp_publish_schedule_plan_v3(uuid,text,uuid) from public, anon;
grant execute on function public.kcp_create_driver_invitation(uuid,text,text,text,text,text,integer) to authenticated;
grant execute on function public.kcp_decline_invitation(text) to authenticated;
grant execute on function public.kcp_publish_schedule_plan_v3(uuid,text,uuid) to authenticated;

commit;
