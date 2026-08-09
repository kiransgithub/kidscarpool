# Role-specific dashboards

KCP adapts the same database-backed application to the member's responsibilities.

## Viewer

- next published ride and the ride after it
- assigned driver, date, time and status
- Schedule, Groups and More
- no Requests primary tab
- no pending-change counts
- no invitation counts
- no internal schedule-version number
- no availability or driving controls

## Parent or driver

- next ride involving the family
- next driving assignment
- cover and availability updates involving the current user
- Schedule, Requests, Groups and More

## Owner or Admin

- next ride and next assignment
- open cover count
- unassigned ride count
- pending availability changes
- pending invitation count
- full group-management tools

## Mixed memberships

A person may be a Viewer in one group, Parent in another and Owner in a third. Home uses the highest operational responsibility across the portfolio, while every group card and group-detail panel follows that group's role.

Database RLS and RPC permissions remain authoritative; role-specific rendering only reduces clutter and accidental actions.
