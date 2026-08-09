-- ===========================================================================
-- Regression: recovery-safe single-active-owner invariant
--
-- Ports supabase/tests/regression_owner_transfer_invariant.sql (which targeted
-- kcp_memberships) onto the canonical membership role model.
--
-- The invariant MUST be enforced by a DEFERRED constraint trigger and NOT by
-- an immediate partial unique index. An immediate index rejects the
-- intermediate two-owner state that an atomic owner transfer passes through --
-- the bug fixed by migration 202608070001, and reintroduced (and caught here)
-- while squashing the baseline.
--
-- Cases:
--   A  cascade delete of a group with an active owner        -> commits
--   B  atomic owner transfer in one transaction              -> commits
--   C  committing with zero active owners                    -> rejected
--   D  committing with two active owners                     -> rejected
--   E  no immediate unique index resurrects the old bug      -> asserted
--
-- Prereqs: baseline applied. Usage: psql -v ON_ERROR_STOP=1 -f this_file
-- ===========================================================================

\set QUIET on
\pset pager off

do $$
declare
    v_user  uuid := gen_random_uuid();
    v_parent uuid := gen_random_uuid();
    v_group uuid;
    v_owner uuid;
    v_count integer;
    v_failed boolean;
begin
    -- ---- E: structural guard, checked first -------------------------------
    if to_regclass('public.kcp_one_active_owner_per_group') is not null then
        raise exception
            'E FAILED: immediate owner index exists; it blocks atomic transfer';
    end if;

    if not exists (
        select 1 from pg_trigger t
        where t.tgrelid = 'public.kcp_memberships'::regclass
          and t.tgname  = 'kcp_memberships_single_owner_check'
          and not t.tgisinternal
          and t.tgdeferrable
          and t.tginitdeferred
    ) then
        raise exception 'E FAILED: deferred owner invariant trigger missing';
    end if;
    raise notice 'PASS E: deferred trigger present, no immediate index';

    -- ---- fixture ----------------------------------------------------------
    insert into auth.users(id) values (v_user);
    insert into public.kcp_profiles(id, display_name) values (v_user, 'Owner');
    perform auth.become(v_user);

    insert into public.kcp_groups(
            code, name, school_key, school_name, academic_year, created_by)
        values ('OWNTST', 'Owner invariant test', 'owner-test-1',
                'Owner test destination', 'Test term', v_user)
        returning id into v_group;
    insert into public.kcp_memberships(
            group_id, user_id, parent_name, child_name, grade, role, status)
        values (v_group, v_user, 'Owner', 'Owner child', 4, 'owner', 'active');
    v_owner := v_user;

    -- ---- B: atomic owner transfer ----------------------------------------
    -- Passes through a transient two-owner state; must still commit.
    insert into auth.users(id) values (v_parent);
    insert into public.kcp_profiles(id, display_name) values (v_parent, 'New owner');
    insert into public.kcp_memberships(
            group_id, user_id, parent_name, child_name, grade, role, status)
        values (v_group, v_parent, 'New owner', 'New child', 4, 'owner', 'active');
    update public.kcp_memberships
       set role = 'admin'
     where group_id = v_group and user_id = v_owner;

    select count(*) into v_count
      from public.kcp_memberships
     where group_id = v_group and role = 'owner' and status = 'active';
    if v_count <> 1 then
        raise exception 'B FAILED: expected 1 active owner, found %', v_count;
    end if;
    raise notice 'PASS B: atomic owner transfer through transient 2-owner state';

    -- ---- C: zero owners must be rejected ---------------------------------
    v_failed := false;
    begin
        update public.kcp_memberships
           set role = 'parent'
         where group_id = v_group;
        -- Force the deferred trigger to fire without ending this block.
        set constraints public.kcp_memberships_single_owner_check immediate;
    exception when others then
        v_failed := true;
    end;
    if not v_failed then
        raise exception 'C FAILED: zero-owner state was accepted';
    end if;
    raise notice 'PASS C: zero-owner state rejected';
end;
$$;

-- C left the transaction in a poisoned state inside the DO block, so the
-- remaining cases run in their own statements against a clean fixture.

do $$
declare
    v_user  uuid := gen_random_uuid();
    v_second uuid := gen_random_uuid();
    v_group uuid;
    v_failed boolean := false;
begin
    insert into auth.users(id) values (v_user), (v_second);
    insert into public.kcp_profiles(id, display_name)
    values (v_user, 'Owner2'), (v_second, 'Second owner');
    perform auth.become(v_user);
    insert into public.kcp_groups(
            code, name, school_key, school_name, academic_year, created_by)
        values ('OWNTS2', 'Owner invariant test 2', 'owner-test-2',
                'Owner test destination', 'Test term', v_user)
        returning id into v_group;
    insert into public.kcp_memberships(
            group_id, user_id, parent_name, child_name, grade, role, status)
        values (v_group, v_user, 'Owner', 'Owner child', 4, 'owner', 'active');

    -- ---- D: two owners at commit must be rejected ------------------------
    begin
        insert into public.kcp_memberships(
                group_id, user_id, parent_name, child_name, grade, role, status)
            values (v_group, v_second, 'Second owner', 'Second child', 4, 'owner', 'active');
        set constraints public.kcp_memberships_single_owner_check immediate;
    exception when others then
        v_failed := true;
    end;
    if not v_failed then
        raise exception 'D FAILED: two-owner state was accepted at commit';
    end if;
    raise notice 'PASS D: two-owner state rejected';
end;
$$;

-- ---- A: cascade delete of a group holding an active owner ----------------
do $$
declare
    v_user  uuid := gen_random_uuid();
    v_group uuid;
begin
    insert into auth.users(id) values (v_user);
    insert into public.kcp_profiles(id, display_name) values (v_user, 'Owner3');
    perform auth.become(v_user);
    insert into public.kcp_groups(
            code, name, school_key, school_name, academic_year, created_by)
        values ('OWNTS3', 'Owner invariant test 3', 'owner-test-3',
                'Owner test destination', 'Test term', v_user)
        returning id into v_group;
    insert into public.kcp_memberships(
            group_id, user_id, parent_name, child_name, grade, role, status)
        values (v_group, v_user, 'Owner', 'Owner child', 4, 'owner', 'active');

    delete from public.kcp_groups where id = v_group;

    if exists (select 1 from public.kcp_groups where id = v_group) then
        raise exception 'A FAILED: group survived delete';
    end if;
    raise notice 'PASS A: cascade delete of group with active owner';
end;
$$;

do $$ begin
    raise notice 'PASS: recovery-safe single-owner invariant holds';
end $$;
