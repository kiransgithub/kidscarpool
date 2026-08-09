begin;

-- A magic-link sign-in can create a new Auth UUID when an older device-scoped
-- account already exists. Prove ownership with the verified Auth email, create
-- the current profile when needed, and move active group access atomically.
create or replace function public.kcp_resume_verified_account(
    p_display_name text default null
)
returns table(
    profile_id uuid,
    display_name text,
    account_email text,
    recovered_groups integer
)
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
#variable_conflict use_column
declare
    auth_user auth.users;
    source_profile public.kcp_profiles;
    current_profile public.kcp_profiles;
    source_membership record;
    resolved_name text;
    recovered_count integer := 0;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;

    select * into auth_user
      from auth.users
     where id = auth.uid()
     for update;

    if not found then raise exception 'Authentication identity was not found'; end if;
    if coalesce(auth_user.is_anonymous, false)
       or auth_user.email is null
       or auth_user.email_confirmed_at is null then
        raise exception 'Open the verified email link before continuing';
    end if;

    resolved_name := left(coalesce(
        nullif(trim(p_display_name), ''),
        nullif(trim(auth_user.raw_user_meta_data ->> 'full_name'), ''),
        nullif(trim(auth_user.raw_user_meta_data ->> 'name'), ''),
        nullif(initcap(replace(replace(split_part(auth_user.email, '@', 1), '.', ' '), '_', ' ')), ''),
        'KCP member'
    ), 80);

    select profile.* into current_profile
      from public.kcp_profiles profile
     where profile.id = auth.uid()
     for update;

    select profile.* into source_profile
      from public.kcp_profiles profile
     where profile.id <> auth.uid()
       and lower(profile.account_email) = lower(auth_user.email)
     order by profile.identity_verified_at desc nulls last, profile.updated_at desc
     limit 1
     for update;

    if found then
        -- Release the unique verified-email value before attaching it to the
        -- current Auth UUID. The previous profile and audit history remain.
        update public.kcp_profiles
           set account_email = null,
               updated_at = now()
         where id = source_profile.id;

        insert into public.kcp_profiles(
            id, display_name, phone, account_email, identity_verified_at
        ) values (
            auth.uid(), source_profile.display_name, source_profile.phone,
            lower(auth_user.email), auth_user.email_confirmed_at
        )
        on conflict (id) do update
           set display_name = excluded.display_name,
               phone = coalesce(excluded.phone, public.kcp_profiles.phone),
               account_email = excluded.account_email,
               identity_verified_at = coalesce(
                   public.kcp_profiles.identity_verified_at,
                   excluded.identity_verified_at
               ),
               updated_at = now();

        for source_membership in
            select membership.group_id
              from public.kcp_memberships membership
             where membership.user_id = source_profile.id
               and membership.status = 'active'
             order by membership.group_id
        loop
            perform public.kcp_transfer_group_membership(
                source_membership.group_id,
                source_profile.id,
                auth.uid(),
                'verified email sign-in recovery'
            );
            recovered_count := recovered_count + 1;
        end loop;

        update public.kcp_device_links device_link
           set user_id = auth.uid(),
               last_used_at = now()
         where device_link.user_id = source_profile.id;
    else
        insert into public.kcp_profiles(
            id, display_name, account_email, identity_verified_at
        ) values (
            auth.uid(), resolved_name, lower(auth_user.email), auth_user.email_confirmed_at
        )
        on conflict (id) do update
           set account_email = lower(auth_user.email),
               identity_verified_at = coalesce(
                   public.kcp_profiles.identity_verified_at,
                   auth_user.email_confirmed_at
               ),
               updated_at = now();
    end if;

    return query
    select
        profile.id,
        profile.display_name,
        profile.account_email,
        recovered_count
      from public.kcp_profiles profile
     where profile.id = auth.uid();
end;
$$;

revoke all on function public.kcp_resume_verified_account(text) from public, anon;
grant execute on function public.kcp_resume_verified_account(text) to authenticated;

commit;
