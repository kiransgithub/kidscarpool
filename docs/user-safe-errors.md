# User-safe status and error handling

The family app displays only:

```text
Online
Online · synced just now
Syncing…
Offline — changes will sync when connection returns
Unable to sync. Try again.
```

It never displays database vendors, table names, constraints, RPC names, SQLSTATE values or authentication internals.

## Expected errors

Validation, permission, expired invitation, recovery-code, closed-cover and trip-start-window errors are mapped to concise actionable text.

## Unexpected errors

Unexpected failures are written through `kcp_report_client_error` and receive a reference such as:

```text
KCP-7F31A9C2
```

The member sees:

```text
We could not complete the request. Your data was not changed.
Try again or contact the group owner. Reference: KCP-7F31A9C2
```

A platform administrator can search that reference in the support console and inspect sanitized technical context.

## Data minimization

Error metadata includes only the active view, group ID, membership role, online state and client version. Prompt text, child details, addresses, pickup tags and emergency data are never included automatically.
