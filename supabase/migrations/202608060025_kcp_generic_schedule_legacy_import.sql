begin;

-- ---------------------------------------------------------------------------
-- Import existing groups into the generic schedule-plan model.
--
-- This migration does not regenerate, delete, or supersede any existing trip.
-- It creates an editable plan mirror and attaches compatibility metadata so an
-- administrator can preview a future generic version before publishing it.
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
    case when group_row.current_schedule_version > 0
         then 'published' else 'draft' end,
    coalesce(
        group_row.schedule_start_date,
        (
            select min(trip.trip_date)
            from public.kcp_trips trip
            where trip.group_id = group_row.id
        )
    ),
    coalesce(
        group_row.schedule_end_date,
        (
            select max(trip.trip_date)
            from public.kcp_trips trip
            where trip.group_id = group_row.id
        )
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
    owner_participant.id,
    case when group_row.current_schedule_version > 0
         then owner_participant.id else null end,
    case when group_row.current_schedule_version > 0
         then now() else null end
from public.kcp_groups group_row
left join public.kcp_group_participants owner_participant
  on owner_participant.group_id = group_row.id
 and owner_participant.user_id = group_row.created_by
where not exists (
    select 1
    from public.kcp_schedule_plans existing_plan
    where existing_plan.group_id = group_row.id
);

-- One compatibility session is created per legacy service weekday. The live
-- published trips remain authoritative until an administrator publishes a new
-- generic plan from the mobile builder.
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
join public.kcp_groups group_row
  on group_row.id = plan.group_id
cross join lateral unnest(group_row.service_weekdays) weekday_value
where plan.name = 'Imported recurring schedule'
  and not exists (
      select 1
      from public.kcp_recurring_sessions existing_session
      where existing_session.schedule_plan_id = plan.id
  );

-- Existing bespoke/fixed assignments cannot be inferred safely from one
-- group-level policy. Import them as manual so no driver is silently changed.
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
    jsonb_build_object(
        'source','legacy_schedule',
        'existingTripsRemainAuthoritative',true
    )
from public.kcp_schedule_plans plan
where plan.name = 'Imported recurring schedule'
  and not exists (
      select 1
      from public.kcp_assignment_policies existing_policy
      where existing_policy.schedule_plan_id = plan.id
  );

update public.kcp_groups group_row
   set active_schedule_plan_id = plan.id,
       updated_at = now()
  from public.kcp_schedule_plans plan
 where plan.group_id = group_row.id
   and plan.name = 'Imported recurring schedule'
   and plan.status = 'published'
   and group_row.active_schedule_plan_id is null;

-- Attach generic metadata to historical trips without changing their dates,
-- drivers, status, points, or schedule version. Correlated scalar subqueries are
-- used deliberately so the UPDATE target is never referenced from a JOIN ON.
update public.kcp_trips trip
   set schedule_plan_id = plan.id,
       recurring_session_id = (
           select session.id
           from public.kcp_recurring_sessions session
           where session.schedule_plan_id = plan.id
             and session.weekday = extract(isodow from trip.trip_date)::integer
           order by session.display_order, session.id
           limit 1
       ),
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
           (
               select participant.id
               from public.kcp_group_participants participant
               where participant.group_id = trip.group_id
                 and (
                     participant.user_id = trip.scheduled_driver_id
                     or (
                         trip.scheduled_driver_id is null
                         and trip.scheduled_driver_name is not null
                         and lower(participant.display_name) = lower(trip.scheduled_driver_name)
                     )
                 )
               order by participant.updated_at desc, participant.id
               limit 1
           )
       ),
       actual_participant_id = coalesce(
           trip.actual_participant_id,
           (
               select participant.id
               from public.kcp_group_participants participant
               where participant.group_id = trip.group_id
                 and (
                     participant.user_id = trip.actual_driver_id
                     or (
                         trip.actual_driver_id is null
                         and trip.actual_driver_name is not null
                         and lower(participant.display_name) = lower(trip.actual_driver_name)
                     )
                 )
               order by participant.updated_at desc, participant.id
               limit 1
           )
       ),
       updated_at = now()
  from public.kcp_schedule_plans plan
 where plan.group_id = trip.group_id
   and plan.name = 'Imported recurring schedule'
   and trip.schedule_plan_id is null;

-- Importing metadata is an administrative migration, not a user mutation. The
-- audit event is emitted only once for each imported group.
insert into public.kcp_audit_events(
    group_id,
    actor_id,
    action,
    entity_type,
    entity_id,
    details
)
select
    plan.group_id,
    group_row.created_by,
    'legacy_schedule_imported',
    'schedule_plan',
    plan.id::text,
    jsonb_build_object(
        'planVersion',plan.version,
        'preservedCurrentScheduleVersion',group_row.current_schedule_version,
        'tripsRegenerated',false
    )
from public.kcp_schedule_plans plan
join public.kcp_groups group_row on group_row.id = plan.group_id
where plan.name = 'Imported recurring schedule'
  and not exists (
      select 1
      from public.kcp_audit_events audit
      where audit.group_id = plan.group_id
        and audit.action = 'legacy_schedule_imported'
        and audit.entity_type = 'schedule_plan'
        and audit.entity_id = plan.id::text
  );

commit;
