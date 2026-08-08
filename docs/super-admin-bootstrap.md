# Super Admin bootstrap and support access

The platform role is independent of group Owner/Admin roles. It is used only in the protected support console.

## Prerequisites

1. Merge and deploy the permanent-email PR.
2. Link and verify the email account that will own platform support access.
3. Confirm the account can sign in on the KCP Pages URL.

## One-time bootstrap

Run in the Supabase SQL Editor as a project operator:

```sql
select public.kcp_bootstrap_platform_admin(
  'YOUR_VERIFIED_EMAIL@example.com',
  'super_admin'
);
```

The helper is not executable by browser roles. It looks up a verified permanent Auth user and creates the platform role.

## Support console

After refreshing KCP, Settings displays **Open support console** only for a platform administrator. The console is served at:

```text
/support/
```

It provides:

- all-group search and operational summaries
- owners, member counts, current schedule version and open covers
- support cases
- client error reference lookup
- audited temporary support access

## Privacy

- Platform access is not a group membership.
- Sensitive child data is not returned by the initial group-overview RPC.
- Temporary sensitive access requires a reason, expires after ten minutes and creates platform audit records.
- A service-role key is never embedded in the PWA or support console.

## Validation

1. Bootstrap the verified account.
2. Refresh KCP and open Settings.
3. Open the support console and confirm groups outside the account's memberships are visible.
4. Open temporary support access with a reason.
5. Verify `kcp_platform_audit_events` contains `break_glass_opened` and `break_glass_closed`.
