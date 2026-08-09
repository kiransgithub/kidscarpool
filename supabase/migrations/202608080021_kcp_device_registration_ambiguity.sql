begin;

-- Migration 001 may already be recorded on a live project, so repair the RPC
-- additively. Naming the unique constraint avoids resolving the RETURNS TABLE
-- output column `device_id` as an ON CONFLICT target.
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
    on conflict on constraint kcp_devices_user_id_device_id_key do update
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

revoke all on function public.kcp_register_device(text,text,text,text)
from public, anon;
grant execute on function public.kcp_register_device(text,text,text,text)
to authenticated;

commit;
