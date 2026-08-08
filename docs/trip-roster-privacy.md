# Trip-scoped operational roster privacy

Child master rows and safety profiles are not general group-directory data.

## Direct access

- Owner/Admin: child master rows for their group
- Parent: only children attached to their stable participant
- Viewer: no child master rows
- Assigned driver: no broad table access

## Operational roster RPC

`kcp_get_trip_operational_roster(trip_id)` returns safety details according to scope:

| Scope | Data returned |
|---|---|
| Owner/Admin | All children on the selected ride |
| Assigned driver | All children, beginning 60 minutes before the ride and ending after the operational window |
| Parent outside the driver window | Only their own child |
| Viewer | No access |

The roster may include pickup/drop-off address, pickup tag, authorized people, emergency contact, seat requirement, critical alert and pickup instructions.

## Audit

Every successful sensitive roster request creates `kcp_sensitive_access_events` with the group, trip, user, scope, reason and timestamp.

## Viewer masking

Viewer agenda and group trip responses contain no child list and no free-form operational notes. The browser loads trips through `kcp_group_trips` rather than directly selecting sensitive columns from `kcp_trips`.
