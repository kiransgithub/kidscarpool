begin;

-- ---------------------------------------------------------------------------
-- Child, driver and vehicle operational safety profiles
-- ---------------------------------------------------------------------------

alter table public.kcp_groups
    add column if not exists safety_profiles_required boolean not null default false;

create table if not exists public.kcp_child_safety_profiles (
    child_id uuid primary key references public.kcp_children(id) on delete cascade,
    pickup_address text,
    dropoff_address text,
    authorized_pickup_people jsonb not null default '[]'::jsonb,
    emergency_contact_name text,
    emergency_contact_phone text,
    seat_requirement text not null default 'none'
        check (seat_requirement in ('none','booster','car_seat','front_seat_restricted','other')),
    critical_alert text,
    pickup_instructions text,
    consent_confirmed_at timestamptz,
    updated_by uuid not null references auth.users(id) on delete restrict,
    updated_at timestamptz not null default now(),
    check (authorized_pickup_people is null or jsonb_typeof(authorized_pickup_people) = 'array')
);

create table if not exists public.kcp_driver_safety_profiles (
    participant_id uuid primary key references public.kcp_group_participants(id) on delete cascade,
    emergency_contact_name text,
    emergency_contact_phone text,
    license_acknowledged_at timestamptz,
    insurance_acknowledged_at timestamptz,
    safety_terms_acknowledged_at timestamptz,
    notes text,
    updated_by uuid not null references auth.users(id) on delete restrict,
    updated_at timestamptz not null default now()
);

create table if not exists public.kcp_vehicles (
    id uuid primary key default gen_random_uuid(),
    participant_id uuid not null references public.kcp_group_participants(id) on delete cascade,
    description text not null,
    seat_capacity integer not null check (seat_capacity between 1 and 12),
    booster_capacity integer not null default 0 check (booster_capacity between 0 and 12),
    car_seat_capacity integer not null default 0 check (car_seat_capacity between 0 and 12),
    active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (participant_id, description)
);

create index if not exists kcp_vehicles_participant_active_idx
    on public.kcp_vehicles(participant_id, active);

alter table public.kcp_child_safety_profiles enable row level security;
alter table public.kcp_driver_safety_profiles enable row level security;
alter table public.kcp_vehicles enable row level security;

create or replace function public.kcp_owns_participant(p_participant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1 from public.kcp_group_participants participant
        where participant.id = p_participant_id
          and participant.user_id = auth.uid()
          and participant.status = 'active'
    );
$$;

create or replace function public.kcp_can_manage_participant(p_participant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1 from public.kcp_group_participants participant
        where participant.id = p_participant_id
          and (
              participant.user_id = auth.uid()
              or public.kcp_is_admin(participant.group_id)
          )
    );
$$;

create or replace function public.kcp_can_manage_child(p_child_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select exists (
        select 1
        from public.kcp_children child
        join public.kcp_group_participants participant on participant.id = child.participant_id
        where child.id = p_child_id
          and (
              participant.user_id = auth.uid()
              or public.kcp_is_admin(child.group_id)
          )
    );
$$;

drop policy if exists kcp_child_safety_select on public.kcp_child_safety_profiles;
create policy kcp_child_safety_select
on public.kcp_child_safety_profiles for select to authenticated
using (public.kcp_can_manage_child(child_id));

drop policy if exists kcp_child_safety_insert on public.kcp_child_safety_profiles;
create policy kcp_child_safety_insert
on public.kcp_child_safety_profiles for insert to authenticated
with check (public.kcp_can_manage_child(child_id) and updated_by = auth.uid());

drop policy if exists kcp_child_safety_update on public.kcp_child_safety_profiles;
create policy kcp_child_safety_update
on public.kcp_child_safety_profiles for update to authenticated
using (public.kcp_can_manage_child(child_id))
with check (public.kcp_can_manage_child(child_id) and updated_by = auth.uid());

drop policy if exists kcp_driver_safety_select on public.kcp_driver_safety_profiles;
create policy kcp_driver_safety_select
on public.kcp_driver_safety_profiles for select to authenticated
using (public.kcp_can_manage_participant(participant_id));

drop policy if exists kcp_driver_safety_insert on public.kcp_driver_safety_profiles;
create policy kcp_driver_safety_insert
on public.kcp_driver_safety_profiles for insert to authenticated
with check (public.kcp_can_manage_participant(participant_id) and updated_by = auth.uid());

drop policy if exists kcp_driver_safety_update on public.kcp_driver_safety_profiles;
create policy kcp_driver_safety_update
on public.kcp_driver_safety_profiles for update to authenticated
using (public.kcp_can_manage_participant(participant_id))
with check (public.kcp_can_manage_participant(participant_id) and updated_by = auth.uid());

drop policy if exists kcp_vehicles_select on public.kcp_vehicles;
create policy kcp_vehicles_select
on public.kcp_vehicles for select to authenticated
using (public.kcp_can_manage_participant(participant_id));

drop policy if exists kcp_vehicles_insert on public.kcp_vehicles;
create policy kcp_vehicles_insert
on public.kcp_vehicles for insert to authenticated
with check (public.kcp_can_manage_participant(participant_id));

drop policy if exists kcp_vehicles_update on public.kcp_vehicles;
create policy kcp_vehicles_update
on public.kcp_vehicles for update to authenticated
using (public.kcp_can_manage_participant(participant_id))
with check (public.kcp_can_manage_participant(participant_id));

drop policy if exists kcp_vehicles_delete on public.kcp_vehicles;
create policy kcp_vehicles_delete
on public.kcp_vehicles for delete to authenticated
using (public.kcp_can_manage_participant(participant_id));

create or replace function public.kcp_upsert_child_safety_profile(
    p_child_id uuid,
    p_pickup_address text default null,
    p_dropoff_address text default null,
    p_authorized_pickup_people jsonb default '[]'::jsonb,
    p_emergency_contact_name text default null,
    p_emergency_contact_phone text default null,
    p_seat_requirement text default 'none',
    p_critical_alert text default null,
    p_pickup_instructions text default null,
    p_confirm_consent boolean default false
)
returns public.kcp_child_safety_profiles
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result public.kcp_child_safety_profiles;
    group_id uuid;
begin
    if not public.kcp_can_manage_child(p_child_id) then raise exception 'Child profile access required'; end if;
    if p_seat_requirement not in ('none','booster','car_seat','front_seat_restricted','other') then
        raise exception 'Choose a valid seat requirement';
    end if;
    if p_authorized_pickup_people is not null and jsonb_typeof(p_authorized_pickup_people) <> 'array' then
        raise exception 'Authorized pickup people must be a list';
    end if;

    insert into public.kcp_child_safety_profiles(
        child_id, pickup_address, dropoff_address, authorized_pickup_people,
        emergency_contact_name, emergency_contact_phone, seat_requirement,
        critical_alert, pickup_instructions, consent_confirmed_at,
        updated_by, updated_at
    ) values (
        p_child_id, nullif(trim(p_pickup_address), ''), nullif(trim(p_dropoff_address), ''),
        coalesce(p_authorized_pickup_people, '[]'::jsonb),
        nullif(trim(p_emergency_contact_name), ''),
        nullif(regexp_replace(coalesce(p_emergency_contact_phone,''), '[^0-9+]', '', 'g'), ''),
        p_seat_requirement, nullif(trim(p_critical_alert), ''),
        nullif(trim(p_pickup_instructions), ''),
        case when p_confirm_consent then now() else null end,
        auth.uid(), now()
    )
    on conflict (child_id) do update
       set pickup_address = excluded.pickup_address,
           dropoff_address = excluded.dropoff_address,
           authorized_pickup_people = excluded.authorized_pickup_people,
           emergency_contact_name = excluded.emergency_contact_name,
           emergency_contact_phone = excluded.emergency_contact_phone,
           seat_requirement = excluded.seat_requirement,
           critical_alert = excluded.critical_alert,
           pickup_instructions = excluded.pickup_instructions,
           consent_confirmed_at = coalesce(excluded.consent_confirmed_at, public.kcp_child_safety_profiles.consent_confirmed_at),
           updated_by = auth.uid(),
           updated_at = now()
    returning * into result;

    select child.group_id into group_id from public.kcp_children child where child.id = p_child_id;
    perform public.kcp_write_audit(
        group_id, 'child_safety_profile_updated', 'child', p_child_id::text,
        jsonb_build_object('seatRequirement', p_seat_requirement, 'consentConfirmed', p_confirm_consent)
    );
    return result;
end;
$$;

create or replace function public.kcp_upsert_driver_safety_profile(
    p_participant_id uuid,
    p_emergency_contact_name text default null,
    p_emergency_contact_phone text default null,
    p_license_acknowledged boolean default false,
    p_insurance_acknowledged boolean default false,
    p_safety_terms_acknowledged boolean default false,
    p_notes text default null
)
returns public.kcp_driver_safety_profiles
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result public.kcp_driver_safety_profiles;
    group_id uuid;
begin
    if not public.kcp_can_manage_participant(p_participant_id) then raise exception 'Driver profile access required'; end if;

    insert into public.kcp_driver_safety_profiles(
        participant_id, emergency_contact_name, emergency_contact_phone,
        license_acknowledged_at, insurance_acknowledged_at,
        safety_terms_acknowledged_at, notes, updated_by, updated_at
    ) values (
        p_participant_id, nullif(trim(p_emergency_contact_name), ''),
        nullif(regexp_replace(coalesce(p_emergency_contact_phone,''), '[^0-9+]', '', 'g'), ''),
        case when p_license_acknowledged then now() end,
        case when p_insurance_acknowledged then now() end,
        case when p_safety_terms_acknowledged then now() end,
        nullif(trim(p_notes), ''), auth.uid(), now()
    )
    on conflict (participant_id) do update
       set emergency_contact_name = excluded.emergency_contact_name,
           emergency_contact_phone = excluded.emergency_contact_phone,
           license_acknowledged_at = coalesce(public.kcp_driver_safety_profiles.license_acknowledged_at, excluded.license_acknowledged_at),
           insurance_acknowledged_at = coalesce(public.kcp_driver_safety_profiles.insurance_acknowledged_at, excluded.insurance_acknowledged_at),
           safety_terms_acknowledged_at = coalesce(public.kcp_driver_safety_profiles.safety_terms_acknowledged_at, excluded.safety_terms_acknowledged_at),
           notes = excluded.notes,
           updated_by = auth.uid(),
           updated_at = now()
    returning * into result;

    select participant.group_id into group_id from public.kcp_group_participants participant where participant.id = p_participant_id;
    perform public.kcp_write_audit(
        group_id, 'driver_safety_profile_updated', 'participant', p_participant_id::text,
        jsonb_build_object(
            'licenseAcknowledged', result.license_acknowledged_at is not null,
            'insuranceAcknowledged', result.insurance_acknowledged_at is not null,
            'safetyTermsAcknowledged', result.safety_terms_acknowledged_at is not null
        )
    );
    return result;
end;
$$;

create or replace function public.kcp_upsert_vehicle(
    p_participant_id uuid,
    p_vehicle_id uuid default null,
    p_description text default null,
    p_seat_capacity integer default 1,
    p_booster_capacity integer default 0,
    p_car_seat_capacity integer default 0,
    p_active boolean default true
)
returns public.kcp_vehicles
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    result public.kcp_vehicles;
    group_id uuid;
begin
    if not public.kcp_can_manage_participant(p_participant_id) then raise exception 'Vehicle access required'; end if;
    if length(trim(coalesce(p_description,''))) < 2 then raise exception 'Vehicle description is required'; end if;
    if p_seat_capacity < 1 or p_seat_capacity > 12 then raise exception 'Seat capacity must be between 1 and 12'; end if;
    if p_booster_capacity < 0 or p_booster_capacity > p_seat_capacity then raise exception 'Booster capacity exceeds seat capacity'; end if;
    if p_car_seat_capacity < 0 or p_car_seat_capacity > p_seat_capacity then raise exception 'Car-seat capacity exceeds seat capacity'; end if;

    if p_vehicle_id is null then
        insert into public.kcp_vehicles(
            participant_id, description, seat_capacity, booster_capacity,
            car_seat_capacity, active
        ) values (
            p_participant_id, trim(p_description), p_seat_capacity,
            p_booster_capacity, p_car_seat_capacity, p_active
        ) returning * into result;
    else
        update public.kcp_vehicles
           set description = trim(p_description),
               seat_capacity = p_seat_capacity,
               booster_capacity = p_booster_capacity,
               car_seat_capacity = p_car_seat_capacity,
               active = p_active,
               updated_at = now()
         where id = p_vehicle_id
           and participant_id = p_participant_id
        returning * into result;
        if not found then raise exception 'Vehicle not found'; end if;
    end if;

    select participant.group_id into group_id from public.kcp_group_participants participant where participant.id = p_participant_id;
    perform public.kcp_write_audit(
        group_id, 'vehicle_profile_updated', 'vehicle', result.id::text,
        jsonb_build_object(
            'seatCapacity', result.seat_capacity,
            'boosterCapacity', result.booster_capacity,
            'carSeatCapacity', result.car_seat_capacity,
            'active', result.active
        )
    );
    return result;
end;
$$;

create or replace function public.kcp_set_group_safety_requirement(
    p_group_id uuid,
    p_required boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if not public.kcp_is_admin(p_group_id) then raise exception 'Owner or admin role required'; end if;
    update public.kcp_groups set safety_profiles_required = p_required, updated_at = now() where id = p_group_id;
    perform public.kcp_write_audit(
        p_group_id, 'group_safety_requirement_changed', 'group', p_group_id::text,
        jsonb_build_object('required', p_required)
    );
end;
$$;

create or replace function public.kcp_my_safety_profile(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    participant public.kcp_group_participants;
    result jsonb;
begin
    if not public.kcp_is_member(p_group_id) then raise exception 'Active group membership required'; end if;

    select * into participant
    from public.kcp_group_participants
    where group_id = p_group_id and user_id = auth.uid() and status = 'active'
    limit 1;

    select jsonb_build_object(
        'participant', to_jsonb(participant),
        'driverProfile', (
            select to_jsonb(driver) from public.kcp_driver_safety_profiles driver
            where driver.participant_id = participant.id
        ),
        'vehicles', coalesce((
            select jsonb_agg(to_jsonb(vehicle) order by vehicle.created_at)
            from public.kcp_vehicles vehicle where vehicle.participant_id = participant.id
        ), '[]'::jsonb),
        'children', coalesce((
            select jsonb_agg(
                to_jsonb(child) || jsonb_build_object('safetyProfile', to_jsonb(profile))
                order by child.name
            )
            from public.kcp_children child
            left join public.kcp_child_safety_profiles profile on profile.child_id = child.id
            where child.participant_id = participant.id and child.status = 'active'
        ), '[]'::jsonb),
        'required', (select group_row.safety_profiles_required from public.kcp_groups group_row where group_row.id = p_group_id)
    ) into result;

    return coalesce(result, jsonb_build_object('participant', null, 'driverProfile', null, 'vehicles', '[]'::jsonb, 'children', '[]'::jsonb, 'required', false));
end;
$$;

create or replace function public.kcp_trip_capacity_status(
    p_trip_id uuid,
    p_participant_id uuid
)
returns table(
    eligible boolean,
    required_seats integer,
    available_seats integer,
    required_boosters integer,
    available_boosters integer,
    required_car_seats integer,
    available_car_seats integer,
    message text
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
    trip public.kcp_trips;
    group_required boolean;
    seats integer;
    boosters integer;
    car_seats integer;
    vehicle record;
    driver_complete boolean;
begin
    select * into trip from public.kcp_trips where id = p_trip_id;
    if not found then raise exception 'Trip not found'; end if;
    if not public.kcp_is_member(trip.group_id) then raise exception 'Active group membership required'; end if;

    select safety_profiles_required into group_required from public.kcp_groups where id = trip.group_id;
    select count(*),
           count(*) filter (where coalesce(profile.seat_requirement, 'none') = 'booster'),
           count(*) filter (where coalesce(profile.seat_requirement, 'none') = 'car_seat')
      into seats, boosters, car_seats
      from unnest(trip.child_names) child_name
      left join public.kcp_children child
        on child.group_id = trip.group_id and child.name = child_name and child.status = 'active'
      left join public.kcp_child_safety_profiles profile on profile.child_id = child.id;

    select * into vehicle
    from public.kcp_vehicles
    where participant_id = p_participant_id and active
    order by seat_capacity desc, updated_at desc
    limit 1;

    select exists (
        select 1 from public.kcp_driver_safety_profiles driver
        where driver.participant_id = p_participant_id
          and driver.license_acknowledged_at is not null
          and driver.insurance_acknowledged_at is not null
          and driver.safety_terms_acknowledged_at is not null
    ) into driver_complete;

    if vehicle is null then
        return query select
            not group_required,
            seats, 0, boosters, 0, car_seats, 0,
            case when group_required then 'Add an active vehicle before accepting this ride' else 'Vehicle profile is recommended' end;
        return;
    end if;

    return query select
        (not group_required or driver_complete)
          and vehicle.seat_capacity >= seats
          and vehicle.booster_capacity >= boosters
          and vehicle.car_seat_capacity >= car_seats,
        seats, vehicle.seat_capacity, boosters, vehicle.booster_capacity,
        car_seats, vehicle.car_seat_capacity,
        case
            when group_required and not driver_complete then 'Complete the driver safety acknowledgements'
            when vehicle.seat_capacity < seats then 'Vehicle does not have enough child seats'
            when vehicle.booster_capacity < boosters then 'Vehicle does not have enough booster seats'
            when vehicle.car_seat_capacity < car_seats then 'Vehicle does not have enough car-seat positions'
            else 'Vehicle capacity is compatible'
        end;
end;
$$;

revoke all on table public.kcp_child_safety_profiles from public, anon;
revoke all on table public.kcp_driver_safety_profiles from public, anon;
revoke all on table public.kcp_vehicles from public, anon;
grant select, insert, update on public.kcp_child_safety_profiles to authenticated;
grant select, insert, update on public.kcp_driver_safety_profiles to authenticated;
grant select, insert, update, delete on public.kcp_vehicles to authenticated;

revoke all on function public.kcp_owns_participant(uuid) from public, anon;
revoke all on function public.kcp_can_manage_participant(uuid) from public, anon;
revoke all on function public.kcp_can_manage_child(uuid) from public, anon;
revoke all on function public.kcp_upsert_child_safety_profile(uuid,text,text,jsonb,text,text,text,text,text,boolean) from public, anon;
revoke all on function public.kcp_upsert_driver_safety_profile(uuid,text,text,boolean,boolean,boolean,text) from public, anon;
revoke all on function public.kcp_upsert_vehicle(uuid,uuid,text,integer,integer,integer,boolean) from public, anon;
revoke all on function public.kcp_set_group_safety_requirement(uuid,boolean) from public, anon;
revoke all on function public.kcp_my_safety_profile(uuid) from public, anon;
revoke all on function public.kcp_trip_capacity_status(uuid,uuid) from public, anon;

grant execute on function public.kcp_owns_participant(uuid) to authenticated;
grant execute on function public.kcp_can_manage_participant(uuid) to authenticated;
grant execute on function public.kcp_can_manage_child(uuid) to authenticated;
grant execute on function public.kcp_upsert_child_safety_profile(uuid,text,text,jsonb,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.kcp_upsert_driver_safety_profile(uuid,text,text,boolean,boolean,boolean,text) to authenticated;
grant execute on function public.kcp_upsert_vehicle(uuid,uuid,text,integer,integer,integer,boolean) to authenticated;
grant execute on function public.kcp_set_group_safety_requirement(uuid,boolean) to authenticated;
grant execute on function public.kcp_my_safety_profile(uuid) to authenticated;
grant execute on function public.kcp_trip_capacity_status(uuid,uuid) to authenticated;

commit;
