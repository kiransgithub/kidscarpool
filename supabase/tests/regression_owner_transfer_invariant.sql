-- Read-only regression check for the final owner invariant.
-- The immediate partial unique index breaks cross-device recovery because the
-- replacement Owner is inserted before the former Owner is removed inside one
-- transaction. The deferred trigger must be the only enforcement mechanism.

begin;

do $$
declare
    deferred_trigger_count integer;
begin
    if to_regclass('public.kcp_one_active_owner_per_group') is not null then
        raise exception 'Legacy immediate owner index is present';
    end if;

    select count(*)
      into deferred_trigger_count
      from pg_trigger trigger_row
     where trigger_row.tgrelid = 'public.kcp_memberships'::regclass
       and trigger_row.tgname = 'kcp_memberships_single_owner_check'
       and not trigger_row.tgisinternal
       and trigger_row.tgdeferrable
       and trigger_row.tginitdeferred;

    if deferred_trigger_count <> 1 then
        raise exception
            'Expected one deferred owner invariant trigger, found %',
            deferred_trigger_count;
    end if;

    if exists (
        select 1
        from public.kcp_memberships membership
        where membership.status = 'active'
        group by membership.group_id
        having count(*) filter (where membership.role = 'owner') <> 1
    ) then
        raise exception 'An active group has zero or multiple active Owners';
    end if;
end;
$$;

rollback;

select 'PASS: owner transfer uses the deferred invariant and no immediate unique index' as result;
