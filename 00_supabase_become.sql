-- SUPABASE CI HELPER.
--
-- On real Supabase the auth schema, auth.users and auth.uid() already exist,
-- so the tests only need a way to impersonate a user. auth.uid() reads the
-- request.jwt.claim.sub GUC, so setting that GUC is enough -- this file does
-- NOT redefine auth.uid(), auth.users, or any Supabase-owned object.
--
-- Applied only when KCP_MODE=supabase. The local counterpart is
-- 00_local_auth_shim.sql, which additionally creates the stand-in auth schema.

create or replace function auth.become(p_user uuid) returns void
language sql as $$
    select set_config('request.jwt.claim.sub', p_user::text, false);
$$;

commit;
