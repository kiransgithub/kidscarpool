# KCP platform support console

The family PWA contains no global platform controls. Verified platform administrators use the separate console:

```text
https://<KCP-PAGES-HOST>/platform-support/
```

## Authorization

A group Owner or Admin is not automatically a platform administrator. Access requires an active `kcp_platform_admins` record and a permanent authenticated account.

The console uses the public Supabase client key. It does not contain the service-role key. Every read or mutation is authorized by a security-definer RPC and written to the platform audit trail.

## Dashboard

- all active and archived groups
- active members and recent clients
- next-24-hour rides
- open covers
- unconfirmed rides
- open support cases
- recent client error references
- latest database migration

## Group view

Default group details are masked:

```text
G•••• O•••r
N•• O••r
```

Support can inspect group state, roles, invitation status, schedule versions, coverage, recent audit and client build information without revealing contact or child data.

## Break-glass access

Sensitive data requires:

1. a specific support reason of at least 10 characters
2. a duration of 1–30 minutes
3. an active platform support session

The console can then show member contact data and child operational data for the selected group. Opening, viewing and closing the session are separate platform audit events. The session expires automatically and is closed when the group drawer closes or the administrator signs out.

## Repair operations

- reissue an unaccepted invitation
- transfer ownership to an existing active member
- archive or reactivate a group
- update support case status
- inspect a user-visible KCP error reference

Every repair requires an explicit reason where appropriate and is audited. The console does not silently impersonate a family account.

## Client heartbeats

The family PWA records only:

- authenticated user ID
- random client-instance ID
- build version
- platform/browser label
- active group ID
- last-seen time

It does not record child data, addresses, prompts or trip notes.

## Bootstrap

Use the verified permanent Super Admin email:

```sql
select public.kcp_bootstrap_platform_admin(
  'YOUR_VERIFIED_EMAIL@example.com',
  'super_admin'
);
```

The account must already exist in Supabase Auth and `kcp_profiles`.
