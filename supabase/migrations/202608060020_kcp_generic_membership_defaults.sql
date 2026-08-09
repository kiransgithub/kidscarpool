begin;

-- The legacy membership table requires an integer grade for compatibility with
-- existing screens. Generic activity groups may use text levels such as
-- Beginner or Intermediate, which are stored in kcp_children.grade_or_level.
-- Coalesce the compatibility grade to zero without losing the text level.

alter table public.kcp_memberships
    alter column grade set default 0;

create or replace function public.kcp_default_legacy_membership_grade()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
    new.grade := coalesce(new.grade, 0);
    return new;
end;
$$;

drop trigger if exists kcp_membership_default_legacy_grade
on public.kcp_memberships;

create trigger kcp_membership_default_legacy_grade
before insert or update of grade
on public.kcp_memberships
for each row
execute function public.kcp_default_legacy_membership_grade();

revoke all on function public.kcp_default_legacy_membership_grade()
from public, anon, authenticated;

commit;
