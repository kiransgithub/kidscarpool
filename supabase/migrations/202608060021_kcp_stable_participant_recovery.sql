begin;

-- ---------------------------------------------------------------------------
-- Preserve the stable group participant when an anonymous Auth identity is
-- transferred. Migration 016 creates the replacement membership before it
-- marks the former membership removed; the membership-sync trigger therefore
-- creates a short-lived replacement participant. This trigger merges that row
-- back into the original stable participant before completing the transfer.
-- ---------------------------------------------------------------------------

create or replace function public.kcp_reconcile_participant_after_membership_transfer()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    target_membership public.kcp_memberships;
    source_participant public.kcp_group_participants;
    target_participant public.kcp_group_participants;
begin
    if old.status <> 'active' or new.status <> 'removed' then
        return new;
    end if;

    select membership.*
      into target_membership
      from public.kcp_memberships membership
     where membership.group_id = new.group_id
       and membership.user_id <> new.user_id
       and membership.status = 'active'
       and lower(membership.parent_name) = lower(new.parent_name)
     order by membership.updated_at desc, membership.user_id
     limit 1;

    if target_membership.user_id is null then
        return new;
    end if;

    select participant.*
      into source_participant
      from public.kcp_group_participants participant
     where participant.group_id = new.group_id
       and participant.user_id = new.user_id
     limit 1;

    select participant.*
      into target_participant
      from public.kcp_group_participants participant
     where participant.group_id = new.group_id
       and participant.user_id = target_membership.user_id
     limit 1;

    if source_participant.id is null then
        -- Old data without a stable participant already has the desired target
        -- participant through the membership trigger.
        return new;
    end if;

    if target_participant.id is not null
       and target_participant.id <> source_participant.id then
        update public.kcp_schedule_plans
           set created_by_participant_id = source_participant.id
         where created_by_participant_id = target_participant.id;

        update public.kcp_schedule_plans
           set published_by_participant_id = source_participant.id
         where published_by_participant_id = target_participant.id;

        update public.kcp_assignment_policies
           set fixed_participant_id = source_participant.id
         where fixed_participant_id = target_participant.id;

        update public.kcp_schedule_exceptions
           set override_participant_id = source_participant.id
         where override_participant_id = target_participant.id;

        update public.kcp_schedule_exceptions
           set created_by_participant_id = source_participant.id
         where created_by_participant_id = target_participant.id;

        update public.kcp_responsibility_blocks
           set participant_id = source_participant.id
         where participant_id = target_participant.id;

        update public.kcp_trips
           set scheduled_participant_id = source_participant.id,
               updated_at = now()
         where scheduled_participant_id = target_participant.id;

        update public.kcp_trips
           set actual_participant_id = source_participant.id,
               updated_at = now()
         where actual_participant_id = target_participant.id;

        delete from public.kcp_assignment_policy_members target_member
         where target_member.participant_id = target_participant.id
           and exists (
               select 1
               from public.kcp_assignment_policy_members source_member
               where source_member.policy_id = target_member.policy_id
                 and source_member.participant_id = source_participant.id
           );

        update public.kcp_assignment_policy_members
           set participant_id = source_participant.id
         where participant_id = target_participant.id;

        insert into public.kcp_children(
            group_id,
            participant_id,
            name,
            grade_or_level,
            legacy_grade,
            pickup_tag,
            status,
            created_at,
            updated_at
        )
        select
            child.group_id,
            source_participant.id,
            child.name,
            child.grade_or_level,
            child.legacy_grade,
            child.pickup_tag,
            child.status,
            child.created_at,
            now()
        from public.kcp_children child
        where child.participant_id = target_participant.id
        on conflict (group_id, participant_id, name) do update
           set grade_or_level = coalesce(
                   excluded.grade_or_level,
                   public.kcp_children.grade_or_level
               ),
               legacy_grade = coalesce(
                   excluded.legacy_grade,
                   public.kcp_children.legacy_grade
               ),
               pickup_tag = coalesce(
                   excluded.pickup_tag,
                   public.kcp_children.pickup_tag
               ),
               status = 'active',
               updated_at = now();

        delete from public.kcp_children
         where participant_id = target_participant.id;

        delete from public.kcp_group_participants
         where id = target_participant.id;
    end if;

    update public.kcp_group_participants
       set user_id = target_membership.user_id,
           display_name = target_membership.parent_name,
           can_drive = target_membership.role <> 'viewer',
           status = 'active',
           source = 'membership',
           updated_at = now()
     where id = source_participant.id;

    insert into public.kcp_audit_events(
        group_id,
        actor_id,
        action,
        entity_type,
        entity_id,
        details
    ) values (
        new.group_id,
        target_membership.user_id,
        'stable_participant_identity_rebound',
        'group_participant',
        source_participant.id::text,
        jsonb_build_object(
            'sourceUserId', new.user_id,
            'targetUserId', target_membership.user_id,
            'participantIdPreserved', source_participant.id
        )
    );

    return new;
end;
$$;

drop trigger if exists kcp_membership_reconcile_participant_transfer
on public.kcp_memberships;

create trigger kcp_membership_reconcile_participant_transfer
after update of status
on public.kcp_memberships
for each row
when (old.status = 'active' and new.status = 'removed')
execute function public.kcp_reconcile_participant_after_membership_transfer();

revoke all on function public.kcp_reconcile_participant_after_membership_transfer()
from public, anon, authenticated;

commit;
