# KCP Pilot Server v8

The server provides normalized PostgreSQL persistence for carpool groups, invitations, memberships, parent constraints, calendars, schedule versions and append-only audit events. It retains a group-specific snapshot for trip execution state.

## Start or upgrade

```bash
cd backend
docker compose down
find . -name '._*' -delete
dot_clean . 2>/dev/null || true
docker compose up --build -d
curl http://localhost:8090/health
```

Expected:

```json
{"status":"ok","service":"kcp-pilot","version":"0.8.0"}
```

Use another host port with:

```bash
KCP_PORT=8091 docker compose up --build -d
```

Do not run `docker compose down -v` during an upgrade because it removes the named PostgreSQL volume.

## v8 database migration

Older pilot schemas required `memberships.joined_at` for every row, but a pending invited membership has not joined yet. v8 automatically executes:

```sql
ALTER TABLE memberships ALTER COLUMN joined_at DROP NOT NULL;
```

That repairs the invitation HTTP 500 without deleting existing data.

## Multi-group endpoint

`GET /v1/groups` returns every active group associated with the identity headers:

- nested group details
- member role, child and grade
- active-member count
- pending invitation count
- pending constraint-request count
- calendar-registration state
- last activity time

This drives the iOS Groups tab and group switching.

## Invitation controls

- invitation creator must be Owner/Admin
- active-member and pending-invitation duplicates are rejected
- reusing another member's phone returns HTTP 409 with a useful explanation
- phone may be omitted for a share-code-only pilot invitation
- acceptance validates token, expiration, parent name and phone when one was supplied

## Smoke test

```bash
KCP_BASE_URL=http://127.0.0.1:8090 python3 tests/workflow_smoke_test.py
```

## Operational checks

```bash
docker compose ps
docker compose logs --tail=150 api
docker compose exec db psql -U kcp -d kcp -c "select code,name,current_schedule_version from carpool_groups order by updated_at desc;"
docker compose exec db psql -U kcp -d kcp -c "select group_code,parent_name,phone,role,status,joined_at from memberships order by group_code,parent_name;"
docker compose exec db psql -U kcp -d kcp -c "select group_code,invited_parent_name,status,created_at from invitations order by created_at desc limit 20;"
```

## Backup and audit export

```bash
./backup-kcp-db.sh
./export-audit.sh KCP-PHOENIX-2026
```
