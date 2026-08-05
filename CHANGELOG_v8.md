# KCP Pilot v8 — Multi-Group Navigation and Invitation Repair

## Problems fixed

### Invitation creation HTTP 500

The v7 invitation path created an `invited` membership with `joined_at = NULL`, while older pilot databases still enforced `memberships.joined_at NOT NULL`. PostgreSQL therefore rejected every new invitation and FastAPI surfaced a generic HTTP 500.

v8 applies an additive startup migration:

```sql
ALTER TABLE memberships ALTER COLUMN joined_at DROP NOT NULL;
```

Existing rows and the Docker volume are retained.

The server and iOS app also reject an attempt to invite a different parent using the signed-in parent's phone number. The user now receives a useful conflict message instead of a database error. An invitation may use the invited parent's real phone number or leave it blank for a share-code-only pilot invitation.

### Newly created group replaced the remembered group

v7 remembered one active group code locally and did not expose an identity-scoped group list. Creating another group made it difficult to return to the original group even though PostgreSQL retained it.

v8 adds:

- `GET /v1/groups`, scoped to the signed-in parent and phone
- a prominent **Groups** tab
- all joined/owned groups with role, child, member count and pending work
- switching between groups without deleting the prior group's data
- separate remote snapshots for trip execution state per group
- active-group context on the Home screen
- Create Group and Join by Invitation actions directly from Groups

## Pilot flow

1. Owner creates or selects a group from **Groups**.
2. Owner/Admin creates an invitation using the invited parent's phone, or leaves phone blank.
3. Owner shares the generated eight-character invitation code.
4. The invited parent installs the same build, chooses **I have an invitation**, enters the exact invited name, code, server URL and pilot OTP `123456`.
5. The accepted group appears in the invited parent's Groups tab.
6. Parent submits availability; an Owner/Admin reviews it.
7. Every group keeps independent members, constraints, calendar, schedule versions, trips and audit records.
