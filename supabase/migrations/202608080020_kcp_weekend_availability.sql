begin;

alter table public.kcp_constraints
    drop constraint if exists kcp_constraints_drop_weekdays_check,
    drop constraint if exists kcp_constraints_pickup_weekdays_check;
alter table public.kcp_constraints
    add constraint kcp_constraints_drop_weekdays_check
        check (drop_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),
    add constraint kcp_constraints_pickup_weekdays_check
        check (pickup_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]);

alter table public.kcp_constraint_requests
    drop constraint if exists kcp_constraint_requests_requested_drop_weekdays_check,
    drop constraint if exists kcp_constraint_requests_requested_pickup_weekdays_check;
alter table public.kcp_constraint_requests
    add constraint kcp_constraint_requests_requested_drop_weekdays_check
        check (requested_drop_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),
    add constraint kcp_constraint_requests_requested_pickup_weekdays_check
        check (requested_pickup_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]);

create or replace function public.kcp_submit_constraint_request(
    p_group_id uuid,
    p_drop_weekdays smallint[],
    p_pickup_weekdays smallint[],
    p_notes text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    current_constraint public.kcp_constraints;
    request_id uuid;
begin
    if not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;
    if not (coalesce(p_drop_weekdays, '{}'::smallint[]) <@ array[1,2,3,4,5,6,7]::smallint[])
       or not (coalesce(p_pickup_weekdays, '{}'::smallint[]) <@ array[1,2,3,4,5,6,7]::smallint[]) then
        raise exception 'Weekdays must be between Monday (1) and Sunday (7)';
    end if;

    select * into current_constraint
    from public.kcp_constraints constraint_row
    where constraint_row.group_id = p_group_id
      and constraint_row.user_id = auth.uid();

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

revoke all on function public.kcp_submit_constraint_request(uuid,smallint[],smallint[],text)
from public, anon;
grant execute on function public.kcp_submit_constraint_request(uuid,smallint[],smallint[],text)
to authenticated;

commit;
