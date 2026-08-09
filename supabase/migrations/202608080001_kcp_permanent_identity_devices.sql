begin;

-- ---------------------------------------------------------------------------
-- Permanent identity and multi-device account support
-- ---------------------------------------------------------------------------

alter table public.kcp_profiles
    add column if not exists account_email text,
    add column if not exists identity_verified_at timestamptz;

create unique index if not exists kcp_profiles_account_email_unique
    on public.kcp_profiles (lower(account_email))
    where account_email is not null;

create table if not exists public.kcp_devices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    device_id text not null,
    label text not null default 'KCP device',
    platform text not null default 'web',
    app_version text,
    first_seen_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    revoked_at timestamptz,
    revoked_reason text,
    unique (user_id, device_id),
    check (length(device_id) between 8 and 200),
    check (length(label) between 1 and 120),
    check (length(platform) between 1 and 40)
);

create index if not exists kcp_devices_user_active_idx
    on public.kcp_devices(user_id, last_seen_at desc)
    where revoked_at is null;

alter table public.kcp_devices enable row level security;

drop policy if exists kcp_devices_self_select on public.kcp_devices;
create policy kcp_devices_self_select
on public.kcp_devices for select to authenticated
using (user_id = auth.uid());

drop policy if exists kcp_devices_self_insert on public.kcp_devices;
create policy kcp_devices_self_insert
on public.kcp_devices for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists kcp_devices_self_update on public.kcp_devices;
create policy kcp_devices_self_update
on public.kcp_devices for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create or replace function public.kcp_identity_status()
returns table(
    user_id uuid,
    email text,
    is_anonymous boolean,
    email_confirmed_at timestamptz,
    identity_verified boolean
)
language sql
stable
security definer
set search_path = public, auth, pg_catalog
as $$
    select
        auth_user.id,
        auth_user.email,
        coalesce(auth_user.is_anonymous, false),
        auth_user.email_confirmed_at,
        coalesce(auth_user.is_anonymous, false) = false
            and auth_user.email is not null
            and auth_user.email_confirmed_at is not null
    from auth.users auth_user
    where auth_user.id = auth.uid();
$$;

create or replace function public.kcp_register_device(
    p_device_id text,
    p_label text default 'KCP device',
    p_platform text default 'web',
    p_app_version text default null
)
returns table(
    device_id text,
    label text,
    platform text,
    app_version text,
    first_seen_at timestamptz,
    last_seen_at timestamptz,
    revoked_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    normalized_id text := nullif(trim(p_device_id), '');
    normalized_label text := coalesce(nullif(trim(p_label), ''), 'KCP device');
    normalized_platform text := coalesce(nullif(trim(p_platform), ''), 'web');
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if normalized_id is null or length(normalized_id) < 8 then
        raise exception 'A stable device identifier is required';
    end if;

    insert into public.kcp_devices(
        user_id, device_id, label, platform, app_version,
        first_seen_at, last_seen_at, revoked_at, revoked_reason
    ) values (
        auth.uid(), normalized_id, normalized_label, normalized_platform,
        nullif(trim(p_app_version), ''), now(), now(), null, null
    )
    on conflict (user_id, device_id) do update
       set label = excluded.label,
           platform = excluded.platform,
           app_version = excluded.app_version,
           last_seen_at = now();

    return query
    select
        device.device_id,
        device.label,
        device.platform,
        device.app_version,
        device.first_seen_at,
        device.last_seen_at,
        device.revoked_at
    from public.kcp_devices device
    where device.user_id = auth.uid()
      and device.device_id = normalized_id;
end;
$$;

create or replace function public.kcp_list_my_devices()
returns table(
    device_id text,
    label text,
    platform text,
    app_version text,
    first_seen_at timestamptz,
    last_seen_at timestamptz,
    revoked_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select
        device.device_id,
        device.label,
        device.platform,
        device.app_version,
        device.first_seen_at,
        device.last_seen_at,
        device.revoked_at
    from public.kcp_devices device
    where device.user_id = auth.uid()
    order by device.last_seen_at desc;
$$;

create or replace function public.kcp_revoke_device(
    p_device_id text,
    p_reason text default 'Revoked by account owner'
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    update public.kcp_devices
       set revoked_at = now(),
           revoked_reason = coalesce(nullif(trim(p_reason), ''), 'Revoked by account owner')
     where user_id = auth.uid()
       and device_id = trim(p_device_id)
       and revoked_at is null;

    if not found then raise exception 'Device was not found or is already revoked'; end if;
end;
$$;

create or replace function public.kcp_current_device_allowed(p_device_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1
        from public.kcp_devices device
        where device.user_id = auth.uid()
          and device.device_id = trim(p_device_id)
          and device.revoked_at is null
    );
$$;

create or replace function public.kcp_record_identity_upgrade()
returns table(email text, verified_at timestamptz)
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
    auth_user auth.users;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into auth_user
    from auth.users
    where id = auth.uid();

    if not found then raise exception 'Authentication identity was not found'; end if;
    if coalesce(auth_user.is_anonymous, false) then
        raise exception 'Verify the email link before completing account setup';
    end if;
    if auth_user.email is null or auth_user.email_confirmed_at is null then
        raise exception 'A verified email identity is required';
    end if;

    update public.kcp_profiles
       set account_email = lower(auth_user.email),
           identity_verified_at = coalesce(identity_verified_at, auth_user.email_confirmed_at),
           updated_at = now()
     where id = auth.uid();

    insert into public.kcp_audit_events(
        group_id, actor_id, action, entity_type, entity_id, details, occurred_at
    )
    select
        membership.group_id,
        auth.uid(),
        'identity_upgraded',
        'profile',
        auth.uid()::text,
        jsonb_build_object('method', 'email', 'verifiedAt', auth_user.email_confirmed_at),
        now()
    from public.kcp_memberships membership
    where membership.user_id = auth.uid()
      and membership.status = 'active'
      and not exists (
          select 1
          from public.kcp_audit_events audit
          where audit.group_id = membership.group_id
            and audit.action = 'identity_upgraded'
            and audit.entity_type = 'profile'
            and audit.entity_id = auth.uid()::text
      );

    return query select lower(auth_user.email), auth_user.email_confirmed_at;
end;
$$;

revoke all on table public.kcp_devices from public, anon;
grant select, insert, update on public.kcp_devices to authenticated;

revoke all on function public.kcp_identity_status() from public, anon;
revoke all on function public.kcp_register_device(text,text,text,text) from public, anon;
revoke all on function public.kcp_list_my_devices() from public, anon;
revoke all on function public.kcp_revoke_device(text,text) from public, anon;
revoke all on function public.kcp_current_device_allowed(text) from public, anon;
revoke all on function public.kcp_record_identity_upgrade() from public, anon;

grant execute on function public.kcp_identity_status() to authenticated;
grant execute on function public.kcp_register_device(text,text,text,text) to authenticated;
grant execute on function public.kcp_list_my_devices() to authenticated;
grant execute on function public.kcp_revoke_device(text,text) to authenticated;
grant execute on function public.kcp_current_device_allowed(text) to authenticated;
grant execute on function public.kcp_record_identity_upgrade() to authenticated;

commit;
