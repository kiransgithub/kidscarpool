begin;

-- Supabase installs most extensions under the `extensions` schema. The
-- original code-generation helpers called pgcrypto.gen_random_bytes() with a
-- function search_path restricted to `public`, so group creation failed with:
--
--   function gen_random_bytes(integer) does not exist
--
-- Use PostgreSQL's core gen_random_uuid() instead. It is available through
-- pg_catalog and therefore does not depend on the pgcrypto extension schema.

create or replace function public.kcp_random_code(p_prefix text default 'KCP')
returns text
language plpgsql
volatile
set search_path = public, pg_catalog
as $$
declare
    candidate text;
    normalized_prefix text := regexp_replace(
        upper(coalesce(nullif(trim(p_prefix), ''), 'KCP')),
        '[^A-Z0-9]',
        '',
        'g'
    );
begin
    if normalized_prefix = '' then
        normalized_prefix := 'KCP';
    end if;

    loop
        candidate := normalized_prefix || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
        exit when not exists (
            select 1 from public.kcp_groups where code = candidate
        );
    end loop;

    return candidate;
end;
$$;

create or replace function public.kcp_random_invite_token()
returns text
language plpgsql
volatile
set search_path = public, pg_catalog
as $$
declare
    candidate text;
begin
    loop
        candidate := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
        exit when not exists (
            select 1 from public.kcp_invitations where token = candidate
        );
    end loop;

    return candidate;
end;
$$;

-- These helpers are internal implementation details. Client applications call
-- the SECURITY DEFINER onboarding RPCs instead of invoking them directly.
revoke all on function public.kcp_random_code(text) from public, anon, authenticated;
revoke all on function public.kcp_random_invite_token() from public, anon, authenticated;

-- Migration-time smoke checks. They do not insert any application rows.
do $$
declare
    generated_group_code text;
    generated_invite_code text;
begin
    generated_group_code := public.kcp_random_code('tst');
    generated_invite_code := public.kcp_random_invite_token();

    if generated_group_code !~ '^TST-[0-9A-F]{10}$' then
        raise exception 'Unexpected generated group code format: %', generated_group_code;
    end if;

    if generated_invite_code !~ '^[0-9A-F]{8}$' then
        raise exception 'Unexpected generated invitation token format: %', generated_invite_code;
    end if;
end;
$$;

commit;
