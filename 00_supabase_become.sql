-- SUPABASE CI HELPER.
--
-- The local Supabase stack owns the auth schema. Tests impersonate a user by
-- setting the same request JWT claim read by auth.uid(), but the helper itself
-- lives in public so CI never writes to Supabase-managed auth objects.

create or replace function public.kcp_test_become(p_user uuid)
returns void
language sql
set search_path = public, pg_catalog
as $$
    select set_config('request.jwt.claim.sub', p_user::text, false);
$$;

revoke all on function public.kcp_test_become(uuid) from public, anon, authenticated;

commit;
