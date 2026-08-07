# Pilot account persistence and recovery

KCP now uses two layers of local persistence:

1. Supabase Auth session data is stored in IndexedDB, with local storage as a fallback.
2. Every joined group receives a separate, revocable remembered-device credential. Only its SHA-256 hash is stored in PostgreSQL.

Normal app restarts should not ask a parent or viewer to register again. Clearing all website data, deleting the PWA, or switching to another browser/device removes the local credentials.

## Parent or viewer recovery

A parent or viewer can enter the **same original invitation code**, exact invited name and matching phone number. An accepted invitation is treated as a recovery credential:

- the group membership moves to the current Supabase Auth identity;
- the previous identity is marked `removed` for that group;
- active/future driver assignments, coverage records and points move to the replacement identity;
- a new remembered-device credential is created locally;
- an immutable audit event records the transfer.

The invitation code must be treated as private.

## Recover the preloaded Kiran owner entry

The seeded owner did not join through an invitation. When the app reports that the Kiran roster entry belongs to another device, issue a one-time code from **Supabase → SQL Editor**:

```sql
select *
from public.kcp_issue_roster_recovery_code(
  'KCP-BASIS-2026-27',
  'Kiran',
  30
);
```

The result contains a code resembling:

```text
REC-12AB34CD-56EF78A9
```

In KCP:

1. Open **Groups**.
2. Select **Recover group access**.
3. Enter the one-time code.
4. Tap **Recover and remember this device**.

The code expires after the number of minutes supplied to the SQL function and can be used only once. The recovery moves ownership, the Kiran roster claim, operational driver references, cover records and points to the current Supabase identity. The earlier membership becomes `removed`; historical audit actors remain unchanged.

## Inspect active and removed identities

```sql
select
  g.code,
  m.parent_name,
  m.child_name,
  m.role,
  m.status,
  m.user_id,
  m.joined_at,
  m.updated_at
from public.kcp_memberships m
join public.kcp_groups g on g.id = m.group_id
where g.code = 'KCP-BASIS-2026-27'
order by m.parent_name, m.updated_at desc;
```

## Revoke remembered devices

The app does not expose raw database hashes. A project operator can revoke all remembered devices for one group/user from SQL Editor:

```sql
update public.kcp_device_links
set revoked_at = now()
where group_id = (
  select id from public.kcp_groups where code = 'KCP-BASIS-2026-27'
)
and user_id = 'USER-UUID-HERE'::uuid
and revoked_at is null;
```

Revocation does not immediately terminate a currently valid Supabase Auth session. It prevents the remembered-device credential from restoring access after that session is lost.
