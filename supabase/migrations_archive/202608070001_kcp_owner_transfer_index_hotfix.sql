begin;

-- ---------------------------------------------------------------------------
-- Recovery-safe owner transfer hotfix
--
-- Migration 018 originally created an immediate partial unique index to permit
-- only one active Owner. Migration 026 replaced it with a deferred constraint
-- trigger so account recovery can insert the replacement Owner and remove the
-- former Owner in one transaction.
--
-- When an automated Supabase deployment and a manual `supabase db push` race,
-- migration 018 can be executed again after migration 026 and recreate the old
-- index before the duplicate migration-history insert fails. Reapply the final
-- invariant here under a new migration version.
-- ---------------------------------------------------------------------------

-- Be defensive in case an earlier environment created the object as a table
-- constraint rather than as the known partial unique index.
do $$
begin
    if exists (
        select 1
        from pg_constraint constraint_row
        where constraint_row.conrelid = 'public.kcp_memberships'::regclass
          and constraint_row.conname = 'kcp_one_active_owner_per_group'
    ) then
        alter table public.kcp_memberships
            drop constraint kcp_one_active_owner_per_group;
    end if;
end;
$$;

drop index if exists public.kcp_one_active_owner_per_group;

-- Normalize any experimental duplicate owner rows before restoring the final
-- deferred invariant. Prefer the group creator, then the earliest membership.
with ranked_owners as (
    select
        membership.group_id,
        membership.user_id,
        row_number() over (
            partition by membership.group_id
            order by
                case when membership.user_id = group_row.created_by then 0 else 1 end,
                coalesce(membership.joined_at, membership.updated_at),
                membership.user_id
        ) as owner_rank
    from public.kcp_memberships membership
    join public.kcp_groups group_row
      on group_row.id = membership.group_id
    where membership.status = 'active'
      and membership.role = 'owner'
)
update public.kcp_memberships membership
   set role = 'admin',
       updated_at = now()
  from ranked_owners ranked
 where membership.group_id = ranked.group_id
   and membership.user_id = ranked.user_id
   and ranked.owner_rank > 1;

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

    -- During cascading group deletion the group row is already gone.
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

    -- Unclaimed preloaded groups may have no members. Once a group has an
    -- active member, the transaction must commit with exactly one Owner.
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

-- Fail this migration rather than silently leave the recovery-breaking index.
do $$
begin
    if to_regclass('public.kcp_one_active_owner_per_group') is not null then
        raise exception 'Legacy immediate owner index still exists';
    end if;

    if not exists (
        select 1
        from pg_trigger trigger_row
        where trigger_row.tgrelid = 'public.kcp_memberships'::regclass
          and trigger_row.tgname = 'kcp_memberships_single_owner_check'
          and not trigger_row.tgisinternal
          and trigger_row.tgdeferrable
          and trigger_row.tginitdeferred
    ) then
        raise exception 'Deferred owner invariant trigger is missing';
    end if;
end;
$$;

commit;
