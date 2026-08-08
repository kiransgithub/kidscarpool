# Database-driven production UI

The deployed GitHub Pages PWA renders operational data from Supabase. The client contains generic controls, labels, icons, and empty-state text only.

## Supabase-owned data

- group names, types, destinations, terms, timezones and status
- memberships, roles and driving permissions
- participant and child/rider names
- invitation data
- recurring sessions, weekdays and times
- assignment policies and driver order
- published schedule versions and concrete trips
- actual and scheduled drivers
- optional calendar metadata and structured exception events
- cover requests, points and audit history

## Role-aware presentation

| Membership | Production view |
|---|---|
| Owner | Group administration, invitations, schedule configuration, calendar metadata, all normal ride actions when allowed to drive |
| Admin | Same configuration controls as Owner except ownership-only operations |
| Parent/driver | Assigned rides, availability, cover requests, volunteering, points, calendar and group data |
| Viewer | Read-only group, schedule, points and calendar views; no driving, cover or configuration controls |

The server and Row-Level Security remain authoritative. Hiding a control is usability, not authorization.

## Calendar handling

A calendar PDF is optional. The PWA stores the source file and metadata without embedding or inventing school-specific dates. Structured closures, changed times and other exceptions must already exist in Supabase or be added through the schedule-exception workflow.

## Pilot fixtures

Scenario-specific data is allowed only under `supabase/seeds`, tests, archived migrations and documentation. It is not concatenated into the production JavaScript runtime.

`web/build-runtime.mjs` assembles the deployed JavaScript and fails when it detects known pilot identities, destination names, group codes, calendar hashes or retired client-side calendar templates.
