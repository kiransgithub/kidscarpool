begin;

-- ---------------------------------------------------------------------------
-- Revoke credentials tied to an identity that has been removed from a group.
-- The one credential actively used by kcp_restore_device_link is reactivated
-- when its user_id moves to the replacement identity.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_revoke_device_links_after_membership_removal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if old.status = 'active' and new.status = 'removed' then
        update public.kcp_device_links dl
           set revoked_at = coalesce(dl.revoked_at, now())
         where dl.group_id = new.group_id
           and dl.user_id = new.user_id
           and dl.revoked_at is null;
    end if;

    return new;
end;
$$;

create or replace function public.kcp_reactivate_transferred_device_link()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
    if old.user_id is distinct from new.user_id then
        new.revoked_at := null;
        new.last_used_at := coalesce(new.last_used_at, now());
    end if;

    return new;
end;
$$;

drop trigger if exists kcp_membership_removal_revoke_devices
on public.kcp_memberships;

create trigger kcp_membership_removal_revoke_devices
after update of status on public.kcp_memberships
for each row
when (old.status = 'active' and new.status = 'removed')
execute function public.kcp_revoke_device_links_after_membership_removal();

drop trigger if exists kcp_device_link_identity_transfer
on public.kcp_device_links;

create trigger kcp_device_link_identity_transfer
before update of user_id on public.kcp_device_links
for each row
when (old.user_id is distinct from new.user_id)
execute function public.kcp_reactivate_transferred_device_link();

revoke all on function public.kcp_revoke_device_links_after_membership_removal()
from public, anon, authenticated;
revoke all on function public.kcp_reactivate_transferred_device_link()
from public, anon, authenticated;

commit;
