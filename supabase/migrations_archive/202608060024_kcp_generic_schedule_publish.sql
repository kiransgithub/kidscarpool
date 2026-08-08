begin;

-- ---------------------------------------------------------------------------
-- Publish a generic plan into immutable schedule-version metadata,
-- responsibility blocks and concrete trips.
-- ---------------------------------------------------------------------------

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
    v_plan public.kcp_schedule_plans;
    v_group public.kcp_groups;
    v_publisher_participant uuid;
    v_schedule_version integer;
    v_occurrence_count integer;
    v_trip_count integer;
begin
    select plan.*
      into v_plan
      from public.kcp_schedule_plans plan
     where plan.id = p_plan_id
     for update;

    if not found then
        raise exception 'Schedule plan not found';
    end if;
    if not public.kcp_is_admin(v_plan.group_id) then
        raise exception 'Owner or admin role required';
    end if;
    if v_plan.status <> 'draft' then
        raise exception 'Only a draft schedule plan can be published';
    end if;
    if v_plan.starts_on is null or v_plan.ends_on is null then
        raise exception 'The schedule plan needs a date range';
    end if;
    if not exists (
        select 1
        from public.kcp_recurring_sessions session
        where session.schedule_plan_id = v_plan.id
          and session.status = 'active'
    ) then
        raise exception 'Add at least one recurring ride session';
    end if;

    select count(*)
      into v_occurrence_count
      from public.kcp_plan_occurrences(
          v_plan.id,
          v_plan.starts_on,
          v_plan.ends_on,
          5000
      );

    if v_occurrence_count = 0 then
        raise exception 'The plan produced no trips. Check dates, weekdays and recurrence settings.';
    end if;

    select group_row.*
      into v_group
      from public.kcp_groups group_row
     where group_row.id = v_plan.group_id
     for update;

    v_publisher_participant := public.kcp_current_participant_id(v_plan.group_id);
    v_schedule_version := greatest(
        v_group.current_schedule_version + 1,
        coalesce((
            select max(version) + 1
            from public.kcp_schedule_versions
            where group_id = v_plan.group_id
        ), 1)
    );

    update public.kcp_schedule_versions version_row
       set status = 'superseded'
     where version_row.group_id = v_plan.group_id
       and version_row.status = 'published';

    insert into public.kcp_schedule_versions(
        group_id,version,status,reason,generated_by,generated_at,
        published_by,published_at,change_summary
    ) values (
        v_plan.group_id,
        v_schedule_version,
        'published',
        coalesce(nullif(trim(p_reason),''),'Flexible schedule published'),
        auth.uid(),
        now(),
        auth.uid(),
        now(),
        jsonb_build_object(
            'schedulePlanId',v_plan.id,
            'schedulePlanVersion',v_plan.version,
            'engine','generic_schedule_plan',
            'startsOn',v_plan.starts_on,
            'endsOn',v_plan.ends_on,
            'outboundLabel',v_plan.outbound_label,
            'returnLabel',v_plan.return_label,
            'occurrences',v_occurrence_count
        )
    );

    update public.kcp_schedule_plans plan
       set status = 'superseded',
           updated_at = now()
     where plan.group_id = v_plan.group_id
       and plan.status = 'published'
       and plan.id <> v_plan.id;

    update public.kcp_schedule_plans plan
       set status = 'published',
           published_by_participant_id = v_publisher_participant,
           published_at = now(),
           updated_at = now()
     where plan.id = v_plan.id;

    update public.kcp_groups group_row
       set active_schedule_plan_id = v_plan.id,
           current_schedule_version = v_schedule_version,
           schedule_start_date = v_plan.starts_on,
           schedule_end_date = v_plan.ends_on,
           service_weekdays = coalesce((
               select array_agg(distinct session.weekday order by session.weekday)::smallint[]
               from public.kcp_recurring_sessions session
               where session.schedule_plan_id = v_plan.id
                 and session.status = 'active'
           ), group_row.service_weekdays),
           drop_time = coalesce((
               select min(session.outbound_time)
               from public.kcp_recurring_sessions session
               where session.schedule_plan_id = v_plan.id
                 and session.status = 'active'
                 and session.outbound_enabled
           ), group_row.drop_time),
           pickup_time = coalesce((
               select min(session.return_time)
               from public.kcp_recurring_sessions session
               where session.schedule_plan_id = v_plan.id
                 and session.status = 'active'
                 and session.return_enabled
           ), group_row.pickup_time),
           auto_complete_after_minutes = v_plan.auto_complete_after_minutes,
           schedule_policy = 'generic_plan',
           updated_at = now()
     where group_row.id = v_plan.group_id;

    insert into public.kcp_responsibility_blocks(
        group_id,schedule_plan_id,schedule_version,policy_id,block_key,
        block_start,block_end,participant_id,status
    )
    select
        v_plan.group_id,
        v_plan.id,
        v_schedule_version,
        occurrence.policy_id,
        occurrence.block_key,
        min(occurrence.service_date),
        max(occurrence.service_date),
        occurrence.participant_id,
        case when occurrence.participant_id is null
             then 'coverage_needed' else 'assigned' end
    from public.kcp_plan_occurrences(
        v_plan.id,v_plan.starts_on,v_plan.ends_on,5000
    ) occurrence
    group by occurrence.policy_id,occurrence.block_key,occurrence.participant_id;

    insert into public.kcp_trips(
        group_id,schedule_version,trip_date,kind,
        scheduled_driver_id,scheduled_driver_name,
        actual_driver_id,actual_driver_name,status,scheduled_time,time_label,
        notes,child_names,started_at,completed_at,volunteer_assignment,
        started_source,completed_source,schedule_plan_id,recurring_session_id,
        responsibility_block_id,scheduled_participant_id,actual_participant_id,
        leg_type,display_label,created_at,updated_at
    )
    select
        v_plan.group_id,
        v_schedule_version,
        occurrence.service_date,
        case when occurrence.leg_type = 'outbound'
             then 'morning_drop' else 'afternoon_pickup' end,
        occurrence.participant_user_id,
        occurrence.participant_name,
        null,
        null,
        case when occurrence.participant_user_id is null
             then 'coverage_needed' else 'scheduled' end,
        occurrence.scheduled_at,
        to_char(
            occurrence.scheduled_at at time zone v_plan.timezone,
            'FMHH12:MI AM'
        ),
        occurrence.session_name,
        coalesce((
            select array_agg(child.name order by child.name)
            from public.kcp_children child
            where child.group_id = v_plan.group_id
              and child.status = 'active'
        ), '{}'::text[]),
        null,
        null,
        false,
        null,
        null,
        v_plan.id,
        occurrence.session_id,
        block.id,
        occurrence.participant_id,
        null,
        occurrence.leg_type,
        occurrence.display_label,
        now(),
        now()
    from public.kcp_plan_occurrences(
        v_plan.id,v_plan.starts_on,v_plan.ends_on,5000
    ) occurrence
    left join public.kcp_responsibility_blocks block
      on block.schedule_plan_id = v_plan.id
     and block.schedule_version = v_schedule_version
     and block.block_key = occurrence.block_key
     and block.policy_id is not distinct from occurrence.policy_id
     and block.participant_id is not distinct from occurrence.participant_id
    order by occurrence.scheduled_at,occurrence.session_id,occurrence.leg_type;

    get diagnostics v_trip_count = row_count;

    perform public.kcp_write_audit(
        v_plan.group_id,
        'schedule_plan_published',
        'schedule_plan',
        v_plan.id::text,
        jsonb_build_object(
            'planVersion',v_plan.version,
            'scheduleVersion',v_schedule_version,
            'tripCount',v_trip_count,
            'reason',p_reason
        )
    );

    return v_schedule_version;
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
    v_plan_id uuid;
begin
    if not public.kcp_is_member(p_group_id) then
        raise exception 'Active group membership required';
    end if;

    select plan.id
      into v_plan_id
      from public.kcp_schedule_plans plan
     where plan.group_id = p_group_id
     order by
        case when plan.status = 'draft' then 0
             when plan.id = (
                 select group_row.active_schedule_plan_id
                 from public.kcp_groups group_row
                 where group_row.id = p_group_id
             ) then 1
             else 2 end,
        plan.version desc
     limit 1;

    return jsonb_build_object(
        'plan',(
            select to_jsonb(plan)
            from public.kcp_schedule_plans plan
            where plan.id = v_plan_id
        ),
        'sessions',coalesce((
            select jsonb_agg(to_jsonb(session) order by session.weekday,session.display_order,session.id)
            from public.kcp_recurring_sessions session
            where session.schedule_plan_id = v_plan_id
        ),'[]'::jsonb),
        'policies',coalesce((
            select jsonb_agg(to_jsonb(policy) order by policy.priority desc,policy.id)
            from public.kcp_assignment_policies policy
            where policy.schedule_plan_id = v_plan_id
        ),'[]'::jsonb),
        'policyMembers',coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'policy_id',member.policy_id,
                    'participant_id',member.participant_id,
                    'rotation_position',member.rotation_position,
                    'weight',member.weight,
                    'active',member.active
                ) order by member.rotation_position
            )
            from public.kcp_assignment_policy_members member
            join public.kcp_assignment_policies policy on policy.id = member.policy_id
            where policy.schedule_plan_id = v_plan_id
        ),'[]'::jsonb),
        'participants',coalesce((
            select jsonb_agg(to_jsonb(participant) order by participant.display_name,participant.id)
            from public.kcp_group_participants participant
            where participant.group_id = p_group_id
              and participant.status = 'active'
        ),'[]'::jsonb),
        'exceptions',coalesce((
            select jsonb_agg(to_jsonb(exception_row) order by exception_row.exception_date,exception_row.id)
            from public.kcp_schedule_exceptions exception_row
            where exception_row.schedule_plan_id = v_plan_id
        ),'[]'::jsonb)
    );
end;
$$;

revoke all on function public.kcp_publish_schedule_plan(uuid,text)
from public, anon;
grant execute on function public.kcp_publish_schedule_plan(uuid,text)
to authenticated;

revoke all on function public.kcp_schedule_builder_state(uuid)
from public, anon;
grant execute on function public.kcp_schedule_builder_state(uuid)
to authenticated;

commit;
