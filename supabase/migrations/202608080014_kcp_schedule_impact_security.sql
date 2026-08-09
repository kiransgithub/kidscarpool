begin;

-- The renamed implementation is an internal building block. Browser roles must
-- publish through the impact-reviewed v2 wrapper.
revoke all on function public.kcp_publish_schedule_plan_base(uuid,text)
from public, anon, authenticated;

create or replace function public.kcp_schedule_change_details(p_change_set_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    change_set public.kcp_schedule_change_sets;
    result jsonb;
begin
    select * into change_set
    from public.kcp_schedule_change_sets
    where id = p_change_set_id;
    if not found then raise exception 'Schedule change preview not found'; end if;
    if not public.kcp_is_member(change_set.group_id) then
        raise exception 'Active group membership required';
    end if;
    if change_set.status = 'previewed' and not public.kcp_is_admin(change_set.group_id) then
        raise exception 'Owner or Admin role required to inspect an unpublished schedule preview';
    end if;

    select to_jsonb(change_set) || jsonb_build_object(
        'impacts', coalesce((
            select jsonb_agg(to_jsonb(impact) order by impact.trip_date, impact.impact_type)
            from public.kcp_schedule_change_impacts impact
            where impact.change_set_id = change_set.id
        ), '[]'::jsonb),
        'acknowledgements', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userId', acknowledgement.user_id,
                'name', profile.display_name,
                'status', acknowledgement.status,
                'note', acknowledgement.note,
                'acknowledgedAt', acknowledgement.acknowledged_at
            ) order by profile.display_name)
            from public.kcp_schedule_acknowledgements acknowledgement
            left join public.kcp_profiles profile on profile.id = acknowledgement.user_id
            where acknowledgement.change_set_id = change_set.id
        ), '[]'::jsonb)
    ) into result;
    return result;
end;
$$;

revoke all on function public.kcp_schedule_change_details(uuid) from public, anon;
grant execute on function public.kcp_schedule_change_details(uuid) to authenticated;

commit;
