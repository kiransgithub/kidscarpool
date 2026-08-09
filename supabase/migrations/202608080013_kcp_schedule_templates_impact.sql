begin;

-- ---------------------------------------------------------------------------
-- Generic schedule templates, conflicts, impact review and acknowledgements
-- ---------------------------------------------------------------------------

create table if not exists public.kcp_schedule_templates (
    template_key text primary key,
    name text not null,
    description text not null,
    group_kind text,
    config jsonb not null,
    display_order integer not null default 0,
    active boolean not null default true,
    updated_at timestamptz not null default now(),
    check (jsonb_typeof(config) = 'object')
);

insert into public.kcp_schedule_templates(template_key, name, description, group_kind, config, display_order)
values
('school_weekdays','School weekdays','Monday through Friday with drop-off and pickup. Enter the actual times.','school',
 '{"weekdays":[1,2,3,4,5],"outboundEnabled":true,"returnEnabled":true,"strategy":"balanced","outboundLabel":"School drop-off","returnLabel":"School pickup"}'::jsonb,10),
('single_activity','One recurring activity','Choose one or more activity days and enter each day’s times.',null,
 '{"weekdays":[],"outboundEnabled":true,"returnEnabled":true,"strategy":"fixed","outboundLabel":"Drop-off","returnLabel":"Pickup"}'::jsonb,20),
('weekly_rotation','Multi-day weekly rotation','One driver handles every selected ride for the assigned week.',null,
 '{"weekdays":[],"outboundEnabled":true,"returnEnabled":true,"strategy":"round_robin_week","outboundLabel":"Drop-off","returnLabel":"Pickup"}'::jsonb,30),
('pickup_only','Pickup-only group','Generate only return or pickup rides on selected days.',null,
 '{"weekdays":[],"outboundEnabled":false,"returnEnabled":true,"strategy":"balanced","outboundLabel":"Outbound","returnLabel":"Pickup"}'::jsonb,40),
('custom','Custom schedule','Start with an empty week and configure every rule.',null,
 '{"weekdays":[],"outboundEnabled":true,"returnEnabled":true,"strategy":"manual","outboundLabel":"Outbound","returnLabel":"Return"}'::jsonb,50)
on conflict (template_key) do update
set name = excluded.name,
    description = excluded.description,
    group_kind = excluded.group_kind,
    config = excluded.config,
    display_order = excluded.display_order,
    active = true,
    updated_at = now();

create table if not exists public.kcp_schedule_change_sets (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.kcp_groups(id) on delete cascade,
    plan_id uuid not null references public.kcp_schedule_plans(id) on delete cascade,
    from_schedule_version integer not null,
    to_schedule_version integer,
    status text not null default 'previewed'
        check (status in ('previewed','published','superseded','cancelled')),
    reason text,
    summary jsonb not null default '{}'::jsonb,
    requires_acknowledgement boolean not null default false,
    created_by uuid not null references public.kcp_profiles(id) on delete restrict,
    created_at timestamptz not null default now(),
    published_at timestamptz
);

create index if not exists kcp_schedule_change_sets_group_created_idx
    on public.kcp_schedule_change_sets(group_id, created_at desc);

create table if not exists public.kcp_schedule_change_impacts (
    id uuid primary key default gen_random_uuid(),
    change_set_id uuid not null references public.kcp_schedule_change_sets(id) on delete cascade,
    impact_type text not null check (impact_type in (
        'added','removed','time_changed','driver_changed','cross_group_conflict'
    )),
    trip_date date not null,
    leg_type text,
    old_trip_id uuid references public.kcp_trips(id) on delete set null,
    old_time timestamptz,
    new_time timestamptz,
    old_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    new_participant_id uuid references public.kcp_group_participants(id) on delete set null,
    affected_user_id uuid references auth.users(id) on delete set null,
    details jsonb not null default '{}'::jsonb
);

create index if not exists kcp_schedule_change_impacts_set_idx
    on public.kcp_schedule_change_impacts(change_set_id, impact_type, trip_date);

create table if not exists public.kcp_schedule_acknowledgements (
    change_set_id uuid not null references public.kcp_schedule_change_sets(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending','acknowledged','declined')),
    note text,
    acknowledged_at timestamptz,
    primary key (change_set_id, user_id)
);

alter table public.kcp_schedule_templates enable row level security;
alter table public.kcp_schedule_change_sets enable row level security;
alter table public.kcp_schedule_change_impacts enable row level security;
alter table public.kcp_schedule_acknowledgements enable row level security;

revoke all on table public.kcp_schedule_templates from public, anon, authenticated;
revoke all on table public.kcp_schedule_change_sets from public, anon, authenticated;
revoke all on table public.kcp_schedule_change_impacts from public, anon, authenticated;
revoke all on table public.kcp_schedule_acknowledgements from public, anon, authenticated;

create or replace function public.kcp_list_schedule_templates(p_group_kind text default null)
returns table(template_key text, name text, description text, config jsonb)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select template.template_key, template.name, template.description, template.config
    from public.kcp_schedule_templates template
    where template.active
      and (template.group_kind is null or p_group_kind is null or template.group_kind = p_group_kind)
    order by template.display_order, template.name;
$$;

create or replace function public.kcp_detect_user_conflicts(
    p_user_id uuid default auth.uid(),
    p_from timestamptz default now(),
    p_to timestamptz default now() + interval '90 days'
)
returns table(
    first_trip_id uuid,
    first_group_id uuid,
    first_group_name text,
    first_label text,
    first_start timestamptz,
    first_end timestamptz,
    second_trip_id uuid,
    second_group_id uuid,
    second_group_name text,
    second_label text,
    second_start timestamptz,
    second_end timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
    if p_user_id <> auth.uid() and not public.kcp_is_platform_admin('support_admin') then
        raise exception 'You can inspect only your own assignment conflicts';
    end if;

    return query
    with assignments as (
        select trip.id, trip.group_id, group_row.name as group_name,
               coalesce(trip.display_label, 'Ride') as label,
               trip.scheduled_time as starts_at,
               trip.scheduled_time + make_interval(mins => group_row.auto_complete_after_minutes) as ends_at
        from public.kcp_trips trip
        join public.kcp_groups group_row on group_row.id = trip.group_id
        join public.kcp_memberships member
          on member.group_id = trip.group_id
         and member.user_id = p_user_id
         and member.status = 'active'
        where trip.schedule_version = group_row.current_schedule_version
          and coalesce(trip.actual_driver_id, trip.scheduled_driver_id) = p_user_id
          and trip.status not in ('completed','cancelled')
          and trip.scheduled_time between p_from and p_to
    )
    select first.id, first.group_id, first.group_name, first.label, first.starts_at, first.ends_at,
           second.id, second.group_id, second.group_name, second.label, second.starts_at, second.ends_at
    from assignments first
    join assignments second on second.id > first.id
      and second.group_id <> first.group_id
      and tstzrange(first.starts_at, first.ends_at, '[)') && tstzrange(second.starts_at, second.ends_at, '[)')
    order by first.starts_at, second.starts_at;
end;
$$;

do $$
begin
    create type public.kcp_schedule_change_compare_row as (
        trip_date date,
        leg_type text,
        old_trip_id uuid,
        old_time timestamptz,
        new_time timestamptz,
        old_participant_id uuid,
        new_participant_id uuid,
        impact_type text,
        display_label text
    );
exception when duplicate_object then null;
end;
$$;

create or replace function public.kcp_prepare_schedule_change(
    p_plan_id uuid,
    p_reason text default 'Schedule update preview'
)
returns table(change_set_id uuid, summary jsonb, requires_acknowledgement boolean)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    plan public.kcp_schedule_plans;
    group_record public.kcp_groups;
    set_id uuid;
    summary_value jsonb;
    requires_ack boolean;
    compare_rows public.kcp_schedule_change_compare_row[];
begin
    select * into plan from public.kcp_schedule_plans where id = p_plan_id for update;
    if not found then raise exception 'Schedule plan not found'; end if;
    if not public.kcp_is_admin(plan.group_id) then raise exception 'Owner or admin role required'; end if;
    if plan.status <> 'draft' then raise exception 'Only a draft plan can be reviewed'; end if;
    select * into group_record from public.kcp_groups where id = plan.group_id;

    update public.kcp_schedule_change_sets
       set status = 'superseded'
     where plan_id = plan.id and created_by = auth.uid() and status = 'previewed';

    select coalesce(array_agg(row(
        comparison.trip_date,
        comparison.leg_type,
        comparison.old_trip_id,
        comparison.old_time,
        comparison.new_time,
        comparison.old_participant_id,
        comparison.new_participant_id,
        comparison.impact_type,
        comparison.display_label
    )::public.kcp_schedule_change_compare_row), array[]::public.kcp_schedule_change_compare_row[])
    into compare_rows
    from (
    with occurrence_json as (
        select to_jsonb(occurrence) as item
        from public.kcp_plan_occurrences(plan.id, plan.starts_on, plan.ends_on, 10000) occurrence
    ), candidate_base as (
        select
            (item->>'actual_date')::date as trip_date,
            item->>'leg_type' as leg_type,
            item->>'display_label' as display_label,
            item->>'session_name' as session_name,
            nullif(item->>'participant_id','')::uuid as participant_id,
            ((item->>'actual_date')::date::text || ' ' || (item->>'local_time'))::timestamp at time zone plan.timezone as scheduled_time
        from occurrence_json
    ), candidates as (
        select candidate_base.*,
               row_number() over (
                   partition by trip_date, leg_type
                   order by scheduled_time, session_name, coalesce(participant_id::text,'')
               ) as ordinal
        from candidate_base
    ), current_base as (
        select trip.id as trip_id, trip.trip_date,
               coalesce(trip.leg_type, case when trip.kind = 'afternoon_pickup' then 'return' else 'outbound' end) as leg_type,
               trip.scheduled_time,
               trip.scheduled_participant_id as participant_id,
               coalesce(trip.display_label, 'Ride') as display_label
        from public.kcp_trips trip
        where trip.group_id = plan.group_id
          and trip.schedule_version = group_record.current_schedule_version
          and trip.trip_date between plan.starts_on and plan.ends_on
          and trip.status not in ('completed','cancelled')
    ), current_rows as (
        select current_base.*,
               row_number() over (
                   partition by trip_date, leg_type
                   order by scheduled_time, trip_id
               ) as ordinal
        from current_base
    )
    select
        coalesce(candidate.trip_date, current_row.trip_date) as trip_date,
        coalesce(candidate.leg_type, current_row.leg_type) as leg_type,
        current_row.trip_id as old_trip_id,
        current_row.scheduled_time as old_time,
        candidate.scheduled_time as new_time,
        current_row.participant_id as old_participant_id,
        candidate.participant_id as new_participant_id,
        case
            when current_row.trip_id is null then 'added'
            when candidate.trip_date is null then 'removed'
            when current_row.scheduled_time is distinct from candidate.scheduled_time then 'time_changed'
            when current_row.participant_id is distinct from candidate.participant_id then 'driver_changed'
            else 'unchanged'
        end as impact_type,
        coalesce(candidate.display_label, current_row.display_label) as display_label
    from candidates candidate
    full join current_rows current_row
      on current_row.trip_date = candidate.trip_date
     and current_row.leg_type = candidate.leg_type
     and current_row.ordinal = candidate.ordinal
    ) comparison;

    insert into public.kcp_schedule_change_sets(
        group_id, plan_id, from_schedule_version, status, reason, created_by
    ) values (
        plan.group_id, plan.id, group_record.current_schedule_version,
        'previewed', nullif(trim(p_reason), ''), auth.uid()
    ) returning id into set_id;

    insert into public.kcp_schedule_change_impacts(
        change_set_id, impact_type, trip_date, leg_type, old_trip_id,
        old_time, new_time, old_participant_id, new_participant_id,
        affected_user_id, details
    )
    select set_id, compare.impact_type, compare.trip_date, compare.leg_type,
           compare.old_trip_id, compare.old_time, compare.new_time,
           compare.old_participant_id, compare.new_participant_id,
           coalesce(new_participant.user_id, old_participant.user_id),
           jsonb_build_object('label', compare.display_label)
    from unnest(compare_rows) compare
    left join public.kcp_group_participants old_participant on old_participant.id = compare.old_participant_id
    left join public.kcp_group_participants new_participant on new_participant.id = compare.new_participant_id
    where compare.impact_type <> 'unchanged';

    -- Compare candidate assignments with current assignments in other groups.
    insert into public.kcp_schedule_change_impacts(
        change_set_id, impact_type, trip_date, leg_type,
        new_time, new_participant_id, affected_user_id, details
    )
    select distinct set_id, 'cross_group_conflict', compare.trip_date, compare.leg_type,
           compare.new_time, compare.new_participant_id, participant.user_id,
           jsonb_build_object(
               'label', compare.display_label,
               'conflictTripId', other_trip.id,
               'conflictGroupId', other_group.id,
               'conflictGroupName', other_group.name,
               'conflictLabel', coalesce(other_trip.display_label, 'Ride'),
               'conflictTime', other_trip.scheduled_time
           )
    from unnest(compare_rows) compare
    join public.kcp_group_participants participant on participant.id = compare.new_participant_id
    join public.kcp_trips other_trip
      on coalesce(other_trip.actual_driver_id, other_trip.scheduled_driver_id) = participant.user_id
     and other_trip.group_id <> plan.group_id
     and other_trip.status not in ('completed','cancelled')
     and other_trip.scheduled_time is not null
    join public.kcp_groups other_group
      on other_group.id = other_trip.group_id
     and other_trip.schedule_version = other_group.current_schedule_version
    where compare.new_time is not null
      and tstzrange(
          compare.new_time,
          compare.new_time + make_interval(mins => plan.auto_complete_after_minutes),
          '[)'
      ) && tstzrange(
          other_trip.scheduled_time,
          other_trip.scheduled_time + make_interval(mins => other_group.auto_complete_after_minutes),
          '[)'
      );

    select jsonb_build_object(
        'totalCandidateRides', (select count(*) from unnest(compare_rows) compare where compare.new_time is not null),
        'added', (select count(*) from public.kcp_schedule_change_impacts where change_set_id = set_id and impact_type = 'added'),
        'removed', (select count(*) from public.kcp_schedule_change_impacts where change_set_id = set_id and impact_type = 'removed'),
        'timeChanged', (select count(*) from public.kcp_schedule_change_impacts where change_set_id = set_id and impact_type = 'time_changed'),
        'driverChanged', (select count(*) from public.kcp_schedule_change_impacts where change_set_id = set_id and impact_type = 'driver_changed'),
        'conflicts', (select count(*) from public.kcp_schedule_change_impacts where change_set_id = set_id and impact_type = 'cross_group_conflict'),
        'affectedUsers', (select count(distinct affected_user_id) from public.kcp_schedule_change_impacts where change_set_id = set_id and affected_user_id is not null),
        'urgentImpacts', (select count(*) from public.kcp_schedule_change_impacts where change_set_id = set_id and coalesce(new_time, old_time) <= now() + interval '24 hours')
    ) into summary_value;

    requires_ack := coalesce((summary_value->>'urgentImpacts')::integer, 0) > 0;
    update public.kcp_schedule_change_sets
       set summary = summary_value, requires_acknowledgement = requires_ack
     where id = set_id;

    if requires_ack then
        insert into public.kcp_schedule_acknowledgements(change_set_id, user_id, status)
        select distinct set_id, impact.affected_user_id, 'pending'
        from public.kcp_schedule_change_impacts impact
        where impact.change_set_id = set_id
          and impact.affected_user_id is not null
          and impact.affected_user_id <> auth.uid()
          and coalesce(impact.new_time, impact.old_time) <= now() + interval '24 hours'
        on conflict do nothing;
    end if;

    perform public.kcp_write_audit(
        plan.group_id, 'schedule_change_previewed', 'schedule_change_set', set_id::text,
        summary_value
    );
    return query select set_id, summary_value, requires_ack;
end;
$$;

create or replace function public.kcp_schedule_change_details(p_change_set_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    change_set public.kcp_schedule_change_sets;
    result jsonb;
begin
    select * into change_set from public.kcp_schedule_change_sets where id = p_change_set_id;
    if not found then raise exception 'Schedule change preview not found'; end if;
    if not public.kcp_is_member(change_set.group_id) then raise exception 'Active group membership required'; end if;

    select to_jsonb(change_set) || jsonb_build_object(
        'impacts', coalesce((
            select jsonb_agg(to_jsonb(impact) order by impact.trip_date, impact.impact_type)
            from public.kcp_schedule_change_impacts impact
            where impact.change_set_id = change_set.id
        ), '[]'::jsonb),
        'acknowledgements', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userId', acknowledgement.user_id,
                'name', profile.display_name,
                'status', acknowledgement.status,
                'note', acknowledgement.note,
                'acknowledgedAt', acknowledgement.acknowledged_at
            ) order by profile.display_name)
            from public.kcp_schedule_acknowledgements acknowledgement
            left join public.kcp_profiles profile on profile.id = acknowledgement.user_id
            where acknowledgement.change_set_id = change_set.id
        ), '[]'::jsonb)
    ) into result;
    return result;
end;
$$;

-- Preserve the tested publisher and wrap it with impact state.
do $$
begin
    if to_regprocedure('public.kcp_publish_schedule_plan_base(uuid,text)') is null
       and to_regprocedure('public.kcp_publish_schedule_plan(uuid,text)') is not null then
        execute 'alter function public.kcp_publish_schedule_plan(uuid,text) rename to kcp_publish_schedule_plan_base';
    end if;
end;
$$;

create or replace function public.kcp_publish_schedule_plan_v2(
    p_plan_id uuid,
    p_reason text,
    p_change_set_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    plan public.kcp_schedule_plans;
    change_set public.kcp_schedule_change_sets;
    version integer;
    affected record;
begin
    select * into plan from public.kcp_schedule_plans where id = p_plan_id;
    if not found then raise exception 'Schedule plan not found'; end if;
    if not public.kcp_is_admin(plan.group_id) then raise exception 'Owner or admin role required'; end if;
    select * into change_set from public.kcp_schedule_change_sets where id = p_change_set_id for update;
    if not found or change_set.plan_id <> plan.id or change_set.status <> 'previewed' then
        raise exception 'Preview the latest schedule impact before publishing';
    end if;

    version := public.kcp_publish_schedule_plan_base(plan.id, p_reason);
    update public.kcp_schedule_change_sets
       set status = 'published', to_schedule_version = version, published_at = now(),
           reason = coalesce(nullif(trim(p_reason), ''), reason)
     where id = change_set.id;

    for affected in
        select distinct impact.affected_user_id
        from public.kcp_schedule_change_impacts impact
        where impact.change_set_id = change_set.id and impact.affected_user_id is not null
    loop
        perform public.kcp_enqueue_notification(
            affected.affected_user_id, 'schedule_changed', plan.group_id, null,
            'Carpool schedule changed',
            'Review future ride times and driver assignments.',
            './?view=schedule',
            jsonb_build_object('changeSetId', change_set.id, 'scheduleVersion', version, 'requiresAcknowledgement', change_set.requires_acknowledgement),
            'schedule-change:' || change_set.id || ':' || affected.affected_user_id,
            now()
        );
    end loop;

    perform public.kcp_write_audit(
        plan.group_id, 'schedule_change_published', 'schedule_change_set', change_set.id::text,
        change_set.summary || jsonb_build_object('scheduleVersion', version, 'reason', p_reason)
    );
    return version;
end;
$$;

create or replace function public.kcp_publish_schedule_plan(
    p_plan_id uuid,
    p_reason text default 'Schedule plan published'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    prepared record;
begin
    select * into prepared from public.kcp_prepare_schedule_change(p_plan_id, p_reason);
    return public.kcp_publish_schedule_plan_v2(p_plan_id, p_reason, prepared.change_set_id);
end;
$$;

create or replace function public.kcp_acknowledge_schedule_change(
    p_change_set_id uuid,
    p_status text,
    p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    change_set public.kcp_schedule_change_sets;
begin
    if p_status not in ('acknowledged','declined') then raise exception 'Choose Acknowledge or Flag a problem'; end if;
    select * into change_set from public.kcp_schedule_change_sets where id = p_change_set_id;
    if not found or not public.kcp_is_member(change_set.group_id) then raise exception 'Schedule change not found'; end if;

    update public.kcp_schedule_acknowledgements
       set status = p_status, note = nullif(trim(p_note), ''), acknowledged_at = now()
     where change_set_id = p_change_set_id and user_id = auth.uid();
    if not found then raise exception 'No acknowledgement is required from this account'; end if;

    perform public.kcp_write_audit(
        change_set.group_id, 'schedule_change_' || p_status, 'schedule_change_set', change_set.id::text,
        jsonb_build_object('userId', auth.uid(), 'note', nullif(trim(p_note), ''))
    );
end;
$$;

create or replace function public.kcp_my_schedule_acknowledgements()
returns table(
    change_set_id uuid,
    group_id uuid,
    group_name text,
    status text,
    summary jsonb,
    published_at timestamptz,
    note text
)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select change_set.id, change_set.group_id, group_row.name,
           acknowledgement.status, change_set.summary,
           change_set.published_at, acknowledgement.note
    from public.kcp_schedule_acknowledgements acknowledgement
    join public.kcp_schedule_change_sets change_set on change_set.id = acknowledgement.change_set_id
    join public.kcp_groups group_row on group_row.id = change_set.group_id
    where acknowledgement.user_id = auth.uid()
      and change_set.status = 'published'
      and acknowledgement.status in ('pending','declined')
    order by change_set.published_at desc;
$$;

revoke all on function public.kcp_list_schedule_templates(text) from public, anon;
revoke all on function public.kcp_detect_user_conflicts(uuid,timestamptz,timestamptz) from public, anon;
revoke all on function public.kcp_prepare_schedule_change(uuid,text) from public, anon;
revoke all on function public.kcp_schedule_change_details(uuid) from public, anon;
revoke all on function public.kcp_publish_schedule_plan_v2(uuid,text,uuid) from public, anon;
revoke all on function public.kcp_publish_schedule_plan(uuid,text) from public, anon;
revoke all on function public.kcp_acknowledge_schedule_change(uuid,text,text) from public, anon;
revoke all on function public.kcp_my_schedule_acknowledgements() from public, anon;
grant execute on function public.kcp_list_schedule_templates(text) to authenticated;
grant execute on function public.kcp_detect_user_conflicts(uuid,timestamptz,timestamptz) to authenticated;
grant execute on function public.kcp_prepare_schedule_change(uuid,text) to authenticated;
grant execute on function public.kcp_schedule_change_details(uuid) to authenticated;
grant execute on function public.kcp_publish_schedule_plan_v2(uuid,text,uuid) to authenticated;
grant execute on function public.kcp_publish_schedule_plan(uuid,text) to authenticated;
grant execute on function public.kcp_acknowledge_schedule_change(uuid,text,text) to authenticated;
grant execute on function public.kcp_my_schedule_acknowledgements() to authenticated;

commit;
