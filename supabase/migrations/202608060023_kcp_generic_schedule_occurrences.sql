begin;

-- ---------------------------------------------------------------------------
-- Resolve a schedule plan into dated outbound/return occurrences. This is used
-- by both the mobile preview and the publisher, so preview and persisted trips
-- always share the same assignment calculation.
-- ---------------------------------------------------------------------------

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
#variable_conflict use_variable
declare
    v_plan public.kcp_schedule_plans;
    v_range_start date;
    v_range_end date;
begin
    select plan.*
      into v_plan
      from public.kcp_schedule_plans plan
     where plan.id = p_plan_id;

    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_member(v_plan.group_id) then
        raise exception 'Active group membership required';
    end if;

    v_range_start := coalesce(p_from, v_plan.starts_on);
    v_range_end := coalesce(p_to, v_plan.ends_on);

    if v_range_start is null
       or v_range_end is null
       or v_range_end < v_range_start then
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
        from generate_series(v_range_start, v_range_end, interval '1 day') generated_day
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
            session.display_order,
            context.id as schedule_plan_id,
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
        where dates.service_date >= coalesce(session.recurrence_anchor_date, context.starts_on)
          and mod(
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
            coalesce(policy.strategy, 'manual') as strategy,
            coalesce(policy.cycle_behavior, 'calendar') as cycle_behavior,
            coalesce(policy.anchor_date, session_row.recurrence_anchor_date, v_plan.starts_on) as policy_anchor_date,
            policy.fixed_participant_id,
            member_list.member_ids,
            time_override.replacement_outbound_time,
            time_override.replacement_return_time,
            driver_override.override_participant_id,
            exists (
                select 1
                from public.kcp_schedule_exceptions exception_row
                where exception_row.schedule_plan_id = session_row.schedule_plan_id
                  and exception_row.exception_date = session_row.service_date
                  and exception_row.action = 'outbound_only'
                  and (
                      exception_row.session_id is null
                      or exception_row.session_id = session_row.session_id
                  )
            ) as outbound_only,
            exists (
                select 1
                from public.kcp_schedule_exceptions exception_row
                where exception_row.schedule_plan_id = session_row.schedule_plan_id
                  and exception_row.exception_date = session_row.service_date
                  and exception_row.action = 'return_only'
                  and (
                      exception_row.session_id is null
                      or exception_row.session_id = session_row.session_id
                  )
            ) as return_only
        from matching_sessions session_row
        left join lateral (
            select policy_candidate.*
            from public.kcp_assignment_policies policy_candidate
            where policy_candidate.schedule_plan_id = session_row.schedule_plan_id
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
                exception_row.replacement_outbound_time,
                exception_row.replacement_return_time
            from public.kcp_schedule_exceptions exception_row
            where exception_row.schedule_plan_id = session_row.schedule_plan_id
              and exception_row.exception_date = session_row.service_date
              and exception_row.action = 'change_time'
              and (
                  exception_row.session_id is null
                  or exception_row.session_id = session_row.session_id
              )
            order by exception_row.updated_at desc, exception_row.id desc
            limit 1
        ) time_override on true
        left join lateral (
            select exception_row.override_participant_id
            from public.kcp_schedule_exceptions exception_row
            where exception_row.schedule_plan_id = session_row.schedule_plan_id
              and exception_row.exception_date = session_row.service_date
              and exception_row.action = 'change_driver'
              and exception_row.override_participant_id is not null
              and (
                  exception_row.session_id is null
                  or exception_row.session_id = session_row.session_id
              )
            order by exception_row.updated_at desc, exception_row.id desc
            limit 1
        ) driver_override on true
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
            configured.strategy,
            configured.cycle_behavior,
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
            configured.strategy,
            configured.cycle_behavior,
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
                order by leg.service_date,leg.display_order,leg.local_time,leg.leg_order,leg.session_id
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
                when sequence_row.strategy = 'manual'
                    then null
                when sequence_row.strategy = 'fixed'
                    then coalesce(sequence_row.fixed_participant_id, sequence_row.member_ids[1])
                when coalesce(cardinality(sequence_row.member_ids), 0) = 0
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
                when sequence_row.strategy = 'round_robin_week' then concat(
                    'week:',sequence_row.policy_id,':',sequence_row.service_week_start
                )
                when sequence_row.strategy = 'round_robin_day' then concat(
                    'day:',sequence_row.policy_id,':',sequence_row.service_date
                )
                when sequence_row.strategy = 'fixed' then concat(
                    'fixed-day:',sequence_row.policy_id,':',sequence_row.service_date
                )
                else concat(
                    'trip:',coalesce(sequence_row.policy_id::text,'manual'),':',
                    sequence_row.service_date,':',sequence_row.session_id,':',sequence_row.leg_type
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
    order by scheduled_at,assigned.display_order,assigned.leg_order
    limit greatest(1,least(coalesce(p_limit,1000),5000));
end;
$$;

revoke all on function public.kcp_plan_occurrences(uuid,date,date,integer)
from public, anon;
grant execute on function public.kcp_plan_occurrences(uuid,date,date,integer)
to authenticated;

commit;
