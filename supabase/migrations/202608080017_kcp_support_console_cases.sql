begin;

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
              on participant.group_id = member.group_id
             and participant.user_id = member.user_id
             and participant.status = 'active'
            where member.group_id = group_record.id
        ), '[]'::jsonb),
        'invitations', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', invitation.id,
                'name', public.kcp_mask_support_text(invitation.invited_parent_name),
                'role', invitation.role,
                'status', invitation.status,
                'createdAt', invitation.created_at,
                'expiresAt', invitation.expires_at
            ) order by invitation.created_at desc)
            from public.kcp_invitations invitation
            where invitation.group_id = group_record.id
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

create or replace function public.kcp_support_cases_list(
    p_status text default null,
    p_group_id uuid default null,
    p_limit integer default 200
)
returns table(
    case_id uuid,
    group_id uuid,
    group_name text,
    status text,
    category text,
    summary text,
    reported_by uuid,
    reported_by_masked text,
    created_at timestamptz,
    resolved_at timestamptz
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
    select support_case.id, support_case.group_id, group_row.name,
           support_case.status, support_case.category, support_case.summary,
           support_case.reported_by, public.kcp_mask_support_text(profile.display_name),
           support_case.created_at, support_case.resolved_at
    from public.kcp_support_cases support_case
    left join public.kcp_groups group_row on group_row.id = support_case.group_id
    left join public.kcp_profiles profile on profile.id = support_case.reported_by
    where (p_status is null or support_case.status = p_status)
      and (p_group_id is null or support_case.group_id = p_group_id)
    order by
      case when support_case.status in ('open','new') then 0
           when support_case.status in ('in_progress','investigating') then 1
           else 2 end,
      support_case.created_at desc
    limit least(greatest(p_limit,1),500);
end;
$$;

create or replace function public.kcp_support_update_case(
    p_case_id uuid,
    p_status text,
    p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    support_case public.kcp_support_cases;
begin
    if not public.kcp_is_platform_admin('support_admin') then
        raise exception 'Platform support role required';
    end if;
    if p_status not in ('open','in_progress','resolved','closed') then
        raise exception 'Choose Open, In progress, Resolved or Closed';
    end if;
    select * into support_case from public.kcp_support_cases where id = p_case_id for update;
    if not found then raise exception 'Support case not found'; end if;

    update public.kcp_support_cases
       set status = p_status,
           resolved_at = case when p_status in ('resolved','closed') then now() else null end
     where id = support_case.id;

    perform public.kcp_write_platform_audit(
        'support_case_updated','support_case',support_case.id::text,
        jsonb_build_object('status',p_status,'note',nullif(trim(p_note),''),'groupId',support_case.group_id)
    );
end;
$$;

revoke all on function public.kcp_support_group_details(uuid) from public, anon;
revoke all on function public.kcp_support_cases_list(text,uuid,integer) from public, anon;
revoke all on function public.kcp_support_update_case(uuid,text,text) from public, anon;
grant execute on function public.kcp_support_group_details(uuid) to authenticated;
grant execute on function public.kcp_support_cases_list(text,uuid,integer) to authenticated;
grant execute on function public.kcp_support_update_case(uuid,text,text) to authenticated;

commit;
