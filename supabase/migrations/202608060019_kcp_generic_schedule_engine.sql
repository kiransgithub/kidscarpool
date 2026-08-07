begin;

-- ---------------------------------------------------------------------------
-- Generic schedule-plan editing, preview and publishing
-- ---------------------------------------------------------------------------

create or replace function public.kcp_get_or_create_draft_plan(p_group_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    existing_draft public.kcp_schedule_plans;
    source_plan public.kcp_schedule_plans;
    new_plan public.kcp_schedule_plans;
    group_record public.kcp_groups;
    creator_participant uuid;
    old_session record;
    old_policy record;
    old_exception record;
    new_session_id uuid;
    new_policy_id uuid;
    session_map jsonb := '{}'::jsonb;
    policy_map jsonb := '{}'::jsonb;
begin
    if not public.kcp_is_admin(p_group_id) then
        raise exception 'Owner or admin role required';
    end if;

    select plan.*
      into existing_draft
      from public.kcp_schedule_plans plan
     where plan.group_id = p_group_id
       and plan.status = 'draft'
     order by plan.version desc
     limit 1;

    if existing_draft.id is not null then
        return existing_draft.id;
    end if;

    select group_row.*
      into group_record
      from public.kcp_groups group_row
     where group_row.id = p_group_id
     for update;
    if not found then
        raise exception 'Group not found';
    end if;

    creator_participant := public.kcp_current_participant_id(p_group_id);

    select plan.*
      into source_plan
      from public.kcp_schedule_plans plan
     where plan.id = group_record.active_schedule_plan_id
        or (
            group_record.active_schedule_plan_id is null
            and plan.group_id = p_group_id
            and plan.status = 'published'
        )
     order by
        case when plan.id = group_record.active_schedule_plan_id then 0 else 1 end,
        plan.version desc
     limit 1;

    if source_plan.id is null then
        insert into public.kcp_schedule_plans(
            group_id,
            version,
            name,
            status,
            starts_on,
            ends_on,
            timezone,
            outbound_label,
            return_label,
            auto_complete_after_minutes,
            created_by_participant_id
        ) values (
            p_group_id,
            coalesce((select max(version) + 1 from public.kcp_schedule_plans where group_id = p_group_id), 1),
            'Recurring schedule',
            'draft',
            group_record.schedule_start_date,
            group_record.schedule_end_date,
            group_record.timezone,
            case group_record.group_kind
                when 'school' then 'School drop-off'
                when 'music' then 'Class drop-off'
                when 'tennis' then 'Practice drop-off'
                when 'training' then 'Training drop-off'
                when 'gymnastics' then 'Class drop-off'
                when 'club' then 'Club drop-off'
                else 'Outbound'
            end,
            case group_record.group_kind
                when 'school' then 'School pickup'
                when 'music' then 'Class pickup'
                when 'tennis' then 'Practice pickup'
                when 'training' then 'Training pickup'
                when 'gymnastics' then 'Class pickup'
                when 'club' then 'Club pickup'
                else 'Return'
            end,
            group_record.auto_complete_after_minutes,
            creator_participant
        ) returning * into new_plan;

        return new_plan.id;
    end if;

    insert into public.kcp_schedule_plans(
        group_id,
        version,
        name,
        status,
        starts_on,
        ends_on,
        timezone,
        outbound_label,
        return_label,
        auto_complete_after_minutes,
        created_by_participant_id
    ) values (
        source_plan.group_id,
        (select max(version) + 1 from public.kcp_schedule_plans where group_id = source_plan.group_id),
        source_plan.name,
        'draft',
        source_plan.starts_on,
        source_plan.ends_on,
        source_plan.timezone,
        source_plan.outbound_label,
        source_plan.return_label,
        source_plan.auto_complete_after_minutes,
        creator_participant
    ) returning * into new_plan;

    for old_session in
        select session.*
        from public.kcp_recurring_sessions session
        where session.schedule_plan_id = source_plan.id
        order by session.weekday, session.display_order, session.id
    loop
        insert into public.kcp_recurring_sessions(
            schedule_plan_id,
            name,
            weekday,
            recurrence_interval_weeks,
            recurrence_anchor_date,
            outbound_enabled,
            outbound_time,
            return_enabled,
            return_time,
            return_day_offset,
            destination_override,
            display_order,
            status
        ) values (
            new_plan.id,
            old_session.name,
            old_session.weekday,
            old_session.recurrence_interval_weeks,
            old_session.recurrence_anchor_date,
            old_session.outbound_enabled,
            old_session.outbound_time,
            old_session.return_enabled,
            old_session.return_time,
            old_session.return_day_offset,
            old_session.destination_override,
            old_session.display_order,
            old_session.status
        ) returning id into new_session_id;

        session_map := jsonb_set(
            session_map,
            array[old_session.id::text],
            to_jsonb(new_session_id::text),
            true
        );
    end loop;

    for old_policy in
        select policy.*
        from public.kcp_assignment_policies policy
        where policy.schedule_plan_id = source_plan.id
        order by policy.priority desc, policy.id
    loop
        insert into public.kcp_assignment_policies(
            schedule_plan_id,
            name,
            strategy,
            cycle_behavior,
            anchor_date,
            fixed_participant_id,
            priority,
            status,
            config
        ) values (
            new_plan.id,
            old_policy.name,
            old_policy.strategy,
            old_policy.cycle_behavior,
            old_policy.anchor_date,
            old_policy.fixed_participant_id,
            old_policy.priority,
            old_policy.status,
            old_policy.config
        ) returning id into new_policy_id;

        policy_map := jsonb_set(
            policy_map,
            array[old_policy.id::text],
            to_jsonb(new_policy_id::text),
            true
        );

        insert into public.kcp_assignment_policy_members(
            policy_id,
            participant_id,
            rotation_position,
            weight,
            active
        )
        select
            new_policy_id,
            member.participant_id,
            member.rotation_position,
            member.weight,
            member.active
        from public.kcp_assignment_policy_members member
        where member.policy_id = old_policy.id;
    end loop;

    insert into public.kcp_policy_sessions(policy_id, session_id)
    select
        (policy_map ->> link.policy_id::text)::uuid,
        (session_map ->> link.session_id::text)::uuid
    from public.kcp_policy_sessions link
    where policy_map ? link.policy_id::text
      and session_map ? link.session_id::text;

    for old_exception in
        select exception_row.*
        from public.kcp_schedule_exceptions exception_row
        where exception_row.schedule_plan_id = source_plan.id
        order by exception_row.exception_date, exception_row.id
    loop
        insert into public.kcp_schedule_exceptions(
            schedule_plan_id,
            session_id,
            exception_date,
            action,
            replacement_outbound_time,
            replacement_return_time,
            override_participant_id,
            reason,
            created_by_participant_id
        ) values (
            new_plan.id,
            case
                when old_exception.session_id is null then null
                else (session_map ->> old_exception.session_id::text)::uuid
            end,
            old_exception.exception_date,
            old_exception.action,
            old_exception.replacement_outbound_time,
            old_exception.replacement_return_time,
            old_exception.override_participant_id,
            old_exception.reason,
            creator_participant
        );
    end loop;

    perform public.kcp_write_audit(
        p_group_id,
        'schedule_draft_created',
        'schedule_plan',
        new_plan.id::text,
        jsonb_build_object(
            'sourcePlanId', source_plan.id,
            'sourcePlanVersion', source_plan.version,
            'draftPlanVersion', new_plan.version
        )
    );

    return new_plan.id;
end;
$$;

create or replace function public.kcp_save_schedule_plan(
    p_plan_id uuid,
    p_name text,
    p_starts_on date,
    p_ends_on date,
    p_outbound_label text,
    p_return_label text,
    p_auto_complete_after_minutes integer,
    p_sessions jsonb,
    p_strategy text,
    p_cycle_behavior text,
    p_anchor_date date,
    p_participant_ids uuid[],
    p_fixed_participant_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    plan_record public.kcp_schedule_plans;
    session_json jsonb;
    policy_record public.kcp_assignment_policies;
    participant_id uuid;
    participant_count integer := 0;
    session_count integer := 0;
    session_name text;
    weekday_value integer;
    outbound_enabled_value boolean;
    return_enabled_value boolean;
    outbound_time_value time;
    return_time_value time;
    return_day_offset_value integer;
    recurrence_interval_value integer;
    recurrence_anchor_value date;
    display_order_value integer;
    destination_override_value text;
begin
    select plan.*
      into plan_record
      from public.kcp_schedule_plans plan
     where plan.id = p_plan_id
     for update;

    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_admin(plan_record.group_id) then
        raise exception 'Owner or admin role required';
    end if;
    if plan_record.status <> 'draft' then
        raise exception 'Only a draft schedule plan can be edited';
    end if;
    if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
        raise exception 'Enter a valid schedule date range';
    end if;
    if p_auto_complete_after_minutes not between 5 and 480 then
        raise exception 'Auto-complete duration must be between 5 and 480 minutes';
    end if;
    if p_strategy not in (
        'fixed',
        'round_robin_trip',
        'round_robin_day',
        'round_robin_week',
        'balanced',
        'manual'
    ) then
        raise exception 'Choose a valid assignment strategy';
    end if;
    if p_cycle_behavior not in ('calendar','occurrence') then
        raise exception 'Choose a valid rotation behavior';
    end if;
    if jsonb_typeof(p_sessions) <> 'array' or jsonb_array_length(p_sessions) = 0 then
        raise exception 'Add at least one recurring ride session';
    end if;

    if exists (
        select 1
        from unnest(coalesce(p_participant_ids, '{}'::uuid[])) participant_value
        where not exists (
            select 1
            from public.kcp_group_participants participant
            where participant.id = participant_value
              and participant.group_id = plan_record.group_id
              and participant.status = 'active'
              and participant.can_drive
        )
    ) then
        raise exception 'Every selected driver must be an active driving participant in this group';
    end if;

    participant_count := cardinality(coalesce(p_participant_ids, '{}'::uuid[]));
    if p_strategy <> 'manual' and participant_count = 0 then
        raise exception 'Select at least one driver for this assignment strategy';
    end if;
    if p_strategy = 'fixed'
       and coalesce(p_fixed_participant_id, p_participant_ids[1]) is null then
        raise exception 'Choose the fixed driver';
    end if;
    if p_fixed_participant_id is not null
       and not (p_fixed_participant_id = any(coalesce(p_participant_ids, '{}'::uuid[]))) then
        raise exception 'The fixed driver must be included in the selected drivers';
    end if;

    -- Draft schedules are replaceable. Exceptions are draft-specific and are
    -- intentionally cleared when the recurring session structure is replaced.
    delete from public.kcp_schedule_exceptions
     where schedule_plan_id = plan_record.id;
    delete from public.kcp_assignment_policies
     where schedule_plan_id = plan_record.id;
    delete from public.kcp_recurring_sessions
     where schedule_plan_id = plan_record.id;

    update public.kcp_schedule_plans
       set name = coalesce(nullif(trim(p_name), ''), 'Recurring schedule'),
           starts_on = p_starts_on,
           ends_on = p_ends_on,
           outbound_label = coalesce(nullif(trim(p_outbound_label), ''), 'Drop-off'),
           return_label = coalesce(nullif(trim(p_return_label), ''), 'Pickup'),
           auto_complete_after_minutes = p_auto_complete_after_minutes,
           updated_at = now()
     where id = plan_record.id;

    for session_json in
        select value
        from jsonb_array_elements(p_sessions)
    loop
        session_count := session_count + 1;
        session_name := coalesce(
            nullif(trim(session_json ->> 'name'), ''),
            concat('Session ', session_count)
        );
        weekday_value := (session_json ->> 'weekday')::integer;
        outbound_enabled_value := coalesce((session_json ->> 'outboundEnabled')::boolean, false);
        return_enabled_value := coalesce((session_json ->> 'returnEnabled')::boolean, false);
        outbound_time_value := nullif(session_json ->> 'outboundTime', '')::time;
        return_time_value := nullif(session_json ->> 'returnTime', '')::time;
        return_day_offset_value := coalesce((session_json ->> 'returnDayOffset')::integer, 0);
        recurrence_interval_value := coalesce((session_json ->> 'intervalWeeks')::integer, 1);
        recurrence_anchor_value := coalesce(
            nullif(session_json ->> 'anchorDate', '')::date,
            p_starts_on
        );
        display_order_value := coalesce((session_json ->> 'displayOrder')::integer, session_count);
        destination_override_value := nullif(trim(session_json ->> 'destinationOverride'), '');

        if weekday_value not between 1 and 7 then
            raise exception 'Session % has an invalid weekday', session_name;
        end if;
        if not outbound_enabled_value and not return_enabled_value then
            raise exception 'Session % must include drop-off, pickup, or both', session_name;
        end if;
        if outbound_enabled_value and outbound_time_value is null then
            raise exception 'Session % needs a drop-off/outbound time', session_name;
        end if;
        if return_enabled_value and return_time_value is null then
            raise exception 'Session % needs a pickup/return time', session_name;
        end if;
        if return_day_offset_value not between 0 and 2 then
            raise exception 'Session % has an invalid return-day offset', session_name;
        end if;
        if recurrence_interval_value not between 1 and 52 then
            raise exception 'Session % has an invalid recurrence interval', session_name;
        end if;

        insert into public.kcp_recurring_sessions(
            schedule_plan_id,
            name,
            weekday,
            recurrence_interval_weeks,
            recurrence_anchor_date,
            outbound_enabled,
            outbound_time,
            return_enabled,
            return_time,
            return_day_offset,
            destination_override,
            display_order,
            status
        ) values (
            plan_record.id,
            session_name,
            weekday_value,
            recurrence_interval_value,
            recurrence_anchor_value,
            outbound_enabled_value,
            outbound_time_value,
            return_enabled_value,
            return_time_value,
            return_day_offset_value,
            destination_override_value,
            display_order_value,
            'active'
        );
    end loop;

    insert into public.kcp_assignment_policies(
        schedule_plan_id,
        name,
        strategy,
        cycle_behavior,
        anchor_date,
        fixed_participant_id,
        priority,
        status,
        config
    ) values (
        plan_record.id,
        'Default assignment policy',
        p_strategy,
        p_cycle_behavior,
        coalesce(p_anchor_date, p_starts_on),
        case
            when p_strategy = 'fixed'
            then coalesce(p_fixed_participant_id, p_participant_ids[1])
            else null
        end,
        100,
        'active',
        jsonb_build_object('scope', 'all_sessions')
    ) returning * into policy_record;

    if participant_count > 0 then
        for participant_id in
            select participant_value
            from unnest(p_participant_ids) with ordinality
                 selected(participant_value, position)
            order by position
        loop
            insert into public.kcp_assignment_policy_members(
                policy_id,
                participant_id,
                rotation_position,
                weight,
                active
            ) values (
                policy_record.id,
                participant_id,
                (
                    select position::integer
                    from unnest(p_participant_ids) with ordinality
                         lookup(participant_value, position)
                    where lookup.participant_value = participant_id
                    limit 1
                ),
                1,
                true
            );
        end loop;
    end if;

    perform public.kcp_write_audit(
        plan_record.group_id,
        'schedule_draft_saved',
        'schedule_plan',
        plan_record.id::text,
        jsonb_build_object(
            'planVersion', plan_record.version,
            'sessions', session_count,
            'strategy', p_strategy,
            'cycleBehavior', p_cycle_behavior,
            'selectedDrivers', participant_count,
            'startsOn', p_starts_on,
            'endsOn', p_ends_on
        )
    );

    return plan_record.id;
end;
$$;

create or replace function public.kcp_plan_occurrences(
    p_plan_id uuid,
    p_from date default null,
    p_to date default null,
    p_limit integer default 1000
)
returns table(
    service_date date,
    session_id uuid,
    session_name text,
    leg_type text,
    local_time time without time zone,
    day_offset smallint,
    scheduled_at timestamptz,
    display_label text,
    policy_id uuid,
    strategy text,
    block_key text,
    participant_id uuid,
    participant_name text,
    participant_user_id uuid
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    plan_record public.kcp_schedule_plans;
    range_start date;
    range_end date;
begin
    select plan.*
      into plan_record
      from public.kcp_schedule_plans plan
     where plan.id = p_plan_id;

    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_member(plan_record.group_id) then
        raise exception 'Active group membership required';
    end if;

    range_start := coalesce(p_from, plan_record.starts_on);
    range_end := coalesce(p_to, plan_record.ends_on);

    if range_start is null or range_end is null or range_end < range_start then
        raise exception 'The plan needs a valid start and end date';
    end if;

    return query
    with plan_context as (
        select
            plan.*,
            group_row.timezone as group_timezone
        from public.kcp_schedule_plans plan
        join public.kcp_groups group_row on group_row.id = plan.group_id
        where plan.id = p_plan_id
    ), service_dates as (
        select generated_day::date as service_date
        from generate_series(range_start, range_end, interval '1 day') generated_day
    ), matching_sessions as (
        select
            dates.service_date,
            session.id as session_id,
            session.name as session_name,
            session.weekday,
            session.recurrence_interval_weeks,
            coalesce(session.recurrence_anchor_date, context.starts_on) as recurrence_anchor_date,
            session.outbound_enabled,
            session.outbound_time,
            session.return_enabled,
            session.return_time,
            session.return_day_offset,
            session.destination_override,
            session.display_order,
            context.group_id,
            context.timezone,
            context.group_timezone,
            context.outbound_label,
            context.return_label
        from service_dates dates
        cross join plan_context context
        join public.kcp_recurring_sessions session
          on session.schedule_plan_id = context.id
         and session.status = 'active'
         and session.weekday = extract(isodow from dates.service_date)::integer
        where mod(
            floor(
                (dates.service_date - coalesce(session.recurrence_anchor_date, context.starts_on)) / 7.0
            )::integer,
            session.recurrence_interval_weeks
        ) = 0
          and not exists (
              select 1
              from public.kcp_school_calendars calendar
              join public.kcp_calendar_events calendar_event
                on calendar_event.calendar_id = calendar.id
              where calendar.group_id = context.group_id
                and calendar_event.event_type = 'no_school'
                and dates.service_date between calendar_event.start_date and calendar_event.end_date
          )
          and not exists (
              select 1
              from public.kcp_schedule_exceptions exception_row
              where exception_row.schedule_plan_id = context.id
                and exception_row.exception_date = dates.service_date
                and exception_row.action = 'skip'
                and (
                    exception_row.session_id is null
                    or exception_row.session_id = session.id
                )
          )
    ), configured_sessions as (
        select
            session_row.*,
            policy.id as policy_id,
            policy.strategy,
            policy.cycle_behavior,
            coalesce(policy.anchor_date, session_row.recurrence_anchor_date) as policy_anchor_date,
            policy.fixed_participant_id,
            member_list.member_ids,
            exception_values.replacement_outbound_time,
            exception_values.replacement_return_time,
            exception_values.override_participant_id,
            coalesce(exception_values.outbound_only, false) as outbound_only,
            coalesce(exception_values.return_only, false) as return_only
        from matching_sessions session_row
        left join lateral (
            select policy_candidate.*
            from public.kcp_assignment_policies policy_candidate
            where policy_candidate.schedule_plan_id = p_plan_id
              and policy_candidate.status = 'active'
              and (
                  not exists (
                      select 1
                      from public.kcp_policy_sessions policy_session
                      where policy_session.policy_id = policy_candidate.id
                  )
                  or exists (
                      select 1
                      from public.kcp_policy_sessions policy_session
                      where policy_session.policy_id = policy_candidate.id
                        and policy_session.session_id = session_row.session_id
                  )
              )
            order by policy_candidate.priority desc, policy_candidate.id
            limit 1
        ) policy on true
        left join lateral (
            select array_agg(member.participant_id order by member.rotation_position) as member_ids
            from public.kcp_assignment_policy_members member
            where member.policy_id = policy.id
              and member.active
        ) member_list on true
        left join lateral (
            select
                (array_agg(exception_row.replacement_outbound_time)
                    filter (where exception_row.action = 'change_time'
                                and exception_row.replacement_outbound_time is not null))[1]
                    as replacement_outbound_time,
                (array_agg(exception_row.replacement_return_time)
                    filter (where exception_row.action = 'change_time'
                                and exception_row.replacement_return_time is not null))[1]
                    as replacement_return_time,
                (array_agg(exception_row.override_participant_id)
                    filter (where exception_row.action = 'change_driver'
                                and exception_row.override_participant_id is not null))[1]
                    as override_participant_id,
                bool_or(exception_row.action = 'outbound_only') as outbound_only,
                bool_or(exception_row.action = 'return_only') as return_only
            from public.kcp_schedule_exceptions exception_row
            where exception_row.schedule_plan_id = p_plan_id
              and exception_row.exception_date = session_row.service_date
              and (
                  exception_row.session_id is null
                  or exception_row.session_id = session_row.session_id
              )
        ) exception_values on true
    ), legs as (
        select
            configured.service_date,
            configured.session_id,
            configured.session_name,
            'outbound'::text as leg_type,
            coalesce(configured.replacement_outbound_time, configured.outbound_time) as local_time,
            0::smallint as day_offset,
            configured.outbound_label as display_label,
            configured.display_order,
            0 as leg_order,
            configured.group_id,
            configured.timezone,
            configured.group_timezone,
            configured.policy_id,
            coalesce(configured.strategy, 'manual') as strategy,
            coalesce(configured.cycle_behavior, 'calendar') as cycle_behavior,
            configured.policy_anchor_date,
            configured.fixed_participant_id,
            configured.member_ids,
            configured.override_participant_id
        from configured_sessions configured
        where configured.outbound_enabled
          and not configured.return_only

        union all

        select
            configured.service_date,
            configured.session_id,
            configured.session_name,
            'return'::text as leg_type,
            coalesce(configured.replacement_return_time, configured.return_time) as local_time,
            configured.return_day_offset::smallint as day_offset,
            configured.return_label as display_label,
            configured.display_order,
            1 as leg_order,
            configured.group_id,
            configured.timezone,
            configured.group_timezone,
            configured.policy_id,
            coalesce(configured.strategy, 'manual') as strategy,
            coalesce(configured.cycle_behavior, 'calendar') as cycle_behavior,
            configured.policy_anchor_date,
            configured.fixed_participant_id,
            configured.member_ids,
            configured.override_participant_id
        from configured_sessions configured
        where configured.return_enabled
          and not configured.outbound_only
    ), sequenced as (
        select
            leg.*,
            row_number() over (
                partition by leg.policy_id
                order by
                    leg.service_date,
                    leg.display_order,
                    leg.local_time,
                    leg.leg_order,
                    leg.session_id
            ) - 1 as trip_sequence,
            dense_rank() over (
                partition by leg.policy_id
                order by leg.service_date
            ) - 1 as day_sequence,
            dense_rank() over (
                partition by leg.policy_id
                order by date_trunc('week', leg.service_date::timestamp)::date
            ) - 1 as occurrence_week_sequence,
            date_trunc('week', leg.service_date::timestamp)::date as service_week_start,
            date_trunc('week', leg.policy_anchor_date::timestamp)::date as anchor_week_start
        from legs leg
    ), assigned as (
        select
            sequence_row.*,
            case
                when sequence_row.override_participant_id is not null
                    then sequence_row.override_participant_id
                when sequence_row.strategy = 'fixed'
                    then coalesce(
                        sequence_row.fixed_participant_id,
                        sequence_row.member_ids[1]
                    )
                when sequence_row.strategy = 'manual'
                    then null
                when cardinality(sequence_row.member_ids) is null
                  or cardinality(sequence_row.member_ids) = 0
                    then null
                when sequence_row.strategy = 'round_robin_week'
                    then sequence_row.member_ids[
                        1 + (
                            (
                                case
                                    when sequence_row.cycle_behavior = 'occurrence'
                                        then sequence_row.occurrence_week_sequence::integer
                                    else floor(
                                        (sequence_row.service_week_start - sequence_row.anchor_week_start) / 7.0
                                    )::integer
                                end
                                % cardinality(sequence_row.member_ids)
                                + cardinality(sequence_row.member_ids)
                            ) % cardinality(sequence_row.member_ids)
                        )
                    ]
                when sequence_row.strategy = 'round_robin_day'
                    then sequence_row.member_ids[
                        1 + (sequence_row.day_sequence::integer % cardinality(sequence_row.member_ids))
                    ]
                else sequence_row.member_ids[
                    1 + (sequence_row.trip_sequence::integer % cardinality(sequence_row.member_ids))
                ]
            end as assigned_participant_id,
            case
                when sequence_row.strategy = 'round_robin_week'
                    then concat(
                        'week:',
                        sequence_row.policy_id,
                        ':',
                        sequence_row.service_week_start
                    )
                when sequence_row.strategy = 'round_robin_day'
                    then concat(
                        'day:',
                        sequence_row.policy_id,
                        ':',
                        sequence_row.service_date
                    )
                when sequence_row.strategy = 'fixed'
                    then concat(
                        'fixed-day:',
                        sequence_row.policy_id,
                        ':',
                        sequence_row.service_date
                    )
                else concat(
                    'trip:',
                    coalesce(sequence_row.policy_id::text, 'manual'),
                    ':',
                    sequence_row.service_date,
                    ':',
                    sequence_row.session_id,
                    ':',
                    sequence_row.leg_type
                )
            end as responsibility_key
        from sequenced sequence_row
    )
    select
        assigned.service_date,
        assigned.session_id,
        assigned.session_name,
        assigned.leg_type,
        assigned.local_time,
        assigned.day_offset,
        make_timestamptz(
            extract(year from (assigned.service_date + assigned.day_offset))::integer,
            extract(month from (assigned.service_date + assigned.day_offset))::integer,
            extract(day from (assigned.service_date + assigned.day_offset))::integer,
            extract(hour from assigned.local_time)::integer,
            extract(minute from assigned.local_time)::integer,
            extract(second from assigned.local_time)::double precision,
            coalesce(assigned.timezone, assigned.group_timezone, 'UTC')
        ) as scheduled_at,
        assigned.display_label,
        assigned.policy_id,
        assigned.strategy,
        assigned.responsibility_key,
        assigned.assigned_participant_id,
        participant.display_name,
        participant.user_id
    from assigned
    left join public.kcp_group_participants participant
      on participant.id = assigned.assigned_participant_id
    order by scheduled_at, assigned.display_order, assigned.leg_order
    limit greatest(1, least(coalesce(p_limit, 1000), 5000));
end;
$$;

create or replace function public.kcp_publish_schedule_plan(
    p_plan_id uuid,
    p_reason text default 'Published from the flexible schedule builder'
)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    plan_record public.kcp_schedule_plans;
    group_record public.kcp_groups;
    publisher_participant uuid;
    new_schedule_version integer;
    occurrence_count integer;
    generated_trip_count integer;
begin
    select plan.*
      into plan_record
      from public.kcp_schedule_plans plan
     where plan.id = p_plan_id
     for update;
    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_admin(plan_record.group_id) then
        raise exception 'Owner or admin role required';
    end if;
    if plan_record.status <> 'draft' then
        raise exception 'Only a draft schedule plan can be published';
    end if;
    if plan_record.starts_on is null or plan_record.ends_on is null then
        raise exception 'The schedule plan needs a date range';
    end if;
    if not exists (
        select 1
        from public.kcp_recurring_sessions session
        where session.schedule_plan_id = plan_record.id
          and session.status = 'active'
    ) then
        raise exception 'Add at least one recurring ride session';
    end if;

    select count(*)
      into occurrence_count
      from public.kcp_plan_occurrences(
          plan_record.id,
          plan_record.starts_on,
          plan_record.ends_on,
          5000
      );
    if occurrence_count = 0 then
        raise exception 'The plan produced no trips. Check dates, weekdays and recurrence settings.';
    end if;

    select group_row.*
      into group_record
      from public.kcp_groups group_row
     where group_row.id = plan_record.group_id
     for update;

    publisher_participant := public.kcp_current_participant_id(plan_record.group_id);
    new_schedule_version := greatest(
        group_record.current_schedule_version + 1,
        coalesce((
            select max(version) + 1
            from public.kcp_schedule_versions
            where group_id = plan_record.group_id
        ), 1)
    );

    update public.kcp_schedule_versions
       set status = 'superseded'
     where group_id = plan_record.group_id
       and status = 'published';

    insert into public.kcp_schedule_versions(
        group_id,
        version,
        status,
        reason,
        generated_by,
        generated_at,
        published_by,
        published_at,
        change_summary
    ) values (
        plan_record.group_id,
        new_schedule_version,
        'published',
        coalesce(nullif(trim(p_reason), ''), 'Flexible schedule published'),
        auth.uid(),
        now(),
        auth.uid(),
        now(),
        jsonb_build_object(
            'schedulePlanId', plan_record.id,
            'schedulePlanVersion', plan_record.version,
            'engine', 'generic_schedule_plan',
            'startsOn', plan_record.starts_on,
            'endsOn', plan_record.ends_on,
            'outboundLabel', plan_record.outbound_label,
            'returnLabel', plan_record.return_label,
            'occurrences', occurrence_count
        )
    );

    update public.kcp_schedule_plans
       set status = 'superseded'
     where group_id = plan_record.group_id
       and status = 'published'
       and id <> plan_record.id;

    update public.kcp_schedule_plans
       set status = 'published',
           published_by_participant_id = publisher_participant,
           published_at = now(),
           updated_at = now()
     where id = plan_record.id;

    update public.kcp_groups
       set active_schedule_plan_id = plan_record.id,
           current_schedule_version = new_schedule_version,
           schedule_start_date = plan_record.starts_on,
           schedule_end_date = plan_record.ends_on,
           service_weekdays = coalesce((
               select array_agg(distinct session.weekday order by session.weekday)::smallint[]
               from public.kcp_recurring_sessions session
               where session.schedule_plan_id = plan_record.id
                 and session.status = 'active'
           ), service_weekdays),
           drop_time = coalesce((
               select min(session.outbound_time)
               from public.kcp_recurring_sessions session
               where session.schedule_plan_id = plan_record.id
                 and session.status = 'active'
                 and session.outbound_enabled
           ), drop_time),
           pickup_time = coalesce((
               select min(session.return_time)
               from public.kcp_recurring_sessions session
               where session.schedule_plan_id = plan_record.id
                 and session.status = 'active'
                 and session.return_enabled
           ), pickup_time),
           auto_complete_after_minutes = plan_record.auto_complete_after_minutes,
           schedule_policy = 'generic_plan',
           updated_at = now()
     where id = plan_record.group_id;

    insert into public.kcp_responsibility_blocks(
        group_id,
        schedule_plan_id,
        schedule_version,
        policy_id,
        block_key,
        block_start,
        block_end,
        participant_id,
        status
    )
    select
        plan_record.group_id,
        plan_record.id,
        new_schedule_version,
        occurrence.policy_id,
        occurrence.block_key,
        min(occurrence.service_date),
        max(occurrence.service_date),
        occurrence.participant_id,
        case when occurrence.participant_id is null then 'coverage_needed' else 'assigned' end
    from public.kcp_plan_occurrences(
        plan_record.id,
        plan_record.starts_on,
        plan_record.ends_on,
        5000
    ) occurrence
    group by
        occurrence.policy_id,
        occurrence.block_key,
        occurrence.participant_id;

    insert into public.kcp_trips(
        group_id,
        schedule_version,
        trip_date,
        kind,
        scheduled_driver_id,
        scheduled_driver_name,
        actual_driver_id,
        actual_driver_name,
        status,
        scheduled_time,
        time_label,
        notes,
        child_names,
        started_at,
        completed_at,
        volunteer_assignment,
        started_source,
        completed_source,
        schedule_plan_id,
        recurring_session_id,
        responsibility_block_id,
        scheduled_participant_id,
        actual_participant_id,
        leg_type,
        display_label,
        created_at,
        updated_at
    )
    select
        plan_record.group_id,
        new_schedule_version,
        occurrence.service_date,
        case when occurrence.leg_type = 'outbound' then 'morning_drop' else 'afternoon_pickup' end,
        occurrence.participant_user_id,
        occurrence.participant_name,
        null,
        null,
        case when occurrence.participant_user_id is null then 'coverage_needed' else 'scheduled' end,
        occurrence.scheduled_at,
        to_char(
            occurrence.scheduled_at at time zone plan_record.timezone,
            'FMHH12:MI AM'
        ),
        occurrence.session_name,
        coalesce((
            select array_agg(child.name order by child.name)
            from public.kcp_children child
            where child.group_id = plan_record.group_id
              and child.status = 'active'
        ), '{}'::text[]),
        null,
        null,
        false,
        null,
        null,
        plan_record.id,
        occurrence.session_id,
        block.id,
        occurrence.participant_id,
        null,
        occurrence.leg_type,
        occurrence.display_label,
        now(),
        now()
    from public.kcp_plan_occurrences(
        plan_record.id,
        plan_record.starts_on,
        plan_record.ends_on,
        5000
    ) occurrence
    left join public.kcp_responsibility_blocks block
      on block.schedule_plan_id = plan_record.id
     and block.schedule_version = new_schedule_version
     and block.block_key = occurrence.block_key
     and block.policy_id is not distinct from occurrence.policy_id
     and block.participant_id is not distinct from occurrence.participant_id
    order by occurrence.scheduled_at, occurrence.session_id, occurrence.leg_type;

    get diagnostics generated_trip_count = row_count;

    perform public.kcp_write_audit(
        plan_record.group_id,
        'schedule_plan_published',
        'schedule_plan',
        plan_record.id::text,
        jsonb_build_object(
            'planVersion', plan_record.version,
            'scheduleVersion', new_schedule_version,
            'tripCount', generated_trip_count,
            'reason', p_reason
        )
    );

    return new_schedule_version;
end;
$$;

create or replace function public.kcp_schedule_builder_state(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    plan_id uuid;
begin
    if not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;

    select plan.id
      into plan_id
      from public.kcp_schedule_plans plan
     where plan.group_id = p_group_id
     order by
        case when plan.status = 'draft' then 0
             when plan.id = (select active_schedule_plan_id from public.kcp_groups where id = p_group_id) then 1
             else 2 end,
        plan.version desc
     limit 1;

    return jsonb_build_object(
        'plan', (
            select to_jsonb(plan)
            from public.kcp_schedule_plans plan
            where plan.id = plan_id
        ),
        'sessions', coalesce((
            select jsonb_agg(to_jsonb(session) order by session.weekday, session.display_order, session.id)
            from public.kcp_recurring_sessions session
            where session.schedule_plan_id = plan_id
        ), '[]'::jsonb),
        'policies', coalesce((
            select jsonb_agg(to_jsonb(policy) order by policy.priority desc, policy.id)
            from public.kcp_assignment_policies policy
            where policy.schedule_plan_id = plan_id
        ), '[]'::jsonb),
        'policyMembers', coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'policy_id', member.policy_id,
                    'participant_id', member.participant_id,
                    'rotation_position', member.rotation_position,
                    'weight', member.weight,
                    'active', member.active
                ) order by member.rotation_position
            )
            from public.kcp_assignment_policy_members member
            join public.kcp_assignment_policies policy on policy.id = member.policy_id
            where policy.schedule_plan_id = plan_id
        ), '[]'::jsonb),
        'participants', coalesce((
            select jsonb_agg(to_jsonb(participant) order by participant.display_name, participant.id)
            from public.kcp_group_participants participant
            where participant.group_id = p_group_id
              and participant.status = 'active'
        ), '[]'::jsonb),
        'exceptions', coalesce((
            select jsonb_agg(to_jsonb(exception_row) order by exception_row.exception_date, exception_row.id)
            from public.kcp_schedule_exceptions exception_row
            where exception_row.schedule_plan_id = plan_id
        ), '[]'::jsonb)
    );
end;
$$;

-- ---------------------------------------------------------------------------
-- Backfill a generic, editable mirror of existing groups without changing any
-- currently published trip. Existing plans are imported as manual so that the
-- live schedule remains authoritative until an admin previews and publishes a
-- new generic plan.
-- ---------------------------------------------------------------------------

insert into public.kcp_schedule_plans(
    group_id,
    version,
    name,
    status,
    starts_on,
    ends_on,
    timezone,
    outbound_label,
    return_label,
    auto_complete_after_minutes,
    created_by_participant_id,
    published_by_participant_id,
    published_at
)
select
    group_row.id,
    1,
    'Imported recurring schedule',
    case when group_row.current_schedule_version > 0 then 'published' else 'draft' end,
    coalesce(
        group_row.schedule_start_date,
        (select min(trip.trip_date) from public.kcp_trips trip where trip.group_id = group_row.id)
    ),
    coalesce(
        group_row.schedule_end_date,
        (select max(trip.trip_date) from public.kcp_trips trip where trip.group_id = group_row.id)
    ),
    group_row.timezone,
    case group_row.group_kind
        when 'school' then 'School drop-off'
        when 'music' then 'Class drop-off'
        when 'tennis' then 'Practice drop-off'
        when 'training' then 'Training drop-off'
        when 'gymnastics' then 'Class drop-off'
        when 'club' then 'Club drop-off'
        else 'Outbound'
    end,
    case group_row.group_kind
        when 'school' then 'School pickup'
        when 'music' then 'Class pickup'
        when 'tennis' then 'Practice pickup'
        when 'training' then 'Training pickup'
        when 'gymnastics' then 'Class pickup'
        when 'club' then 'Club pickup'
        else 'Return'
    end,
    group_row.auto_complete_after_minutes,
    participant.id,
    participant.id,
    case when group_row.current_schedule_version > 0 then now() else null end
from public.kcp_groups group_row
left join public.kcp_group_participants participant
  on participant.group_id = group_row.id
 and participant.user_id = group_row.created_by
where not exists (
    select 1
    from public.kcp_schedule_plans existing_plan
    where existing_plan.group_id = group_row.id
);

insert into public.kcp_recurring_sessions(
    schedule_plan_id,
    name,
    weekday,
    recurrence_interval_weeks,
    recurrence_anchor_date,
    outbound_enabled,
    outbound_time,
    return_enabled,
    return_time,
    return_day_offset,
    display_order,
    status
)
select
    plan.id,
    trim(to_char(date '2024-01-01' + (weekday_value - 1), 'FMDay')),
    weekday_value,
    1,
    coalesce(plan.starts_on, current_date),
    true,
    group_row.drop_time,
    true,
    group_row.pickup_time,
    0,
    weekday_value,
    'active'
from public.kcp_schedule_plans plan
join public.kcp_groups group_row on group_row.id = plan.group_id
cross join lateral unnest(group_row.service_weekdays) weekday_value
where plan.name = 'Imported recurring schedule'
  and not exists (
      select 1
      from public.kcp_recurring_sessions existing_session
      where existing_session.schedule_plan_id = plan.id
  );

insert into public.kcp_assignment_policies(
    schedule_plan_id,
    name,
    strategy,
    cycle_behavior,
    anchor_date,
    priority,
    status,
    config
)
select
    plan.id,
    'Imported assignments',
    'manual',
    'calendar',
    plan.starts_on,
    100,
    'active',
    jsonb_build_object('source', 'legacy_schedule')
from public.kcp_schedule_plans plan
where plan.name = 'Imported recurring schedule'
  and not exists (
      select 1
      from public.kcp_assignment_policies existing_policy
      where existing_policy.schedule_plan_id = plan.id
  );

update public.kcp_groups group_row
   set active_schedule_plan_id = plan.id
  from public.kcp_schedule_plans plan
 where plan.group_id = group_row.id
   and plan.name = 'Imported recurring schedule'
   and plan.status = 'published'
   and group_row.active_schedule_plan_id is null;

update public.kcp_trips trip
   set schedule_plan_id = plan.id,
       recurring_session_id = session.id,
       leg_type = case
           when trip.kind = 'morning_drop' then 'outbound'
           else 'return'
       end,
       display_label = case
           when trip.kind = 'morning_drop' then plan.outbound_label
           else plan.return_label
       end,
       scheduled_participant_id = coalesce(
           trip.scheduled_participant_id,
           participant.id
       ),
       actual_participant_id = coalesce(
           trip.actual_participant_id,
           actual_participant.id
       )
  from public.kcp_schedule_plans plan
  left join public.kcp_recurring_sessions session
    on session.schedule_plan_id = plan.id
   and session.weekday = extract(isodow from trip.trip_date)::integer
  left join public.kcp_group_participants participant
    on participant.group_id = trip.group_id
   and (
       participant.user_id = trip.scheduled_driver_id
       or lower(participant.display_name) = lower(trip.scheduled_driver_name)
   )
  left join public.kcp_group_participants actual_participant
    on actual_participant.group_id = trip.group_id
   and (
       actual_participant.user_id = trip.actual_driver_id
       or (
           trip.actual_driver_name is not null
           and lower(actual_participant.display_name) = lower(trip.actual_driver_name)
       )
   )
 where plan.group_id = trip.group_id
   and plan.name = 'Imported recurring schedule'
   and trip.schedule_plan_id is null;

revoke all on function public.kcp_get_or_create_draft_plan(uuid)
from public, anon;
grant execute on function public.kcp_get_or_create_draft_plan(uuid)
to authenticated;

revoke all on function public.kcp_save_schedule_plan(
    uuid,text,date,date,text,text,integer,jsonb,text,text,date,uuid[],uuid
) from public, anon;
grant execute on function public.kcp_save_schedule_plan(
    uuid,text,date,date,text,text,integer,jsonb,text,text,date,uuid[],uuid
) to authenticated;

revoke all on function public.kcp_plan_occurrences(uuid,date,date,integer)
from public, anon;
grant execute on function public.kcp_plan_occurrences(uuid,date,date,integer)
to authenticated;

revoke all on function public.kcp_publish_schedule_plan(uuid,text)
from public, anon;
grant execute on function public.kcp_publish_schedule_plan(uuid,text)
to authenticated;

revoke all on function public.kcp_schedule_builder_state(uuid)
from public, anon;
grant execute on function public.kcp_schedule_builder_state(uuid)
to authenticated;

commit;
