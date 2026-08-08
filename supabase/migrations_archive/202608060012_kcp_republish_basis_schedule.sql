begin;

-- ---------------------------------------------------------------------------
-- Recreate the confirmed BASIS schedule as a new published version.
-- Version 1 remains in the database for audit/recovery and is not deleted.
-- ---------------------------------------------------------------------------

do $$
declare
    target_group uuid;
    new_version integer;
    school_days integer;
    trip_operations integer;
    kiran_operations integer;
    santhosh_operations integer;
    mohan_operations integer;
    pavan_operations integer;
begin
    select id
      into target_group
      from public.kcp_groups
     where code = 'KCP-BASIS-2026-27'
     for update;

    if target_group is null then
        raise exception 'Canonical BASIS pilot group was not found';
    end if;

    if not exists (
        select 1
        from public.kcp_trips
        where group_id = target_group
          and schedule_version = 1
    ) then
        raise exception 'Canonical BASIS version 1 schedule is missing';
    end if;

    update public.kcp_groups
       set group_kind = 'school',
           schedule_start_date = date '2026-08-10',
           schedule_end_date = date '2027-05-28',
           service_weekdays = array[1,2,3,4,5]::smallint[],
           drop_time = time '07:00',
           pickup_time = time '15:35',
           auto_lifecycle_enabled = true,
           auto_complete_after_minutes = 60,
           schedule_policy = 'fixed_weekday_friday_rotation',
           updated_at = now()
     where id = target_group;

    select greatest(
               g.current_schedule_version + 1,
               coalesce((select max(v.version) + 1 from public.kcp_schedule_versions v where v.group_id = g.id), 2),
               2
           )
      into new_version
      from public.kcp_groups g
     where g.id = target_group;

    update public.kcp_schedule_versions
       set status = 'superseded'
     where group_id = target_group
       and status = 'published';

    insert into public.kcp_schedule_versions(
        group_id, version, status, reason,
        generated_by, generated_at, published_by, published_at,
        change_summary
    )
    select
        target_group,
        new_version,
        'published',
        'Republished after calendar-optional, trip-ordering, cover-detail and lifecycle fixes',
        g.created_by,
        now(),
        g.created_by,
        now(),
        jsonb_build_object(
            'policy', 'fixed_weekday_friday_rotation',
            'sourceScheduleVersion', 1,
            'startDate', '2026-08-10',
            'endDate', '2027-05-28',
            'monday', 'Kiran',
            'tuesday', 'Santhosh',
            'wednesday', 'Mohan',
            'thursday', 'Pavan',
            'fridayRotation', jsonb_build_array('Kiran','Santhosh','Mohan','Pavan'),
            'calendarSource', 'BASIS Phoenix Primary Academic Calendar 2026-27',
            'manualStartLeadMinutes', 10,
            'autoCompleteAfterMinutes', 60
        )
    from public.kcp_groups g
    where g.id = target_group;

    insert into public.kcp_trips(
        group_id, schedule_version, trip_date, kind,
        scheduled_driver_id, scheduled_driver_name,
        actual_driver_id, actual_driver_name,
        status, scheduled_time, time_label, notes, child_names,
        started_at, completed_at, volunteer_assignment,
        started_source, completed_source, created_at, updated_at
    )
    select
        t.group_id,
        new_version,
        t.trip_date,
        t.kind,
        t.scheduled_driver_id,
        t.scheduled_driver_name,
        null,
        null,
        'scheduled',
        t.scheduled_time,
        t.time_label,
        t.notes,
        t.child_names,
        null,
        null,
        false,
        null,
        null,
        now(),
        now()
    from public.kcp_trips t
    where t.group_id = target_group
      and t.schedule_version = 1
    order by t.trip_date, case when t.kind = 'morning_drop' then 0 else 1 end;

    update public.kcp_groups
       set current_schedule_version = new_version,
           updated_at = now()
     where id = target_group;

    insert into public.kcp_audit_events(
        group_id, actor_id, action, entity_type, entity_id, details
    )
    select
        target_group,
        g.created_by,
        'schedule_republished_after_regression_fixes',
        'schedule_version',
        new_version::text,
        jsonb_build_object(
            'sourceVersion', 1,
            'newVersion', new_version,
            'schoolDays', 177,
            'tripOperations', 354,
            'startDate', '2026-08-10',
            'calendarPreserved', true
        )
    from public.kcp_groups g
    where g.id = target_group;

    select count(distinct trip_date), count(*)
      into school_days, trip_operations
      from public.kcp_trips
     where group_id = target_group
       and schedule_version = new_version;

    select count(*) into kiran_operations
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = new_version
      and scheduled_driver_name = 'Kiran';

    select count(*) into santhosh_operations
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = new_version
      and scheduled_driver_name = 'Santhosh';

    select count(*) into mohan_operations
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = new_version
      and scheduled_driver_name = 'Mohan';

    select count(*) into pavan_operations
    from public.kcp_trips
    where group_id = target_group
      and schedule_version = new_version
      and scheduled_driver_name = 'Pavan';

    if school_days <> 177 or trip_operations <> 354 then
        raise exception 'Republished BASIS schedule expected 177 days/354 trips, found %/%',
            school_days, trip_operations;
    end if;
    if kiran_operations <> 82
       or santhosh_operations <> 92
       or mohan_operations <> 88
       or pavan_operations <> 92 then
        raise exception 'Republished driver totals are incorrect: Kiran %, Santhosh %, Mohan %, Pavan %',
            kiran_operations, santhosh_operations, mohan_operations, pavan_operations;
    end if;
end;
$$;

commit;
