begin;

-- ---------------------------------------------------------------------------
-- Enforce exactly one active Owner at transaction commit rather than after
-- every individual statement. Account recovery inserts the replacement Owner
-- and removes the former Owner in one transaction; an immediate partial unique
-- index incorrectly rejects the safe intermediate state.
-- ---------------------------------------------------------------------------

drop index if exists public.kcp_one_active_owner_per_group;

create or replace function public.kcp_check_single_active_owner()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
declare
    affected_group_id uuid := coalesce(new.group_id, old.group_id);
    group_status text;
    active_members integer;
    active_owners integer;
begin
    if affected_group_id is null then
        return null;
    end if;

    select group_row.status
      into group_status
      from public.kcp_groups group_row
     where group_row.id = affected_group_id;

    -- A cascading group deletion removes memberships after the group row has
    -- disappeared, so there is no ownership invariant left to validate.
    if group_status is null then
        return null;
    end if;

    select
        count(*) filter (where membership.status = 'active'),
        count(*) filter (
            where membership.status = 'active'
              and membership.role = 'owner'
        )
      into active_members, active_owners
      from public.kcp_memberships membership
     where membership.group_id = affected_group_id;

    -- A preloaded/unclaimed group can intentionally contain no membership yet.
    -- Once the first active member exists, the transaction must finish with one
    -- and only one active Owner.
    if active_members > 0 and active_owners <> 1 then
        raise exception
            'Group % must have exactly one active Owner; found %',
            affected_group_id,
            active_owners;
    end if;

    return null;
end;
$$;

drop trigger if exists kcp_memberships_single_owner_check
on public.kcp_memberships;

create constraint trigger kcp_memberships_single_owner_check
after insert or update or delete
on public.kcp_memberships
deferrable initially deferred
for each row
execute function public.kcp_check_single_active_owner();

revoke all on function public.kcp_check_single_active_owner()
from public, anon, authenticated;

commit;
