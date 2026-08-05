-- Kidscarpool (KCP) pilot schema for Supabase PostgreSQL.
-- Run in Supabase Dashboard > SQL Editor on a new project.

create extension if not exists pgcrypto;

create type public.kcp_member_role as enum ('admin', 'parent');
create type public.kcp_trip_kind as enum ('morning_drop', 'afternoon_pickup');
create type public.kcp_trip_status as enum ('scheduled', 'cover_requested', 'volunteer_assigned', 'in_progress', 'completed', 'cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text unique,
  display_name text not null,
  created_at timestamptz not null default now()
);

create table public.schools (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  address text,
  timezone text not null default 'America/Phoenix',
  created_at timestamptz not null default now()
);

create table public.carpool_groups (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id),
  name text not null,
  invite_code text not null unique,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id uuid not null references public.carpool_groups(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role public.kcp_member_role not null default 'parent',
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (group_id, profile_id)
);

create table public.children (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.carpool_groups(id) on delete cascade,
  guardian_id uuid not null references public.profiles(id),
  display_name text not null,
  grade smallint not null check (grade between 0 and 12),
  active boolean not null default true
);

create table public.parent_constraints (
  group_id uuid not null references public.carpool_groups(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  drop_weekdays smallint[] not null default '{}',
  pickup_weekdays smallint[] not null default '{}',
  notes text,
  updated_at timestamptz not null default now(),
  primary key (group_id, profile_id),
  check (drop_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),
  check (pickup_weekdays <@ array[1,2,3,4,5,6,7]::smallint[])
);

create table public.school_calendars (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.carpool_groups(id) on delete cascade,
  school_id uuid not null references public.schools(id),
  academic_year text not null,
  source_name text not null,
  source_hash text not null,
  uploaded_by uuid not null references public.profiles(id),
  published_at timestamptz not null default now(),
  unique (group_id, school_id, academic_year)
);

create table public.calendar_days (
  calendar_id uuid not null references public.school_calendars(id) on delete cascade,
  school_date date not null,
  day_type text not null check (day_type in ('school', 'no_school', 'early_release', 'no_late_bird', 'project_week')),
  pickup_time time,
  note text,
  primary key (calendar_id, school_date, day_type)
);

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.carpool_groups(id) on delete cascade,
  school_date date not null,
  kind public.kcp_trip_kind not null,
  scheduled_start timestamptz,
  scheduled_driver uuid not null references public.profiles(id),
  actual_driver uuid references public.profiles(id),
  status public.kcp_trip_status not null default 'scheduled',
  started_at timestamptz,
  completed_at timestamptz,
  revision integer not null default 1,
  unique (group_id, school_date, kind)
);

create table public.cover_requests (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null unique references public.trips(id) on delete cascade,
  requested_by uuid not null references public.profiles(id),
  note text,
  accepted_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);

create table public.points_ledger (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.carpool_groups(id) on delete cascade,
  trip_id uuid not null unique references public.trips(id) on delete cascade,
  profile_id uuid not null references public.profiles(id),
  points integer not null check (points in (10, 20)),
  reason text not null check (reason in ('scheduled_trip', 'volunteer_trip')),
  awarded_at timestamptz not null default now()
);

create table public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null default 'ios',
  updated_at timestamptz not null default now()
);

-- Helper: user is an approved member of a group.
create or replace function public.is_group_member(target_group uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.group_members gm
    where gm.group_id = target_group
      and gm.profile_id = auth.uid()
      and gm.approved_at is not null
  );
$$;

create or replace function public.is_group_admin(target_group uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.group_members gm
    where gm.group_id = target_group
      and gm.profile_id = auth.uid()
      and gm.role = 'admin'
      and gm.approved_at is not null
  );
$$;

alter table public.profiles enable row level security;
alter table public.schools enable row level security;
alter table public.carpool_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.children enable row level security;
alter table public.parent_constraints enable row level security;
alter table public.school_calendars enable row level security;
alter table public.calendar_days enable row level security;
alter table public.trips enable row level security;
alter table public.cover_requests enable row level security;
alter table public.points_ledger enable row level security;
alter table public.device_push_tokens enable row level security;

create policy "profile self read" on public.profiles for select using (id = auth.uid());
create policy "profile self update" on public.profiles for update using (id = auth.uid());
create policy "profile self insert" on public.profiles for insert with check (id = auth.uid());

create policy "members see groups" on public.carpool_groups for select using (public.is_group_member(id));
create policy "members see memberships" on public.group_members for select using (public.is_group_member(group_id));
create policy "members see children" on public.children for select using (public.is_group_member(group_id));
create policy "guardian manages child" on public.children for all using (guardian_id = auth.uid()) with check (guardian_id = auth.uid());

create policy "members see constraints" on public.parent_constraints for select using (public.is_group_member(group_id));
create policy "parent manages own constraints" on public.parent_constraints for all
  using (profile_id = auth.uid() and public.is_group_member(group_id))
  with check (profile_id = auth.uid() and public.is_group_member(group_id));

create policy "members see calendars" on public.school_calendars for select using (public.is_group_member(group_id));
create policy "admin creates one calendar" on public.school_calendars for insert with check (public.is_group_admin(group_id));
create policy "members see calendar days" on public.calendar_days for select using (
  exists (select 1 from public.school_calendars sc where sc.id = calendar_id and public.is_group_member(sc.group_id))
);

create policy "members see trips" on public.trips for select using (public.is_group_member(group_id));
create policy "admin manages trips" on public.trips for all using (public.is_group_admin(group_id)) with check (public.is_group_admin(group_id));
create policy "assigned driver updates trip" on public.trips for update using (
  public.is_group_member(group_id) and auth.uid() in (scheduled_driver, actual_driver)
);

create policy "members see cover requests" on public.cover_requests for select using (
  exists (select 1 from public.trips t where t.id = trip_id and public.is_group_member(t.group_id))
);
create policy "member requests cover" on public.cover_requests for insert with check (
  requested_by = auth.uid() and exists (
    select 1 from public.trips t where t.id = trip_id and public.is_group_member(t.group_id)
  )
);
create policy "member accepts cover" on public.cover_requests for update using (
  exists (select 1 from public.trips t where t.id = trip_id and public.is_group_member(t.group_id))
);

create policy "members see leaderboard" on public.points_ledger for select using (public.is_group_member(group_id));
create policy "own push token" on public.device_push_tokens for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- Award points exactly once when a trip becomes completed.
create or replace function public.award_trip_points()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  winner uuid;
  award integer;
  award_reason text;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    winner := coalesce(new.actual_driver, new.scheduled_driver);
    if new.actual_driver is not null and new.actual_driver <> new.scheduled_driver then
      award := 20;
      award_reason := 'volunteer_trip';
    else
      award := 10;
      award_reason := 'scheduled_trip';
    end if;

    insert into public.points_ledger(group_id, trip_id, profile_id, points, reason)
    values (new.group_id, new.id, winner, award, award_reason)
    on conflict (trip_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger trips_award_points
after update of status on public.trips
for each row execute function public.award_trip_points();

-- Realtime tables used by the pilot.
alter publication supabase_realtime add table public.trips;
alter publication supabase_realtime add table public.cover_requests;
alter publication supabase_realtime add table public.parent_constraints;
alter publication supabase_realtime add table public.points_ledger;
