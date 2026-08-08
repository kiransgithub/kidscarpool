begin;

-- ---------------------------------------------------------------------------
-- Generic schedule draft creation and editing
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
     where plan.group_id = p_group_id
       and (
           plan.id = group_record.active_schedule_plan_id
           or plan.status = 'published'
       )
     order by
        case when plan.id = group_record.active_schedule_plan_id then 0 else 1 end,
        plan.version desc
     limit 1;

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
        coalesce((
            select max(plan.version) + 1
            from public.kcp_schedule_plans plan
            where plan.group_id = p_group_id
        ), 1),
        coalesce(source_plan.name, 'Recurring schedule'),
        'draft',
        coalesce(source_plan.starts_on, group_record.schedule_start_date),
        coalesce(source_plan.ends_on, group_record.schedule_end_date),
        coalesce(source_plan.timezone, group_record.timezone),
        coalesce(source_plan.outbound_label, case group_record.group_kind
            when 'school' then 'School drop-off'
            when 'music' then 'Class drop-off'
            when 'tennis' then 'Practice drop-off'
            when 'training' then 'Training drop-off'
            when 'gymnastics' then 'Class drop-off'
            when 'club' then 'Club drop-off'
            else 'Outbound'
        end),
        coalesce(source_plan.return_label, case group_record.group_kind
            when 'school' then 'School pickup'
            when 'music' then 'Class pickup'
            when 'tennis' then 'Practice pickup'
            when 'training' then 'Training pickup'
            when 'gymnastics' then 'Class pickup'
            when 'club' then 'Club pickup'
            else 'Return'
        end),
        coalesce(source_plan.auto_complete_after_minutes, group_record.auto_complete_after_minutes),
        creator_participant
    ) returning * into new_plan;

    if source_plan.id is null then
        return new_plan.id;
    end if;

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
    participant_row record;
    participant_count integer;
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
        'fixed','round_robin_trip','round_robin_day',
        'round_robin_week','balanced','manual'
    ) then
        raise exception 'Choose a valid assignment strategy';
    end if;
    if p_cycle_behavior not in ('calendar','occurrence') then
        raise exception 'Choose a valid rotation behavior';
    end if;
    if jsonb_typeof(p_sessions) <> 'array' or jsonb_array_length(p_sessions) = 0 then
        raise exception 'Add at least one recurring ride session';
    end if;

    participant_count := cardinality(coalesce(p_participant_ids, '{}'::uuid[]));
    if p_strategy <> 'manual' and participant_count = 0 then
        raise exception 'Select at least one driver';
    end if;
    if p_strategy = 'fixed'
       and coalesce(p_fixed_participant_id, p_participant_ids[1]) is null then
        raise exception 'Choose the fixed driver';
    end if;

    if exists (
        select 1
        from unnest(coalesce(p_participant_ids, '{}'::uuid[])) selected(participant_id)
        where not exists (
            select 1
            from public.kcp_group_participants participant
            where participant.id = selected.participant_id
              and participant.group_id = plan_record.group_id
              and participant.status = 'active'
              and participant.can_drive
        )
    ) then
        raise exception 'Every selected driver must be active in this group';
    end if;

    if p_fixed_participant_id is not null
       and not (p_fixed_participant_id = any(coalesce(p_participant_ids, '{}'::uuid[]))) then
        raise exception 'The fixed driver must be selected';
    end if;

    -- Session-specific exceptions are tied to session IDs. The current mobile
    -- editor replaces the full recurring structure, so those draft exceptions
    -- are cleared and can be re-added after the structure is saved.
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
        select value from jsonb_array_elements(p_sessions)
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
            raise exception 'Session % needs an outbound time', session_name;
        end if;
        if return_enabled_value and return_time_value is null then
            raise exception 'Session % needs a return time', session_name;
        end if;
        if return_day_offset_value not between 0 and 2 then
            raise exception 'Session % has an invalid return-day offset', session_name;
        end if;
        if recurrence_interval_value not between 1 and 52 then
            raise exception 'Session % has an invalid recurrence interval', session_name;
        end if;

        insert into public.kcp_recurring_sessions(
            schedule_plan_id,name,weekday,recurrence_interval_weeks,
            recurrence_anchor_date,outbound_enabled,outbound_time,
            return_enabled,return_time,return_day_offset,
            destination_override,display_order,status
        ) values (
            plan_record.id,session_name,weekday_value,recurrence_interval_value,
            recurrence_anchor_value,outbound_enabled_value,outbound_time_value,
            return_enabled_value,return_time_value,return_day_offset_value,
            destination_override_value,display_order_value,'active'
        );
    end loop;

    insert into public.kcp_assignment_policies(
        schedule_plan_id,name,strategy,cycle_behavior,anchor_date,
        fixed_participant_id,priority,status,config
    ) values (
        plan_record.id,
        'Default assignment policy',
        p_strategy,
        p_cycle_behavior,
        coalesce(p_anchor_date, p_starts_on),
        case when p_strategy = 'fixed'
             then coalesce(p_fixed_participant_id, p_participant_ids[1])
             else null end,
        100,
        'active',
        jsonb_build_object('scope','all_sessions')
    ) returning * into policy_record;

    for participant_row in
        select selected.participant_id, selected.position
        from unnest(coalesce(p_participant_ids, '{}'::uuid[]))
             with ordinality selected(participant_id, position)
        order by selected.position
    loop
        insert into public.kcp_assignment_policy_members(
            policy_id,participant_id,rotation_position,weight,active
        ) values (
            policy_record.id,
            participant_row.participant_id,
            participant_row.position::integer,
            1,
            true
        );
    end loop;

    perform public.kcp_write_audit(
        plan_record.group_id,
        'schedule_draft_saved',
        'schedule_plan',
        plan_record.id::text,
        jsonb_build_object(
            'planVersion',plan_record.version,
            'sessions',session_count,
            'strategy',p_strategy,
            'cycleBehavior',p_cycle_behavior,
            'selectedDrivers',participant_count,
            'startsOn',p_starts_on,
            'endsOn',p_ends_on
        )
    );

    return plan_record.id;
end;
$$;

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

commit;
