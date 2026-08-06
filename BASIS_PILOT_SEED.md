# Preloaded BASIS Phoenix Primary pilot

This seed is additive: it does not truncate or delete existing KCP groups, profiles, calendars, trips, or audit history.

## Authoritative schedule

The shared carpool schedule begins **Monday, August 10, 2026**.

| Day | Responsible parent |
|---|---|
| Monday | Kiran |
| Tuesday | Santhosh |
| Wednesday | Mohan |
| Thursday | Pavan |
| Friday | Kiran → Santhosh → Mohan → Pavan, rotating across actual school Fridays |

Each responsible parent is assigned both the morning drop and afternoon pickup for that school day. The first school Friday, August 14, is Kiran's turn. Holidays do not consume a Friday turn.

The authoritative school calendar excludes all no-school dates and marks early-release and No-Late-Bird dates. Project Week, May 24–28, is treated as early release for all five days.

## Seeded roster

| Parent | Child | Grade | Pickup tag |
|---|---|---:|---:|
| Kiran | Thanishka | 4 | 4128 |
| Santhosh | Kavish | 5 | 5200 |
| Mohan | Saanvi | 5 | 5206 |
| Pavan | Ishi | 1 | 1118 |

On Wednesday afternoon, Kavish is excluded from the shared pickup because Santhosh handles that pickup separately for swimming. Ishi uses Late Bird for the common pickup window.

## Verified counts

- 177 scheduled school days from Aug 10, 2026 through May 28, 2027
- 354 trip records: one morning drop and one afternoon pickup per school day
- Kiran: 82 trip operations
- Santhosh: 92 trip operations
- Mohan: 88 trip operations
- Pavan: 92 trip operations

The migration fails and rolls back if these counts do not match.

## Apply

```bash
git pull --ff-only origin main
supabase db push
```

The pending migrations should include `202608060006` through `202608060009`.

If exactly one existing Supabase profile begins with `Kiran`, the migration claims the preloaded group for that user automatically. Otherwise, Kiran opens **Groups** in the PWA and taps **Load the preconfigured group**.

Once claimed, pending invitations are generated for Santhosh, Mohan, and Pavan. Their invitation acceptance binds their Supabase user IDs to the preloaded roster and all of their scheduled trips.

## Verification queries

```sql
select g.code, g.name, g.current_schedule_version, g.schedule_policy
from public.kcp_groups g
where g.code = 'KCP-BASIS-2026-27';

select parent_name, child_name, grade, pickup_tag,
       fixed_weekday, friday_rotation_order, claimed_user_id
from public.kcp_roster_slots
where group_id = (
  select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'
)
order by fixed_weekday;

select count(distinct trip_date) as school_days,
       count(*) as trips
from public.kcp_trips
where group_id = (
  select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'
)
and schedule_version = 1;

select scheduled_driver_name, count(*) as trip_operations
from public.kcp_trips
where group_id = (
  select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'
)
and schedule_version = 1
group by scheduled_driver_name
order by scheduled_driver_name;

select trip_date, scheduled_driver_name
from public.kcp_trips
where group_id = (
  select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'
)
and schedule_version = 1
and kind = 'morning_drop'
and extract(isodow from trip_date) = 5
order by trip_date
limit 8;
```
