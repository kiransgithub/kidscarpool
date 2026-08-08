-- LOCAL TEST HARNESS ONLY. Never applied to Supabase, which provides these.
-- Emulates the parts of the Supabase auth schema the baseline depends on.
create schema if not exists auth;

create table if not exists auth.users (
    id uuid primary key default gen_random_uuid(),
    email text,
    is_anonymous boolean not null default false
);

create or replace function auth.uid() returns uuid
language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin;
    end if;
end $$;

grant usage on schema public to anon, authenticated;

-- Helper: act as a given user for the rest of the transaction/session.
create or replace function auth.become(p_user uuid) returns void
language sql as $$
    select set_config('request.jwt.claim.sub', p_user::text, false);
$$;
