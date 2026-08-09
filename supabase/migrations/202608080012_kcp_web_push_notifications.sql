begin;

-- ---------------------------------------------------------------------------
-- Web Push notification outbox
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_platform_settings (
    setting_key text primary key,
    setting_value text not null,
    updated_by uuid references auth.users(id) on delete set null,
    updated_at timestamptz not null default now()
);

create table if not exists public.kcp_push_subscriptions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    endpoint text not null unique,
    p256dh text not null,
    auth_secret text not null,
    user_agent text,
    device_label text,
    created_at timestamptz not null default now(),
    last_used_at timestamptz not null default now(),
    revoked_at timestamptz
);

create index if not exists kcp_push_subscriptions_user_active_idx
    on public.kcp_push_subscriptions(user_id, last_used_at desc)
    where revoked_at is null;

create table if not exists public.kcp_notification_preferences (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    scope_key text not null default 'global',
    group_id uuid references public.kcp_groups(id) on delete cascade,
    category text not null check (category in (
        'upcoming_ride','schedule_changed','cover_requested','cover_accepted',
        'cover_escalated','child_absence','driver_confirmation_due',
        'completion_due','trip_unconfirmed','admin_approval','invitation_accepted',
        'swap_requested','swap_resolved','points'
    )),
    enabled boolean not null default true,
    updated_at timestamptz not null default now(),
    unique (user_id, scope_key, category),
    check (
        (scope_key = 'global' and group_id is null)
        or (scope_key = 'group:' || group_id::text and group_id is not null)
    )
);

create table if not exists public.kcp_notification_outbox (
    id uuid primary key default gen_random_uuid(),
    target_user_id uuid not null references auth.users(id) on delete cascade,
    group_id uuid references public.kcp_groups(id) on delete cascade,
    trip_id uuid references public.kcp_trips(id) on delete cascade,
    category text not null,
    title text not null,
    body text not null,
    target_url text not null default './',
    payload jsonb not null default '{}'::jsonb,
    dedupe_key text not null unique,
    status text not null default 'pending'
        check (status in ('pending','processing','sent','partial','failed','cancelled')),
    attempts integer not null default 0,
    not_before timestamptz not null default now(),
    locked_at timestamptz,
    processed_at timestamptz,
    last_error text,
    created_at timestamptz not null default now()
);

create index if not exists kcp_notification_outbox_pending_idx
    on public.kcp_notification_outbox(not_before, created_at)
    where status in ('pending','failed');

create table if not exists public.kcp_notification_deliveries (
    id uuid primary key default gen_random_uuid(),
    outbox_id uuid not null references public.kcp_notification_outbox(id) on delete cascade,
    subscription_id uuid references public.kcp_push_subscriptions(id) on delete set null,
    status text not null check (status in ('sent','failed','gone','skipped')),
    response_code integer,
    error_message text,
    attempted_at timestamptz not null default now()
);

create index if not exists kcp_notification_deliveries_outbox_idx
    on public.kcp_notification_deliveries(outbox_id, attempted_at);

alter table public.kcp_platform_settings enable row level security;
alter table public.kcp_push_subscriptions enable row level security;
alter table public.kcp_notification_preferences enable row level security;
alter table public.kcp_notification_outbox enable row level security;
alter table public.kcp_notification_deliveries enable row level security;

revoke all on table public.kcp_platform_settings from public, anon, authenticated;
revoke all on table public.kcp_push_subscriptions from public, anon, authenticated;
revoke all on table public.kcp_notification_preferences from public, anon, authenticated;
revoke all on table public.kcp_notification_outbox from public, anon, authenticated;
revoke all on table public.kcp_notification_deliveries from public, anon, authenticated;

create or replace function public.kcp_set_platform_setting(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_platform_admin('super_admin') then
        raise exception 'Super Admin role required';
    end if;
    if length(trim(coalesce(p_key,''))) < 2 or length(trim(coalesce(p_value,''))) < 1 then
        raise exception 'Setting key and value are required';
    end if;
    insert into public.kcp_platform_settings(setting_key, setting_value, updated_by, updated_at)
    values (trim(p_key), trim(p_value), auth.uid(), now())
    on conflict (setting_key) do update
       set setting_value = excluded.setting_value,
           updated_by = auth.uid(),
           updated_at = now();
    perform public.kcp_write_platform_audit(
        'platform_setting_updated', 'platform_setting', trim(p_key),
        jsonb_build_object('valueLength', length(trim(p_value)))
    );
end;
$$;

create or replace function public.kcp_notification_public_config()
returns table(vapid_public_key text)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select setting_value
    from public.kcp_platform_settings
    where setting_key = 'web_push_public_key';
$$;

create or replace function public.kcp_register_push_subscription(
    p_endpoint text,
    p_p256dh text,
    p_auth_secret text,
    p_user_agent text default null,
    p_device_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result_id uuid;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if length(trim(coalesce(p_endpoint,''))) < 20
       or length(trim(coalesce(p_p256dh,''))) < 20
       or length(trim(coalesce(p_auth_secret,''))) < 8 then
        raise exception 'Push subscription is incomplete';
    end if;

    insert into public.kcp_push_subscriptions(
        user_id, endpoint, p256dh, auth_secret, user_agent,
        device_label, last_used_at, revoked_at
    ) values (
        auth.uid(), trim(p_endpoint), trim(p_p256dh), trim(p_auth_secret),
        nullif(trim(p_user_agent), ''), nullif(trim(p_device_label), ''),
        now(), null
    )
    on conflict (endpoint) do update
       set user_id = auth.uid(),
           p256dh = excluded.p256dh,
           auth_secret = excluded.auth_secret,
           user_agent = excluded.user_agent,
           device_label = excluded.device_label,
           last_used_at = now(),
           revoked_at = null
    returning id into result_id;
    return result_id;
end;
$$;

create or replace function public.kcp_revoke_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    update public.kcp_push_subscriptions
       set revoked_at = now()
     where endpoint = p_endpoint and user_id = auth.uid();
end;
$$;

create or replace function public.kcp_set_notification_preference(
    p_category text,
    p_enabled boolean,
    p_group_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    scope text := case when p_group_id is null then 'global' else 'group:' || p_group_id::text end;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    if p_group_id is not null and not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;
    if p_category not in (
        'upcoming_ride','schedule_changed','cover_requested','cover_accepted',
        'cover_escalated','child_absence','driver_confirmation_due',
        'completion_due','trip_unconfirmed','admin_approval','invitation_accepted',
        'swap_requested','swap_resolved','points'
    ) then raise exception 'Unknown notification category'; end if;

    insert into public.kcp_notification_preferences(
        user_id, scope_key, group_id, category, enabled, updated_at
    ) values (
        auth.uid(), scope, p_group_id, p_category, p_enabled, now()
    )
    on conflict (user_id, scope_key, category) do update
       set enabled = excluded.enabled, group_id = excluded.group_id, updated_at = now();
end;
$$;

create or replace function public.kcp_my_notification_preferences()
returns table(category text, global_enabled boolean)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    with categories(category) as (
        values
        ('upcoming_ride'),('schedule_changed'),('cover_requested'),('cover_accepted'),
        ('cover_escalated'),('child_absence'),('driver_confirmation_due'),
        ('completion_due'),('trip_unconfirmed'),('admin_approval'),
        ('invitation_accepted'),('swap_requested'),('swap_resolved'),('points')
    )
    select categories.category,
           coalesce(preference.enabled, true)
    from categories
    left join public.kcp_notification_preferences preference
      on preference.user_id = auth.uid()
     and preference.scope_key = 'global'
     and preference.category = categories.category
    order by categories.category;
$$;

create or replace function public.kcp_notification_enabled(
    p_user_id uuid,
    p_group_id uuid,
    p_category text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select coalesce(
        (
            select preference.enabled
            from public.kcp_notification_preferences preference
            where preference.user_id = p_user_id
              and preference.scope_key = 'group:' || p_group_id::text
              and preference.category = p_category
        ),
        (
            select preference.enabled
            from public.kcp_notification_preferences preference
            where preference.user_id = p_user_id
              and preference.scope_key = 'global'
              and preference.category = p_category
        ),
        true
    );
$$;

create or replace function public.kcp_enqueue_notification(
    p_target_user_id uuid,
    p_category text,
    p_group_id uuid,
    p_trip_id uuid,
    p_title text,
    p_body text,
    p_target_url text,
    p_payload jsonb,
    p_dedupe_key text,
    p_not_before timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result_id uuid;
begin
    if p_target_user_id is null or length(trim(coalesce(p_dedupe_key,''))) < 4 then return null; end if;
    if not public.kcp_notification_enabled(p_target_user_id, p_group_id, p_category) then return null; end if;

    insert into public.kcp_notification_outbox(
        target_user_id, group_id, trip_id, category, title, body,
        target_url, payload, dedupe_key, not_before
    ) values (
        p_target_user_id, p_group_id, p_trip_id, p_category,
        left(trim(p_title), 120), left(trim(p_body), 300),
        coalesce(nullif(trim(p_target_url), ''), './'),
        coalesce(p_payload, '{}'::jsonb), trim(p_dedupe_key),
        coalesce(p_not_before, now())
    )
    on conflict (dedupe_key) do update
       set title = excluded.title,
           body = excluded.body,
           target_url = excluded.target_url,
           payload = excluded.payload,
           not_before = least(public.kcp_notification_outbox.not_before, excluded.not_before),
           status = case
               when public.kcp_notification_outbox.status in ('failed','cancelled') then 'pending'
               else public.kcp_notification_outbox.status
           end
    returning id into result_id;
    return result_id;
end;
$$;

create or replace function public.kcp_cover_notification_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    recipient record;
    requester_name text;
begin
    select * into trip from public.kcp_trips where id = new.trip_id;
    select profile.display_name into requester_name from public.kcp_profiles profile where profile.id = new.requested_by;

    if tg_op = 'INSERT' and new.status = 'open' then
        for recipient in
            select participant.user_id
            from public.kcp_group_participants participant
            where participant.group_id = new.group_id
              and participant.status = 'active'
              and participant.can_drive
              and participant.user_id <> new.requested_by
        loop
            perform public.kcp_enqueue_notification(
                recipient.user_id, 'cover_requested', new.group_id, new.trip_id,
                'Ride needs coverage',
                coalesce(trip.display_label, 'Ride') || ' on ' || to_char(trip.scheduled_time, 'Mon DD at FMHH12:MI AM'),
                './?view=requests', jsonb_build_object('coverRequestId', new.id),
                'cover:' || new.id || ':open:' || recipient.user_id,
                now()
            );
        end loop;
    end if;

    if tg_op = 'UPDATE' and old.status = 'open' and new.status = 'accepted' then
        perform public.kcp_enqueue_notification(
            new.requested_by, 'cover_accepted', new.group_id, new.trip_id,
            'Coverage accepted',
            coalesce((select display_name from public.kcp_profiles where id = new.accepted_by), 'Another driver')
                || ' accepted ' || coalesce(trip.display_label, 'the ride'),
            './?view=requests', jsonb_build_object('coverRequestId', new.id),
            'cover:' || new.id || ':accepted:' || new.requested_by,
            now()
        );
    end if;

    if tg_op = 'UPDATE'
       and old.escalation_stage is distinct from new.escalation_stage
       and new.escalation_stage in ('group_admin','unresolved') then
        for recipient in
            select member.user_id
            from public.kcp_memberships member
            where member.group_id = new.group_id
              and member.status = 'active'
              and member.role in ('owner','admin')
        loop
            perform public.kcp_enqueue_notification(
                recipient.user_id, 'cover_escalated', new.group_id, new.trip_id,
                case when new.escalation_stage = 'unresolved' then 'Coverage unresolved' else 'Coverage needs admin attention' end,
                coalesce(trip.display_label, 'Ride') || ' is scheduled ' || to_char(trip.scheduled_time, 'Mon DD at FMHH12:MI AM'),
                './?view=requests', jsonb_build_object('coverRequestId', new.id, 'stage', new.escalation_stage),
                'cover:' || new.id || ':' || new.escalation_stage || ':' || recipient.user_id,
                now()
            );
        end loop;
    end if;
    return new;
end;
$$;

drop trigger if exists kcp_cover_notifications on public.kcp_cover_requests;
create trigger kcp_cover_notifications
after insert or update on public.kcp_cover_requests
for each row execute function public.kcp_cover_notification_trigger();

create or replace function public.kcp_absence_notification_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    child_name text;
    trip_record record;
    category_body text;
begin
    if new.status <> 'active' or not new.notify_driver then return new; end if;
    select child.name into child_name from public.kcp_children child where child.id = new.child_id;
    category_body := child_name || ': ' || replace(new.reason, '_', ' ');

    for trip_record in
        select trip.id, trip.scheduled_driver_id, trip.actual_driver_id, trip.display_label, trip.scheduled_time
        from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        where trip.group_id = new.group_id
          and trip.schedule_version = group_row.current_schedule_version
          and child_name = any(trip.child_names)
          and (
              trip.id = new.trip_id
              or (new.trip_id is null and trip.trip_date between new.starts_on and new.ends_on)
          )
          and trip.started_at is null
    loop
        perform public.kcp_enqueue_notification(
            coalesce(trip_record.actual_driver_id, trip_record.scheduled_driver_id),
            'child_absence', new.group_id, trip_record.id,
            'Child ride update', category_body,
            './?view=requests', jsonb_build_object('absenceReportId', new.id, 'childName', child_name),
            'absence:' || new.id || ':trip:' || trip_record.id || ':driver',
            now()
        );
    end loop;
    return new;
end;
$$;

drop trigger if exists kcp_absence_notifications on public.kcp_child_absence_reports;
create trigger kcp_absence_notifications
after insert or update of status on public.kcp_child_absence_reports
for each row execute function public.kcp_absence_notification_trigger();

create or replace function public.kcp_trip_status_notification_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    driver_id uuid := coalesce(new.actual_driver_id, new.scheduled_driver_id);
    admin record;
begin
    if old.status is not distinct from new.status then return new; end if;

    if new.status = 'confirmation_due' then
        perform public.kcp_enqueue_notification(
            driver_id, 'driver_confirmation_due', new.group_id, new.id,
            'Confirm your ride', coalesce(new.display_label, 'Ride') || ' is scheduled now',
            './?view=schedule', jsonb_build_object('tripId', new.id),
            'trip:' || new.id || ':confirmation_due:' || driver_id, now()
        );
    elsif new.status = 'completion_due' then
        perform public.kcp_enqueue_notification(
            driver_id, 'completion_due', new.group_id, new.id,
            'Confirm ride completion', coalesce(new.display_label, 'Ride') || ' still needs explicit completion confirmation',
            './?view=schedule', jsonb_build_object('tripId', new.id),
            'trip:' || new.id || ':completion_due:' || driver_id, now()
        );
    elsif new.status = 'unconfirmed' then
        perform public.kcp_enqueue_notification(
            driver_id, 'trip_unconfirmed', new.group_id, new.id,
            'Ride outcome unconfirmed', coalesce(new.display_label, 'Ride') || ' needs resolution',
            './?view=schedule', jsonb_build_object('tripId', new.id),
            'trip:' || new.id || ':unconfirmed:' || driver_id, now()
        );
        for admin in
            select member.user_id from public.kcp_memberships member
            where member.group_id = new.group_id and member.status = 'active' and member.role in ('owner','admin')
        loop
            perform public.kcp_enqueue_notification(
                admin.user_id, 'trip_unconfirmed', new.group_id, new.id,
                'Ride needs admin review', coalesce(new.display_label, 'Ride') || ' is unconfirmed',
                './?view=requests', jsonb_build_object('tripId', new.id),
                'trip:' || new.id || ':unconfirmed-admin:' || admin.user_id, now()
            );
        end loop;
    end if;
    return new;
end;
$$;

drop trigger if exists kcp_trip_status_notifications on public.kcp_trips;
create trigger kcp_trip_status_notifications
after update of status on public.kcp_trips
for each row execute function public.kcp_trip_status_notification_trigger();

create or replace function public.kcp_swap_notification_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if tg_op = 'INSERT' then
        perform public.kcp_enqueue_notification(
            new.requested_from, 'swap_requested', new.group_id, new.offered_trip_id,
            'Ride swap requested',
            coalesce((select display_name from public.kcp_profiles where id = new.requested_by), 'Another driver') || ' requested a ride swap',
            './?view=requests', jsonb_build_object('swapId', new.id),
            'swap:' || new.id || ':requested:' || new.requested_from, now()
        );
    elsif old.status = 'pending' and new.status in ('accepted','rejected','cancelled','expired') then
        perform public.kcp_enqueue_notification(
            new.requested_by, 'swap_resolved', new.group_id, new.offered_trip_id,
            'Ride swap ' || new.status,
            'The requested ride swap is now ' || new.status,
            './?view=requests', jsonb_build_object('swapId', new.id, 'status', new.status),
            'swap:' || new.id || ':' || new.status || ':' || new.requested_by, now()
        );
    end if;
    return new;
end;
$$;

drop trigger if exists kcp_swap_notifications on public.kcp_trip_swap_requests;
create trigger kcp_swap_notifications
after insert or update of status on public.kcp_trip_swap_requests
for each row execute function public.kcp_swap_notification_trigger();

create or replace function public.kcp_enqueue_trip_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    trip_record record;
    recipient record;
    created_count integer := 0;
    result_id uuid;
begin
    for trip_record in
        select trip.*
        from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        where trip.schedule_version = group_row.current_schedule_version
          and trip.status in ('scheduled','cover_accepted','ready')
          and trip.scheduled_time > p_now + interval '25 minutes'
          and trip.scheduled_time <= p_now + interval '35 minutes'
    loop
        for recipient in
            select distinct user_id from (
                select coalesce(trip_record.actual_driver_id, trip_record.scheduled_driver_id) as user_id
                union all
                select participant.user_id
                from public.kcp_children child
                join public.kcp_group_participants participant on participant.id = child.participant_id
                where child.group_id = trip_record.group_id
                  and child.name = any(trip_record.child_names)
                  and participant.status = 'active'
            ) recipients
            where user_id is not null
        loop
            result_id := public.kcp_enqueue_notification(
                recipient.user_id, 'upcoming_ride', trip_record.group_id, trip_record.id,
                'Ride in 30 minutes',
                coalesce(trip_record.display_label, 'Ride') || ' at ' || to_char(trip_record.scheduled_time, 'FMHH12:MI AM'),
                './?view=schedule', jsonb_build_object('tripId', trip_record.id),
                'trip:' || trip_record.id || ':reminder30:' || recipient.user_id,
                now()
            );
            if result_id is not null then created_count := created_count + 1; end if;
        end loop;
    end loop;
    return created_count;
end;
$$;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'kcp-trip-reminder-enqueue') then
        perform cron.unschedule('kcp-trip-reminder-enqueue');
    end if;
    perform cron.schedule(
        'kcp-trip-reminder-enqueue',
        '*/5 * * * *',
        'select public.kcp_enqueue_trip_reminders(now());'
    );
end;
$$;

revoke all on function public.kcp_set_platform_setting(text,text) from public, anon;
revoke all on function public.kcp_notification_public_config() from public, anon;
revoke all on function public.kcp_register_push_subscription(text,text,text,text,text) from public, anon;
revoke all on function public.kcp_revoke_push_subscription(text) from public, anon;
revoke all on function public.kcp_set_notification_preference(text,boolean,uuid) from public, anon;
revoke all on function public.kcp_my_notification_preferences() from public, anon;
revoke all on function public.kcp_notification_enabled(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.kcp_enqueue_notification(uuid,text,uuid,uuid,text,text,text,jsonb,text,timestamptz) from public, anon, authenticated;
revoke all on function public.kcp_enqueue_trip_reminders(timestamptz) from public, anon, authenticated;

grant execute on function public.kcp_set_platform_setting(text,text) to authenticated;
grant execute on function public.kcp_notification_public_config() to authenticated;
grant execute on function public.kcp_register_push_subscription(text,text,text,text,text) to authenticated;
grant execute on function public.kcp_revoke_push_subscription(text) to authenticated;
grant execute on function public.kcp_set_notification_preference(text,boolean,uuid) to authenticated;
grant execute on function public.kcp_my_notification_preferences() to authenticated;

commit;
