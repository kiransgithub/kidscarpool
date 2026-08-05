from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import secrets
import string
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

import psycopg
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from psycopg.rows import dict_row

DATABASE_URL = os.environ["DATABASE_URL"]
PILOT_GROUP_CODE = os.getenv("PILOT_GROUP_CODE", "KCP-PHOENIX-2026")
PILOT_OTP = os.getenv("PILOT_OTP", "123456")
BASIS_CALENDAR_SHA256 = os.getenv(
    "BASIS_CALENDAR_SHA256",
    "3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464",
).lower()
BASIS_CALENDAR_PDF = Path(__file__).with_name("resources") / "BASIS_Phoenix_Primary_Academic_Calendar_2026-27.pdf"

app = FastAPI(title="Kidscarpool Pilot API", version="0.8.0")


@contextmanager
def db():
    with psycopg.connect(DATABASE_URL, row_factory=dict_row) as conn:
        yield conn


# ---------------------------------------------------------------------------
# Authoritative BASIS Phoenix Primary calendar seed for the four-family pilot.
# Newly created groups remain calendar-empty until an admin uploads one.
# ---------------------------------------------------------------------------

SEED_CALENDAR_EVENTS: list[dict[str, Any]] = [
    {"id": "10000000-0000-4000-8000-000000000001", "type": "first_day", "title": "First Day of School", "start": "2026-08-05", "end": "2026-08-05", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000002", "type": "no_school", "title": "Labor Day Break", "start": "2026-09-07", "end": "2026-09-07", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000003", "type": "early_release", "title": "Professional Development", "start": "2026-09-25", "end": "2026-09-25", "notes": "Confirm the exact dismissal time before assigning pickup."},
    {"id": "10000000-0000-4000-8000-000000000004", "type": "early_release", "title": "Parent/Teacher Conferences", "start": "2026-10-07", "end": "2026-10-07", "notes": "Confirm the exact dismissal time before assigning pickup."},
    {"id": "10000000-0000-4000-8000-000000000005", "type": "no_school", "title": "Fall Break", "start": "2026-10-12", "end": "2026-10-16", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000006", "type": "no_school", "title": "Veterans Day", "start": "2026-11-11", "end": "2026-11-11", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000007", "type": "no_school", "title": "Thanksgiving Break", "start": "2026-11-25", "end": "2026-11-30", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000008", "type": "no_late_bird", "title": "Winter Break Early Release", "start": "2026-12-18", "end": "2026-12-18", "notes": "Early release and no Late Bird. Confirm alternate coverage for the first-grade child."},
    {"id": "10000000-0000-4000-8000-000000000009", "type": "no_school", "title": "Winter Break", "start": "2026-12-21", "end": "2027-01-01", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000010", "type": "no_school", "title": "MLK Day", "start": "2027-01-18", "end": "2027-01-18", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000011", "type": "early_release", "title": "Professional Development", "start": "2027-02-12", "end": "2027-02-12", "notes": "Confirm the exact dismissal time before assigning pickup."},
    {"id": "10000000-0000-4000-8000-000000000012", "type": "no_school", "title": "Presidents Day", "start": "2027-02-15", "end": "2027-02-15", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000013", "type": "no_school", "title": "February Break", "start": "2027-02-22", "end": "2027-02-24", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000014", "type": "early_release", "title": "Parent/Teacher Conferences", "start": "2027-03-10", "end": "2027-03-10", "notes": "Confirm the exact dismissal time before assigning pickup."},
    {"id": "10000000-0000-4000-8000-000000000015", "type": "no_school", "title": "Spring Break", "start": "2027-03-15", "end": "2027-03-19", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000016", "type": "early_release", "title": "Professional Development", "start": "2027-04-01", "end": "2027-04-01", "notes": "Confirm the exact dismissal time before assigning pickup."},
    {"id": "10000000-0000-4000-8000-000000000017", "type": "no_school", "title": "April Break", "start": "2027-04-02", "end": "2027-04-05", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000018", "type": "project_week", "title": "Project Week", "start": "2027-05-24", "end": "2027-05-28", "notes": ""},
    {"id": "10000000-0000-4000-8000-000000000019", "type": "last_day", "title": "Last Day of School", "start": "2027-05-28", "end": "2027-05-28", "notes": "Early release and no Late Bird. Confirm the exact dismissal time."},
]


# ---------------------------------------------------------------------------
# Schema and migrations. These ALTER statements intentionally upgrade the
# existing v3 pilot volume without deleting any snapshot or calendar records.
# ---------------------------------------------------------------------------


def init_db() -> None:
    with db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS carpool_groups (
                code text PRIMARY KEY,
                school_key text NOT NULL,
                academic_year text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now()
            );
            ALTER TABLE carpool_groups ADD COLUMN IF NOT EXISTS name text;
            ALTER TABLE carpool_groups ADD COLUMN IF NOT EXISTS school_name text;
            ALTER TABLE carpool_groups ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';
            ALTER TABLE carpool_groups ADD COLUMN IF NOT EXISTS created_by text;
            ALTER TABLE carpool_groups ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
            ALTER TABLE carpool_groups ADD COLUMN IF NOT EXISTS current_schedule_version integer NOT NULL DEFAULT 1;

            CREATE TABLE IF NOT EXISTS memberships (
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                parent_name text NOT NULL,
                phone text,
                joined_at timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (group_code, parent_name),
                UNIQUE (group_code, phone)
            );
            ALTER TABLE memberships ADD COLUMN IF NOT EXISTS child_name text NOT NULL DEFAULT '';
            ALTER TABLE memberships ADD COLUMN IF NOT EXISTS grade integer NOT NULL DEFAULT 1;
            ALTER TABLE memberships ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'parent';
            ALTER TABLE memberships ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';
            ALTER TABLE memberships ADD COLUMN IF NOT EXISTS invited_by text;
            ALTER TABLE memberships ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
            -- Invited parents have not joined yet. v7 inserted NULL here while the
            -- original pilot schema still required a value, causing every invite
            -- to fail with HTTP 500. This additive migration preserves all rows.
            ALTER TABLE memberships ALTER COLUMN joined_at DROP NOT NULL;

            CREATE TABLE IF NOT EXISTS group_snapshots (
                group_code text PRIMARY KEY REFERENCES carpool_groups(code) ON DELETE CASCADE,
                payload jsonb NOT NULL,
                updated_by text NOT NULL,
                updated_at timestamptz NOT NULL DEFAULT now()
            );

            CREATE TABLE IF NOT EXISTS invitations (
                id uuid PRIMARY KEY,
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                token text NOT NULL UNIQUE,
                invited_parent_name text NOT NULL,
                phone text,
                child_name text NOT NULL,
                grade integer NOT NULL,
                role text NOT NULL DEFAULT 'parent',
                status text NOT NULL DEFAULT 'pending',
                invited_by text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now(),
                expires_at timestamptz NOT NULL,
                accepted_at timestamptz,
                accepted_by text
            );
            CREATE INDEX IF NOT EXISTS invitations_group_status_idx ON invitations(group_code, status);

            CREATE TABLE IF NOT EXISTS parent_constraints (
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                parent_name text NOT NULL,
                drop_weekdays jsonb NOT NULL DEFAULT '[]',
                pickup_weekdays jsonb NOT NULL DEFAULT '[]',
                notes text NOT NULL DEFAULT '',
                updated_at timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (group_code, parent_name)
            );
            ALTER TABLE parent_constraints ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;
            ALTER TABLE parent_constraints ADD COLUMN IF NOT EXISTS effective_from date;
            ALTER TABLE parent_constraints ADD COLUMN IF NOT EXISTS updated_by text NOT NULL DEFAULT 'system';

            CREATE TABLE IF NOT EXISTS constraint_requests (
                id uuid PRIMARY KEY,
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                parent_name text NOT NULL,
                previous_drop_weekdays jsonb NOT NULL DEFAULT '[]',
                previous_pickup_weekdays jsonb NOT NULL DEFAULT '[]',
                requested_drop_weekdays jsonb NOT NULL DEFAULT '[]',
                requested_pickup_weekdays jsonb NOT NULL DEFAULT '[]',
                notes text NOT NULL DEFAULT '',
                status text NOT NULL DEFAULT 'pending',
                submitted_at timestamptz NOT NULL DEFAULT now(),
                reviewed_at timestamptz,
                reviewed_by text,
                rejection_reason text,
                existing_assignments_affected integer NOT NULL DEFAULT 0,
                base_version integer NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS constraint_requests_group_status_idx ON constraint_requests(group_code, status);

            CREATE TABLE IF NOT EXISTS school_calendars (
                id bigserial PRIMARY KEY,
                school_key text NOT NULL,
                academic_year text NOT NULL,
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                uploaded_by text NOT NULL,
                source_name text NOT NULL,
                uploaded_at timestamptz NOT NULL DEFAULT now(),
                UNIQUE (school_key, academic_year, group_code)
            );
            ALTER TABLE school_calendars ADD COLUMN IF NOT EXISTS school_name text;
            ALTER TABLE school_calendars ADD COLUMN IF NOT EXISTS event_count integer NOT NULL DEFAULT 0;
            ALTER TABLE school_calendars ADD COLUMN IF NOT EXISTS source_sha256 text;
            ALTER TABLE school_calendars ADD COLUMN IF NOT EXISTS source_file_size bigint;
            ALTER TABLE school_calendars ADD COLUMN IF NOT EXISTS source_blob bytea;

            CREATE TABLE IF NOT EXISTS calendar_events (
                id uuid PRIMARY KEY,
                calendar_id bigint NOT NULL REFERENCES school_calendars(id) ON DELETE CASCADE,
                event_type text NOT NULL,
                title text NOT NULL,
                start_date date NOT NULL,
                end_date date NOT NULL,
                notes text NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS calendar_events_calendar_date_idx ON calendar_events(calendar_id, start_date);

            CREATE TABLE IF NOT EXISTS schedule_versions (
                id uuid PRIMARY KEY,
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                version integer NOT NULL,
                status text NOT NULL DEFAULT 'published',
                reason text NOT NULL,
                generated_by text NOT NULL,
                generated_at timestamptz NOT NULL DEFAULT now(),
                published_by text,
                published_at timestamptz,
                change_summary jsonb NOT NULL DEFAULT '{}',
                UNIQUE (group_code, version)
            );

            CREATE TABLE IF NOT EXISTS audit_events (
                id bigserial PRIMARY KEY,
                group_code text NOT NULL REFERENCES carpool_groups(code) ON DELETE CASCADE,
                actor_name text NOT NULL,
                actor_phone text,
                action text NOT NULL,
                entity_type text NOT NULL,
                entity_id text NOT NULL,
                details jsonb NOT NULL DEFAULT '{}',
                occurred_at timestamptz NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS audit_events_group_time_idx ON audit_events(group_code, occurred_at DESC);

            CREATE OR REPLACE FUNCTION kcp_prevent_audit_mutation()
            RETURNS trigger AS $$
            BEGIN
                RAISE EXCEPTION 'KCP audit events are append-only';
            END;
            $$ LANGUAGE plpgsql;

            DROP TRIGGER IF EXISTS kcp_audit_events_immutable ON audit_events;
            CREATE TRIGGER kcp_audit_events_immutable
                BEFORE UPDATE OR DELETE ON audit_events
                FOR EACH ROW EXECUTE FUNCTION kcp_prevent_audit_mutation();

            CREATE TABLE IF NOT EXISTS notification_outbox (
                id bigserial PRIMARY KEY,
                group_code text NOT NULL,
                event_type text NOT NULL,
                payload jsonb NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now(),
                delivered_at timestamptz
            );
            """
        )

        conn.execute(
            """
            INSERT INTO carpool_groups(
                code, school_key, academic_year, name, school_name, status,
                created_by, current_schedule_version
            ) VALUES (
                %s, 'basis-phoenix-primary', '2026-27',
                'BASIS Phoenix Primary Carpool', 'BASIS Phoenix Primary',
                'active', 'Kiran', 1
            )
            ON CONFLICT (code) DO UPDATE SET
                name = COALESCE(carpool_groups.name, EXCLUDED.name),
                school_name = COALESCE(carpool_groups.school_name, EXCLUDED.school_name),
                created_by = COALESCE(carpool_groups.created_by, EXCLUDED.created_by)
            """,
            (PILOT_GROUP_CODE,),
        )

        seed_members = [
            ("Kiran", "Thanishka", 4, "owner", [], [2, 3, 4, 5, 6], [2, 3, 4, 5, 6], ""),
            ("Mohan", "Saanvi", 5, "parent", [], [2, 3, 4, 5, 6], [2, 3, 4, 5, 6], ""),
            ("Pavan", "Ishi", 1, "parent", [], [2, 3, 4, 5, 6], [2, 3, 4, 5, 6], "Thursday preferred"),
            ("Santosh", "Kavish", 5, "parent", [], [], [3, 5], "Pickup only; Tuesday or Thursday"),
        ]
        for parent_name, child_name, grade, role, _, drops, pickups, notes in seed_members:
            conn.execute(
                """
                INSERT INTO memberships(
                    group_code, parent_name, child_name, grade, role, status,
                    invited_by, joined_at, updated_at
                ) VALUES (%s,%s,%s,%s,%s,'active',%s,now(),now())
                ON CONFLICT(group_code,parent_name) DO UPDATE SET
                    child_name = CASE WHEN memberships.child_name = '' THEN EXCLUDED.child_name ELSE memberships.child_name END,
                    grade = CASE WHEN memberships.grade = 1 AND EXCLUDED.grade <> 1 THEN EXCLUDED.grade ELSE memberships.grade END,
                    role = CASE WHEN memberships.parent_name = 'Kiran' THEN 'owner' ELSE memberships.role END,
                    status = CASE WHEN memberships.status = 'invited' THEN memberships.status ELSE 'active' END,
                    updated_at = now()
                """,
                (PILOT_GROUP_CODE, parent_name, child_name, grade, role, None if role == "owner" else "Kiran"),
            )
            conn.execute(
                """
                INSERT INTO parent_constraints(
                    group_code,parent_name,drop_weekdays,pickup_weekdays,notes,
                    version,effective_from,updated_by
                ) VALUES(%s,%s,%s::jsonb,%s::jsonb,%s,1,'2026-08-05','Kiran')
                ON CONFLICT(group_code,parent_name) DO NOTHING
                """,
                (PILOT_GROUP_CODE, parent_name, json.dumps(drops), json.dumps(pickups), notes),
            )

        seed_calendar(conn)

        conn.execute(
            """
            INSERT INTO schedule_versions(
                id,group_code,version,status,reason,generated_by,generated_at,
                published_by,published_at,change_summary
            ) VALUES(
                '20000000-0000-4000-8000-000000000001', %s, 1, 'published',
                'Initial schedule generated from confirmed parent availability',
                'Kiran', now(), 'Kiran', now(),
                '{"members":"4","schoolDays":"180"}'::jsonb
            ) ON CONFLICT(group_code,version) DO NOTHING
            """,
            (PILOT_GROUP_CODE,),
        )

        existing_audit = conn.execute(
            "SELECT 1 FROM audit_events WHERE group_code=%s LIMIT 1", (PILOT_GROUP_CODE,)
        ).fetchone()
        if not existing_audit:
            record_audit(
                conn,
                PILOT_GROUP_CODE,
                "Kiran",
                None,
                "group_created",
                "group",
                PILOT_GROUP_CODE,
                {"name": "BASIS Phoenix Primary Carpool"},
            )
            record_audit(
                conn,
                PILOT_GROUP_CODE,
                "Kiran",
                None,
                "calendar_registered",
                "calendar",
                "basis-phoenix-primary-2026-27",
                {"source": "BASIS Phoenix Primary Academic Calendar 2026–27"},
            )
            record_audit(
                conn,
                PILOT_GROUP_CODE,
                "Kiran",
                None,
                "schedule_published",
                "schedule",
                "1",
                {"version": "1"},
            )
        conn.commit()


def seed_calendar(conn: psycopg.Connection) -> None:
    existing = conn.execute(
        """
        SELECT id FROM school_calendars
        WHERE group_code=%s AND school_key='basis-phoenix-primary' AND academic_year='2026-27'
        """,
        (PILOT_GROUP_CODE,),
    ).fetchone()
    if existing:
        calendar_id = existing["id"]
    else:
        calendar_id = conn.execute(
            """
            INSERT INTO school_calendars(
                school_key,school_name,academic_year,group_code,uploaded_by,source_name,event_count
            ) VALUES(
                'basis-phoenix-primary','BASIS Phoenix Primary','2026-27',%s,'Kiran',
                'BASIS Phoenix Primary Academic Calendar 2026–27',%s
            ) RETURNING id
            """,
            (PILOT_GROUP_CODE, len(SEED_CALENDAR_EVENTS)),
        ).fetchone()["id"]

    for event in SEED_CALENDAR_EVENTS:
        conn.execute(
            """
            INSERT INTO calendar_events(id,calendar_id,event_type,title,start_date,end_date,notes)
            VALUES(%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT(id) DO NOTHING
            """,
            (
                event["id"], calendar_id, event["type"], event["title"],
                event["start"], event["end"], event["notes"],
            ),
        )
    if BASIS_CALENDAR_PDF.exists():
        source_blob = BASIS_CALENDAR_PDF.read_bytes()
        source_hash = hashlib.sha256(source_blob).hexdigest()
        conn.execute(
            """
            UPDATE school_calendars SET
                event_count=%s,
                source_sha256=COALESCE(source_sha256,%s),
                source_file_size=COALESCE(source_file_size,%s),
                source_blob=COALESCE(source_blob,%s)
            WHERE id=%s
            """,
            (len(SEED_CALENDAR_EVENTS), source_hash, len(source_blob), source_blob, calendar_id),
        )
    else:
        conn.execute(
            "UPDATE school_calendars SET event_count=%s WHERE id=%s",
            (len(SEED_CALENDAR_EVENTS), calendar_id),
        )


@app.on_event("startup")
def startup() -> None:
    init_db()


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------


class JoinRequest(BaseModel):
    group_code: str = PILOT_GROUP_CODE
    parent_name: str
    phone: str
    otp: str


class CreateGroupRequest(BaseModel):
    code: str | None = None
    name: str
    schoolKey: str
    schoolName: str
    academicYear: str
    creatorChildName: str = ""
    creatorGrade: int = Field(default=1, ge=1, le=12)
    initialDropWeekdays: list[int] = Field(default_factory=lambda: [2, 3, 4, 5, 6])
    initialPickupWeekdays: list[int] = Field(default_factory=lambda: [2, 3, 4, 5, 6])
    initialNotes: str = ""


class InvitationRequest(BaseModel):
    invitedParentName: str
    phone: str | None = None
    childName: str
    grade: int = Field(ge=1, le=12)
    role: str = "parent"


class AcceptInvitationRequest(BaseModel):
    phone: str
    parentName: str


class ConstraintRequestPayload(BaseModel):
    requestedDropWeekdays: list[int] = Field(default_factory=list)
    requestedPickupWeekdays: list[int] = Field(default_factory=list)
    notes: str = ""


class ConstraintReviewPayload(BaseModel):
    decision: str
    reviewNote: str = ""


class MemberRolePayload(BaseModel):
    role: str


class CalendarEventPayload(BaseModel):
    id: uuid.UUID
    type: str
    title: str
    startDate: datetime
    endDate: datetime
    notes: str = ""


class CalendarUploadPayload(BaseModel):
    schoolKey: str
    schoolName: str
    academicYear: str
    sourceName: str
    sourceSHA256: str | None = None
    sourceFileSize: int | None = Field(default=None, ge=0, le=10_000_000)
    sourceContentBase64: str | None = None
    events: list[CalendarEventPayload]


class ScheduleVersionPayload(BaseModel):
    reason: str


class AuditPayload(BaseModel):
    action: str
    entityType: str
    entityID: str
    details: dict[str, str] = Field(default_factory=dict)


@dataclass(frozen=True)
class Identity:
    parent_name: str
    phone: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def normalize_phone(value: str | None) -> str:
    return "".join(ch for ch in (value or "") if ch.isdigit())


def identity(parent: str | None, phone: str | None) -> Identity:
    name = (parent or "").strip()
    normalized = normalize_phone(phone)
    if not name:
        raise HTTPException(401, "Missing X-KCP-Parent identity header")
    if len(normalized) < 10:
        raise HTTPException(401, "Missing or invalid X-KCP-Phone identity header")
    return Identity(name, normalized)


def require_group(conn: psycopg.Connection, group_code: str) -> dict[str, Any]:
    row = conn.execute("SELECT * FROM carpool_groups WHERE code=%s", (group_code,)).fetchone()
    if not row:
        raise HTTPException(404, "Unknown carpool group")
    return row


def require_member(conn: psycopg.Connection, group_code: str, actor: Identity) -> dict[str, Any]:
    require_group(conn, group_code)
    row = conn.execute(
        "SELECT * FROM memberships WHERE group_code=%s AND lower(parent_name)=lower(%s)",
        (group_code, actor.parent_name),
    ).fetchone()
    if not row or row["status"] not in {"active", "pending"}:
        raise HTTPException(403, "This parent is not an active member of the group")
    stored_phone = normalize_phone(row.get("phone"))
    if stored_phone and stored_phone != actor.phone:
        raise HTTPException(403, "This parent profile is linked to another phone")
    if not stored_phone:
        conn.execute(
            "UPDATE memberships SET phone=%s,updated_at=now() WHERE group_code=%s AND parent_name=%s",
            (actor.phone, group_code, row["parent_name"]),
        )
        row["phone"] = actor.phone
    return row


def require_admin(conn: psycopg.Connection, group_code: str, actor: Identity) -> dict[str, Any]:
    member = require_member(conn, group_code, actor)
    if member["role"] not in {"owner", "admin"}:
        raise HTTPException(403, "Only an owner or admin can perform this action")
    return member


def record_audit(
    conn: psycopg.Connection,
    group_code: str,
    actor_name: str,
    actor_phone: str | None,
    action: str,
    entity_type: str,
    entity_id: str,
    details: dict[str, Any],
) -> int:
    row = conn.execute(
        """
        INSERT INTO audit_events(
            group_code,actor_name,actor_phone,action,entity_type,entity_id,details
        ) VALUES(%s,%s,%s,%s,%s,%s,%s::jsonb) RETURNING id
        """,
        (group_code, actor_name, actor_phone, action, entity_type, entity_id, json.dumps(details)),
    ).fetchone()
    return int(row["id"])


def generate_group_code(name: str) -> str:
    prefix = "".join(ch for ch in name.upper() if ch.isalnum())[:10] or "KCP"
    suffix = "".join(secrets.choice(string.ascii_uppercase + string.digits) for _ in range(6))
    return f"{prefix}-{suffix}"


def generate_invite_token() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(8))


def validate_weekdays(values: Iterable[int]) -> None:
    if not set(values).issubset({2, 3, 4, 5, 6}):
        raise HTTPException(400, "Weekdays must use Calendar values 2 through 6")


def estimate_assignment_impact(conn: psycopg.Connection, group_code: str, parent_name: str,
                               drops: set[int], pickups: set[int]) -> int:
    row = conn.execute(
        "SELECT payload FROM group_snapshots WHERE group_code=%s", (group_code,)
    ).fetchone()
    if not row:
        return 0
    payload = row["payload"]
    trips = payload.get("trips", []) if isinstance(payload, dict) else []
    today = datetime.now(timezone.utc).date()
    affected = 0
    for trip in trips:
        driver = (
            trip.get("actualDriver") or trip.get("actual_driver") or
            trip.get("scheduledDriver") or trip.get("scheduled_driver")
        )
        if driver != parent_name:
            continue
        try:
            trip_date = datetime.fromisoformat(str(trip.get("date")).replace("Z", "+00:00")).date()
        except (TypeError, ValueError):
            continue
        if trip_date < today:
            continue
        swift_weekday = ((trip_date.weekday() + 1) % 7) + 1  # Monday=2 ... Friday=6
        kind = trip.get("kind") or trip.get("tripKind") or trip.get("trip_kind")
        if kind == "Morning drop" and swift_weekday not in drops:
            affected += 1
        elif kind == "Afternoon pickup" and swift_weekday not in pickups:
            affected += 1
    return affected


def parse_date(value: date | datetime | str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    return date.fromisoformat(value[:10])


def count_weekdays(start: date, end: date) -> int:
    total = 0
    day = start
    while day <= end:
        if day.weekday() < 5:
            total += 1
        day += timedelta(days=1)
    return total


def extended_break_bounds(start: date, end: date) -> tuple[date, date]:
    left = start
    while (left - timedelta(days=1)).weekday() >= 5:
        left -= timedelta(days=1)
    right = end
    while (right + timedelta(days=1)).weekday() >= 5:
        right += timedelta(days=1)
    return left, right


def calendar_analytics(events: list[dict[str, Any]]) -> dict[str, Any]:
    normalized = [
        {
            **event,
            "start": parse_date(event["start_date"]),
            "end": parse_date(event["end_date"]),
        }
        for event in events
    ]
    closures = [event for event in normalized if event["event_type"] == "no_school"]
    first_day = next((event["start"] for event in normalized if event["event_type"] == "first_day"), date(2026, 8, 5))
    last_day = next((event["end"] for event in normalized if event["event_type"] == "last_day"), date(2027, 5, 28))

    closure_dates: set[date] = set()
    for event in closures:
        day = event["start"]
        while day <= event["end"]:
            closure_dates.add(day)
            day += timedelta(days=1)

    instructional_days = 0
    day = first_day
    while day <= last_day:
        if day.weekday() < 5 and day not in closure_dates:
            instructional_days += 1
        day += timedelta(days=1)

    no_school_weekdays = sum(count_weekdays(event["start"], event["end"]) for event in closures)
    long_breaks: list[tuple[dict[str, Any], int, date]] = []
    for event in closures:
        left, right = extended_break_bounds(event["start"], event["end"])
        days = (right - left).days + 1
        if days >= 3:
            long_breaks.append((event, days, right))

    now = datetime.now(timezone.utc).date()
    upcoming = sorted(
        [event for event in normalized if event["end"] >= now],
        key=lambda item: item["start"],
    )
    upcoming_long = [item for item in long_breaks if item[2] >= now]
    longest = max(long_breaks, key=lambda item: item[1], default=None)
    project_week_days = sum(
        count_weekdays(event["start"], event["end"])
        for event in normalized if event["event_type"] == "project_week"
    )

    return {
        "instructionalDays": instructional_days,
        "holidayPeriods": len(closures),
        "noSchoolWeekdays": no_school_weekdays,
        "longWeekends": len(long_breaks),
        "upcomingLongWeekends": len(upcoming_long),
        "earlyPickups": sum(event["event_type"] in {"early_release", "no_late_bird", "last_day"} for event in normalized),
        "noLateBirdDays": sum(event["event_type"] in {"no_late_bird", "last_day"} for event in normalized),
        "projectWeekDays": project_week_days,
        "longestBreakDays": longest[1] if longest else 0,
        "longestBreakTitle": longest[0]["title"] if longest else None,
        "upcomingEventCount": len(upcoming),
        "nextEventTitle": upcoming[0]["title"] if upcoming else None,
        "nextEventDate": upcoming[0]["start"] if upcoming else None,
    }


# ---------------------------------------------------------------------------
# Serialization helpers
# ---------------------------------------------------------------------------


def serialize_group(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "code": row["code"],
        "name": row.get("name") or row["code"],
        "schoolKey": row["school_key"],
        "schoolName": row.get("school_name") or row["school_key"],
        "academicYear": row["academic_year"],
        "status": row.get("status") or "active",
        "createdBy": row.get("created_by") or "Unknown",
        "createdAt": row["created_at"],
        "updatedAt": row.get("updated_at") or row["created_at"],
        "currentScheduleVersion": row.get("current_schedule_version") or 1,
    }


def serialize_group_summary(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "group": serialize_group(row),
        "role": row.get("member_role") or "parent",
        "membershipStatus": row.get("member_status") or "active",
        "childName": row.get("member_child_name") or "",
        "grade": row.get("member_grade") or 1,
        "activeMemberCount": int(row.get("active_member_count") or 0),
        "pendingInvitationCount": int(row.get("pending_invitation_count") or 0),
        "pendingConstraintCount": int(row.get("pending_constraint_count") or 0),
        "calendarRegistered": bool(row.get("calendar_registered")),
        "lastActivityAt": row.get("last_activity_at") or row.get("updated_at") or row["created_at"],
    }


def serialize_member(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "groupCode": row["group_code"],
        "parentName": row["parent_name"],
        "phone": row.get("phone"),
        "childName": row.get("child_name") or "",
        "grade": row.get("grade") or 1,
        "role": row.get("role") or "parent",
        "status": row.get("status") or "active",
        "invitedBy": row.get("invited_by"),
        "joinedAt": row.get("joined_at"),
        "updatedAt": row.get("updated_at") or row.get("joined_at") or datetime.now(timezone.utc),
    }


def serialize_invitation(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "groupCode": row["group_code"],
        "token": row["token"],
        "invitedParentName": row["invited_parent_name"],
        "phone": row.get("phone"),
        "childName": row["child_name"],
        "grade": row["grade"],
        "role": row["role"],
        "status": row["status"],
        "invitedBy": row["invited_by"],
        "createdAt": row["created_at"],
        "expiresAt": row["expires_at"],
        "acceptedAt": row.get("accepted_at"),
        "acceptedBy": row.get("accepted_by"),
    }


def serialize_constraint(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "groupCode": row["group_code"],
        "parentName": row["parent_name"],
        "dropWeekdays": set(row["drop_weekdays"] or []),
        "pickupWeekdays": set(row["pickup_weekdays"] or []),
        "notes": row.get("notes") or "",
        "version": row.get("version") or 1,
        "effectiveFrom": row.get("effective_from"),
        "updatedBy": row.get("updated_by") or "system",
        "updatedAt": row.get("updated_at") or datetime.now(timezone.utc),
    }


def serialize_constraint_request(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "groupCode": row["group_code"],
        "parentName": row["parent_name"],
        "previousDropWeekdays": set(row["previous_drop_weekdays"] or []),
        "previousPickupWeekdays": set(row["previous_pickup_weekdays"] or []),
        "requestedDropWeekdays": set(row["requested_drop_weekdays"] or []),
        "requestedPickupWeekdays": set(row["requested_pickup_weekdays"] or []),
        "notes": row.get("notes") or "",
        "status": row["status"],
        "submittedAt": row["submitted_at"],
        "reviewedAt": row.get("reviewed_at"),
        "reviewedBy": row.get("reviewed_by"),
        "rejectionReason": row.get("rejection_reason"),
        "existingAssignmentsAffected": row.get("existing_assignments_affected") or 0,
        "baseVersion": row.get("base_version") or 1,
    }


def serialize_calendar(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "schoolKey": row["school_key"],
        "academicYear": row["academic_year"],
        "uploadedBy": row["uploaded_by"],
        "uploadedAt": row["uploaded_at"],
        "sourceName": row["source_name"],
        "schoolName": row.get("school_name"),
        "eventCount": row.get("event_count") or 0,
        "sourceSHA256": row.get("source_sha256"),
        "sourceFileSize": row.get("source_file_size"),
    }


def serialize_calendar_event(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "type": row["event_type"],
        "title": row["title"],
        # Date-only values prevent UTC conversion from shifting Phoenix dates to the prior day.
        "startDate": row["start_date"].isoformat(),
        "endDate": row["end_date"].isoformat(),
        "notes": row.get("notes") or "",
    }


def serialize_schedule_version(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "groupCode": row["group_code"],
        "version": row["version"],
        "status": row["status"],
        "reason": row["reason"],
        "generatedBy": row["generated_by"],
        "generatedAt": row["generated_at"],
        "publishedBy": row.get("published_by"),
        "publishedAt": row.get("published_at"),
        "changeSummary": {str(k): str(v) for k, v in (row.get("change_summary") or {}).items()},
    }


def serialize_audit(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "groupCode": row["group_code"],
        "actorName": row["actor_name"],
        "action": row["action"],
        "entityType": row["entity_type"],
        "entityID": row["entity_id"],
        "details": {str(k): str(v) for k, v in (row.get("details") or {}).items()},
        "occurredAt": row["occurred_at"],
    }


def load_workspace(conn: psycopg.Connection, group_code: str) -> dict[str, Any]:
    group = require_group(conn, group_code)
    members = conn.execute(
        "SELECT * FROM memberships WHERE group_code=%s ORDER BY role,parent_name", (group_code,)
    ).fetchall()
    invitations = conn.execute(
        "SELECT * FROM invitations WHERE group_code=%s ORDER BY created_at DESC", (group_code,)
    ).fetchall()
    constraints = conn.execute(
        "SELECT * FROM parent_constraints WHERE group_code=%s ORDER BY parent_name", (group_code,)
    ).fetchall()
    requests = conn.execute(
        "SELECT * FROM constraint_requests WHERE group_code=%s ORDER BY submitted_at DESC", (group_code,)
    ).fetchall()
    calendar_row = conn.execute(
        "SELECT * FROM school_calendars WHERE group_code=%s ORDER BY uploaded_at DESC LIMIT 1", (group_code,)
    ).fetchone()
    event_rows: list[dict[str, Any]] = []
    analytics = None
    if calendar_row:
        event_rows = conn.execute(
            "SELECT * FROM calendar_events WHERE calendar_id=%s ORDER BY start_date,event_type", (calendar_row["id"],)
        ).fetchall()
        analytics = calendar_analytics(event_rows)
    versions = conn.execute(
        "SELECT * FROM schedule_versions WHERE group_code=%s ORDER BY version DESC", (group_code,)
    ).fetchall()
    audits = conn.execute(
        "SELECT * FROM audit_events WHERE group_code=%s ORDER BY occurred_at DESC,id DESC LIMIT 250", (group_code,)
    ).fetchall()

    return {
        "group": serialize_group(group),
        "members": [serialize_member(row) for row in members],
        "invitations": [serialize_invitation(row) for row in invitations],
        "constraints": [serialize_constraint(row) for row in constraints],
        "constraintRequests": [serialize_constraint_request(row) for row in requests],
        "calendar": serialize_calendar(calendar_row) if calendar_row else None,
        "calendarEvents": [serialize_calendar_event(row) for row in event_rows],
        "calendarAnalytics": analytics,
        "scheduleVersions": [serialize_schedule_version(row) for row in versions],
        "auditEvents": [serialize_audit(row) for row in audits],
    }


# ---------------------------------------------------------------------------
# Health, legacy pilot join and snapshot synchronization
# ---------------------------------------------------------------------------


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "kcp-pilot", "version": "0.8.0"}


@app.post("/v1/onboarding/join")
def join(req: JoinRequest) -> dict[str, Any]:
    if req.otp != PILOT_OTP:
        raise HTTPException(401, "Invalid pilot OTP")
    with db() as conn:
        require_group(conn, req.group_code)
        existing = conn.execute(
            "SELECT phone FROM memberships WHERE group_code=%s AND lower(parent_name)=lower(%s)",
            (req.group_code, req.parent_name),
        ).fetchone()
        if existing and existing["phone"] and normalize_phone(existing["phone"]) != normalize_phone(req.phone):
            raise HTTPException(409, "This parent profile is already linked to another phone")
        conn.execute(
            """
            INSERT INTO memberships(group_code,parent_name,phone,child_name,grade,role,status)
            VALUES(%s,%s,%s,'',1,'parent','active')
            ON CONFLICT(group_code,parent_name) DO UPDATE SET phone=excluded.phone,status='active',updated_at=now()
            """,
            (req.group_code, req.parent_name, normalize_phone(req.phone)),
        )
        conn.commit()
    return {"group_code": req.group_code, "parent_name": req.parent_name, "role": "parent"}


@app.get("/v1/groups/{group_code}/snapshot")
def get_snapshot(
    group_code: str,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> Any:
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        require_member(conn, group_code, actor)
        row = conn.execute("SELECT payload FROM group_snapshots WHERE group_code=%s", (group_code,)).fetchone()
        conn.commit()
        if not row:
            raise HTTPException(404, "No shared snapshot has been uploaded yet")
        return row["payload"]


@app.put("/v1/groups/{group_code}/snapshot")
def put_snapshot(
    group_code: str,
    payload: dict[str, Any],
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        require_member(conn, group_code, actor)
        conn.execute(
            """
            INSERT INTO group_snapshots(group_code,payload,updated_by,updated_at)
            VALUES(%s,%s::jsonb,%s,now())
            ON CONFLICT(group_code) DO UPDATE SET
                payload=excluded.payload,updated_by=excluded.updated_by,updated_at=now()
            """,
            (group_code, json.dumps(payload), actor.parent_name),
        )
        conn.commit()
    return {"status": "saved", "updated_by": actor.parent_name}


# ---------------------------------------------------------------------------
# Group creation, invitations and multi-admin roles
# ---------------------------------------------------------------------------


@app.get("/v1/groups")
def list_groups(
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    """List every active group available to the signed-in parent.

    This endpoint is intentionally identity-scoped. It enables the iOS Groups
    tab to switch workspaces without losing the previous group's PostgreSQL
    records or relying on one locally remembered group code.
    """
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT
                g.*,
                m.role AS member_role,
                m.status AS member_status,
                m.child_name AS member_child_name,
                m.grade AS member_grade,
                (SELECT count(*) FROM memberships am
                    WHERE am.group_code=g.code AND am.status='active') AS active_member_count,
                (SELECT count(*) FROM invitations i
                    WHERE i.group_code=g.code AND i.status='pending') AS pending_invitation_count,
                (SELECT count(*) FROM constraint_requests cr
                    WHERE cr.group_code=g.code AND cr.status='pending') AS pending_constraint_count,
                EXISTS(SELECT 1 FROM school_calendars sc
                    WHERE sc.group_code=g.code) AS calendar_registered,
                GREATEST(
                    g.updated_at,
                    COALESCE((SELECT max(ae.occurred_at) FROM audit_events ae
                              WHERE ae.group_code=g.code), g.updated_at)
                ) AS last_activity_at
            FROM memberships m
            JOIN carpool_groups g ON g.code=m.group_code
            WHERE lower(m.parent_name)=lower(%s)
              AND m.status='active'
              AND g.status='active'
              AND (m.phone=%s OR m.phone IS NULL)
            ORDER BY last_activity_at DESC, g.name, g.code
            """,
            (actor.parent_name, actor.phone),
        ).fetchall()
        return {"groups": [serialize_group_summary(row) for row in rows]}


@app.post("/v1/groups")
def create_group(
    req: CreateGroupRequest,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    name = req.name.strip()
    school_key = req.schoolKey.strip()
    school_name = req.schoolName.strip()
    academic_year = req.academicYear.strip()
    creator_child = req.creatorChildName.strip()
    if not name or not school_key or not school_name or not academic_year:
        raise HTTPException(400, "Group name, school and academic year are required")
    if not creator_child:
        raise HTTPException(400, "The creator's child name is required")
    group_code = (req.code or generate_group_code(name)).upper()
    validate_weekdays(req.initialDropWeekdays)
    validate_weekdays(req.initialPickupWeekdays)

    with db() as conn:
        created = conn.execute(
            """
            INSERT INTO carpool_groups(
                code,school_key,school_name,academic_year,name,status,created_by,current_schedule_version
            ) VALUES(%s,%s,%s,%s,%s,'active',%s,1)
            ON CONFLICT(code) DO NOTHING
            RETURNING code
            """,
            (group_code, school_key, school_name, academic_year, name, actor.parent_name),
        ).fetchone()
        if created is None:
            raise HTTPException(409, "A group with this code already exists")
        conn.execute(
            """
            INSERT INTO memberships(
                group_code,parent_name,phone,child_name,grade,role,status,joined_at,updated_at
            ) VALUES(%s,%s,%s,%s,%s,'owner','active',now(),now())
            """,
            (group_code, actor.parent_name, actor.phone, creator_child, req.creatorGrade),
        )
        conn.execute(
            """
            INSERT INTO parent_constraints(
                group_code,parent_name,drop_weekdays,pickup_weekdays,notes,
                version,effective_from,updated_by,updated_at
            ) VALUES(%s,%s,%s::jsonb,%s::jsonb,%s,1,NULL,%s,now())
            """,
            (
                group_code, actor.parent_name,
                json.dumps(sorted(req.initialDropWeekdays)),
                json.dumps(sorted(req.initialPickupWeekdays)),
                req.initialNotes, actor.parent_name,
            ),
        )
        conn.execute(
            """
            INSERT INTO schedule_versions(
                id,group_code,version,status,reason,generated_by,published_by,published_at,change_summary
            ) VALUES(%s,%s,1,'published','Group created; schedule pending member constraints',%s,%s,now(),'{}'::jsonb)
            """,
            (str(uuid.uuid4()), group_code, actor.parent_name, actor.parent_name),
        )
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            "group_created", "group", group_code,
            {
                "name": name,
                "school": school_name,
                "academicYear": academic_year,
                "creatorChild": creator_child,
                "initialDropWeekdays": req.initialDropWeekdays,
                "initialPickupWeekdays": req.initialPickupWeekdays,
            },
        )
        conn.commit()
        return load_workspace(conn, group_code)


@app.get("/v1/groups/{group_code}/workspace")
def get_workspace(
    group_code: str,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        require_member(conn, group_code, actor)
        conn.commit()
        return load_workspace(conn, group_code)


@app.post("/v1/groups/{group_code}/invitations")
def create_invitation(
    group_code: str,
    req: InvitationRequest,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    invited_name = req.invitedParentName.strip()
    child_name = req.childName.strip()
    invited_phone = normalize_phone(req.phone)
    if req.role not in {"admin", "parent", "viewer"}:
        raise HTTPException(400, "Invitation role must be admin, parent or viewer")
    if not invited_name or not child_name:
        raise HTTPException(400, "Parent name and child name are required")
    if req.phone and len(invited_phone) < 10:
        raise HTTPException(400, "Invitation phone number is invalid")
    with db() as conn:
        require_admin(conn, group_code, actor)
        conn.execute(
            "SELECT pg_advisory_xact_lock(hashtext(%s))",
            (f"invite:{group_code}:{invited_name.casefold()}:{invited_phone}",),
        )
        active_member = conn.execute(
            """
            SELECT 1 FROM memberships
            WHERE group_code=%s AND lower(parent_name)=lower(%s) AND status='active'
            """,
            (group_code, invited_name),
        ).fetchone()
        if active_member:
            raise HTTPException(409, "This parent is already an active member of the group")
        if invited_phone:
            phone_owner = conn.execute(
                """
                SELECT parent_name FROM memberships
                WHERE group_code=%s AND phone=%s AND lower(parent_name)<>lower(%s)
                """,
                (group_code, invited_phone, invited_name),
            ).fetchone()
            if phone_owner:
                raise HTTPException(
                    409,
                    f"This phone is already linked to {phone_owner['parent_name']} in this group. "
                    "Use the invited parent's phone number or leave it blank for a share-code-only invite.",
                )
        duplicate = conn.execute(
            """
            SELECT 1 FROM invitations
            WHERE group_code=%s AND status='pending'
              AND (lower(invited_parent_name)=lower(%s) OR (phone IS NOT NULL AND phone=%s))
            """,
            (group_code, invited_name, invited_phone),
        ).fetchone()
        if duplicate:
            raise HTTPException(409, "A pending invitation already exists for this parent")

        invitation_id = uuid.uuid4()
        token = generate_invite_token()
        expires_at = datetime.now(timezone.utc) + timedelta(days=14)
        row = conn.execute(
            """
            INSERT INTO invitations(
                id,group_code,token,invited_parent_name,phone,child_name,grade,role,
                status,invited_by,expires_at
            ) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,'pending',%s,%s)
            RETURNING *
            """,
            (
                str(invitation_id), group_code, token, invited_name,
                invited_phone or None, child_name, req.grade,
                req.role, actor.parent_name, expires_at,
            ),
        ).fetchone()
        conn.execute(
            """
            INSERT INTO memberships(
                group_code,parent_name,phone,child_name,grade,role,status,invited_by,joined_at,updated_at
            ) VALUES(%s,%s,%s,%s,%s,%s,'invited',%s,NULL,now())
            ON CONFLICT(group_code,parent_name) DO UPDATE SET
                phone=excluded.phone,child_name=excluded.child_name,grade=excluded.grade,
                role=excluded.role,status=CASE WHEN memberships.status='active' THEN 'active' ELSE 'invited' END,
                invited_by=excluded.invited_by,updated_at=now()
            """,
            (
                group_code, invited_name, invited_phone or None,
                child_name, req.grade, req.role, actor.parent_name,
            ),
        )
        conn.execute(
            "UPDATE carpool_groups SET updated_at=now() WHERE code=%s",
            (group_code,),
        )
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            "invitation_created", "invitation", str(invitation_id),
            {"invitee": invited_name, "role": req.role, "expiresAt": expires_at.isoformat()},
        )
        conn.commit()
        return {"invitation": serialize_invitation(row)}


@app.post("/v1/invitations/{token}/accept")
def accept_invitation(
    token: str,
    req: AcceptInvitationRequest,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    if actor.parent_name.casefold() != req.parentName.strip().casefold():
        raise HTTPException(403, "Signed-in parent does not match the acceptance request")
    if actor.phone != normalize_phone(req.phone):
        raise HTTPException(403, "Signed-in phone does not match the acceptance request")

    with db() as conn:
        row = conn.execute(
            "SELECT * FROM invitations WHERE token=%s FOR UPDATE", (token.upper(),)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Invitation code not found")
        if row["status"] != "pending":
            raise HTTPException(409, f"Invitation is already {row['status']}")
        if row["expires_at"] < datetime.now(timezone.utc):
            conn.execute("UPDATE invitations SET status='expired' WHERE id=%s", (row["id"],))
            conn.commit()
            raise HTTPException(410, "Invitation has expired")
        if row["invited_parent_name"].casefold() != actor.parent_name.casefold():
            raise HTTPException(403, "Invitation is for another parent")
        invited_phone = normalize_phone(row.get("phone"))
        if invited_phone and invited_phone != actor.phone:
            raise HTTPException(403, "Invitation is linked to another phone")
        phone_owner = conn.execute(
            """
            SELECT parent_name FROM memberships
            WHERE group_code=%s AND phone=%s AND lower(parent_name)<>lower(%s)
            """,
            (row["group_code"], actor.phone, actor.parent_name),
        ).fetchone()
        if phone_owner:
            raise HTTPException(409, "This phone is already linked to another parent in the group")

        conn.execute(
            """
            UPDATE invitations SET status='accepted',accepted_at=now(),accepted_by=%s
            WHERE id=%s
            """,
            (actor.parent_name, row["id"]),
        )
        conn.execute(
            """
            INSERT INTO memberships(
                group_code,parent_name,phone,child_name,grade,role,status,invited_by,joined_at,updated_at
            ) VALUES(%s,%s,%s,%s,%s,%s,'active',%s,now(),now())
            ON CONFLICT(group_code,parent_name) DO UPDATE SET
                phone=excluded.phone,child_name=excluded.child_name,grade=excluded.grade,
                role=excluded.role,status='active',joined_at=COALESCE(memberships.joined_at,now()),updated_at=now()
            """,
            (
                row["group_code"], actor.parent_name, actor.phone, row["child_name"],
                row["grade"], row["role"], row["invited_by"],
            ),
        )
        record_audit(
            conn, row["group_code"], actor.parent_name, actor.phone,
            "invitation_accepted", "invitation", str(row["id"]),
            {"role": row["role"], "child": row["child_name"]},
        )
        conn.commit()
        return load_workspace(conn, row["group_code"])


@app.patch("/v1/groups/{group_code}/members/{parent_name}/role")
def update_member_role(
    group_code: str,
    parent_name: str,
    req: MemberRolePayload,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    if req.role not in {"admin", "parent", "viewer"}:
        raise HTTPException(400, "Role must be admin, parent or viewer")
    with db() as conn:
        require_admin(conn, group_code, actor)
        target = conn.execute(
            "SELECT * FROM memberships WHERE group_code=%s AND lower(parent_name)=lower(%s)",
            (group_code, parent_name),
        ).fetchone()
        if not target:
            raise HTTPException(404, "Group member not found")
        if target["role"] == "owner":
            raise HTTPException(409, "The owner role cannot be changed through this endpoint")
        conn.execute(
            "UPDATE memberships SET role=%s,updated_at=now() WHERE group_code=%s AND parent_name=%s",
            (req.role, group_code, target["parent_name"]),
        )
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            "member_role_changed", "membership", target["parent_name"],
            {"previousRole": target["role"], "newRole": req.role},
        )
        conn.commit()
        return load_workspace(conn, group_code)


# ---------------------------------------------------------------------------
# Constraint requests, approvals and versioned schedules
# ---------------------------------------------------------------------------


@app.post("/v1/groups/{group_code}/constraint-requests")
def create_constraint_request(
    group_code: str,
    req: ConstraintRequestPayload,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    validate_weekdays(req.requestedDropWeekdays)
    validate_weekdays(req.requestedPickupWeekdays)

    with db() as conn:
        require_member(conn, group_code, actor)
        conn.execute(
            "SELECT pg_advisory_xact_lock(hashtext(%s))",
            (f"constraint:{group_code}:{actor.parent_name.casefold()}",),
        )
        pending = conn.execute(
            """
            SELECT 1 FROM constraint_requests
            WHERE group_code=%s AND lower(parent_name)=lower(%s) AND status='pending'
            """,
            (group_code, actor.parent_name),
        ).fetchone()
        if pending:
            raise HTTPException(409, "A constraint update is already pending admin review")

        current = conn.execute(
            "SELECT * FROM parent_constraints WHERE group_code=%s AND lower(parent_name)=lower(%s)",
            (group_code, actor.parent_name),
        ).fetchone()
        previous_drops = set(current["drop_weekdays"] or []) if current else set()
        previous_pickups = set(current["pickup_weekdays"] or []) if current else set()
        current_notes = (current.get("notes") or "") if current else ""
        if (
            previous_drops == set(req.requestedDropWeekdays)
            and previous_pickups == set(req.requestedPickupWeekdays)
            and current_notes.strip() == req.notes.strip()
        ):
            raise HTTPException(409, "The requested availability is already approved; no update is needed")
        group = require_group(conn, group_code)
        affected = estimate_assignment_impact(
            conn, group_code, actor.parent_name,
            set(req.requestedDropWeekdays), set(req.requestedPickupWeekdays),
        )
        request_id = uuid.uuid4()
        row = conn.execute(
            """
            INSERT INTO constraint_requests(
                id,group_code,parent_name,previous_drop_weekdays,previous_pickup_weekdays,
                requested_drop_weekdays,requested_pickup_weekdays,notes,status,
                existing_assignments_affected,base_version
            ) VALUES(%s,%s,%s,%s::jsonb,%s::jsonb,%s::jsonb,%s::jsonb,%s,'pending',%s,%s)
            RETURNING *
            """,
            (
                str(request_id), group_code, actor.parent_name,
                json.dumps(sorted(previous_drops)), json.dumps(sorted(previous_pickups)),
                json.dumps(sorted(req.requestedDropWeekdays)), json.dumps(sorted(req.requestedPickupWeekdays)),
                req.notes, affected, group.get("current_schedule_version") or 1,
            ),
        ).fetchone()
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            "constraint_request_submitted", "constraint_request", str(request_id),
            {
                "drop": ",".join(map(str, sorted(req.requestedDropWeekdays))),
                "pickup": ",".join(map(str, sorted(req.requestedPickupWeekdays))),
                "affectedTrips": affected,
            },
        )
        conn.commit()
        return {"request": serialize_constraint_request(row), "constraint": None, "scheduleVersion": None}


@app.post("/v1/groups/{group_code}/constraint-requests/{request_id}/review")
def review_constraint_request(
    group_code: str,
    request_id: uuid.UUID,
    req: ConstraintReviewPayload,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    if req.decision not in {"approved", "rejected"}:
        raise HTTPException(400, "Decision must be approved or rejected")

    with db() as conn:
        require_admin(conn, group_code, actor)
        request_row = conn.execute(
            "SELECT * FROM constraint_requests WHERE id=%s AND group_code=%s FOR UPDATE",
            (str(request_id), group_code),
        ).fetchone()
        if not request_row:
            raise HTTPException(404, "Constraint request not found")
        if request_row["status"] != "pending":
            raise HTTPException(409, f"Constraint request is already {request_row['status']}")

        constraint_serialized = None
        schedule_serialized = None
        if req.decision == "approved":
            current = conn.execute(
                "SELECT version FROM parent_constraints WHERE group_code=%s AND parent_name=%s",
                (group_code, request_row["parent_name"]),
            ).fetchone()
            constraint_version = (current["version"] if current else 0) + 1
            constraint_row = conn.execute(
                """
                INSERT INTO parent_constraints(
                    group_code,parent_name,drop_weekdays,pickup_weekdays,notes,version,
                    effective_from,updated_by,updated_at
                ) VALUES(%s,%s,%s::jsonb,%s::jsonb,%s,%s,current_date,%s,now())
                ON CONFLICT(group_code,parent_name) DO UPDATE SET
                    drop_weekdays=excluded.drop_weekdays,pickup_weekdays=excluded.pickup_weekdays,
                    notes=excluded.notes,version=excluded.version,effective_from=excluded.effective_from,
                    updated_by=excluded.updated_by,updated_at=now()
                RETURNING *
                """,
                (
                    group_code, request_row["parent_name"],
                    json.dumps(request_row["requested_drop_weekdays"]),
                    json.dumps(request_row["requested_pickup_weekdays"]),
                    request_row["notes"], constraint_version, actor.parent_name,
                ),
            ).fetchone()

            group = conn.execute(
                """
                UPDATE carpool_groups SET current_schedule_version=current_schedule_version+1,updated_at=now()
                WHERE code=%s RETURNING current_schedule_version
                """,
                (group_code,),
            ).fetchone()
            schedule_id = uuid.uuid4()
            schedule_row = conn.execute(
                """
                INSERT INTO schedule_versions(
                    id,group_code,version,status,reason,generated_by,generated_at,
                    published_by,published_at,change_summary
                ) VALUES(%s,%s,%s,'published',%s,%s,now(),%s,now(),%s::jsonb)
                RETURNING *
                """,
                (
                    str(schedule_id), group_code, group["current_schedule_version"],
                    f"Approved availability update for {request_row['parent_name']}",
                    actor.parent_name, actor.parent_name,
                    json.dumps({
                        "parent": request_row["parent_name"],
                        "affectedTrips": str(request_row["existing_assignments_affected"]),
                        "constraintVersion": str(constraint_version),
                    }),
                ),
            ).fetchone()
            constraint_serialized = serialize_constraint(constraint_row)
            schedule_serialized = serialize_schedule_version(schedule_row)

        reviewed_row = conn.execute(
            """
            UPDATE constraint_requests SET
                status=%s,reviewed_at=now(),reviewed_by=%s,
                rejection_reason=CASE WHEN %s='rejected' THEN %s ELSE NULL END
            WHERE id=%s RETURNING *
            """,
            (req.decision, actor.parent_name, req.decision, req.reviewNote, str(request_id)),
        ).fetchone()
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            f"constraint_request_{req.decision}", "constraint_request", str(request_id),
            {
                "parent": request_row["parent_name"],
                "reviewNote": req.reviewNote,
                "scheduleVersion": str(schedule_serialized["version"]) if schedule_serialized else "unchanged",
            },
        )
        conn.commit()
        return {
            "request": serialize_constraint_request(reviewed_row),
            "constraint": constraint_serialized,
            "scheduleVersion": schedule_serialized,
        }


@app.post("/v1/groups/{group_code}/schedule-versions")
def create_schedule_version(
    group_code: str,
    req: ScheduleVersionPayload,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        require_admin(conn, group_code, actor)
        group = conn.execute(
            """
            UPDATE carpool_groups SET current_schedule_version=current_schedule_version+1,updated_at=now()
            WHERE code=%s RETURNING current_schedule_version
            """,
            (group_code,),
        ).fetchone()
        version_id = uuid.uuid4()
        row = conn.execute(
            """
            INSERT INTO schedule_versions(
                id,group_code,version,status,reason,generated_by,published_by,published_at,change_summary
            ) VALUES(%s,%s,%s,'published',%s,%s,%s,now(),'{}'::jsonb) RETURNING *
            """,
            (str(version_id), group_code, group["current_schedule_version"], req.reason, actor.parent_name, actor.parent_name),
        ).fetchone()
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            "schedule_published", "schedule", str(group["current_schedule_version"]),
            {"reason": req.reason},
        )
        conn.commit()
        return {"scheduleVersion": serialize_schedule_version(row)}


# ---------------------------------------------------------------------------
# Single authoritative calendar, events and analytics
# ---------------------------------------------------------------------------


@app.post("/v1/groups/{group_code}/calendar")
def upload_calendar(
    group_code: str,
    req: CalendarUploadPayload,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)

    source_blob: bytes | None = None
    verified_hash: str | None = None
    if req.sourceContentBase64 is not None:
        try:
            source_blob = base64.b64decode(req.sourceContentBase64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise HTTPException(400, "Calendar PDF content is not valid Base64") from exc
        if req.sourceFileSize is not None and len(source_blob) != req.sourceFileSize:
            raise HTTPException(400, "Calendar PDF size does not match the declared size")
        calculated_hash = hashlib.sha256(source_blob).hexdigest()
        verified_hash = calculated_hash.lower()
        if req.sourceSHA256 is not None and verified_hash != req.sourceSHA256.lower():
            raise HTTPException(400, "Calendar PDF SHA-256 does not match the uploaded content")
    elif req.sourceSHA256 is not None or req.sourceFileSize is not None:
        raise HTTPException(400, "Calendar PDF metadata was supplied without the PDF content")

    if req.schoolKey == "basis-phoenix-primary":
        if source_blob is None:
            raise HTTPException(400, "Select and upload the authoritative BASIS Phoenix Primary calendar PDF")
        if verified_hash != BASIS_CALENDAR_SHA256:
            raise HTTPException(400, "The selected PDF does not match the authoritative BASIS Phoenix Primary 2026–27 calendar")

    with db() as conn:
        require_admin(conn, group_code, actor)
        existing = conn.execute(
            """
            SELECT * FROM school_calendars
            WHERE school_key=%s AND academic_year=%s AND group_code=%s
            """,
            (req.schoolKey, req.academicYear, group_code),
        ).fetchone()
        if existing:
            raise HTTPException(
                409,
                detail={
                    "message": "Holiday schedule is already uploaded and considered in the carpool schedule.",
                    "uploadedBy": existing["uploaded_by"],
                    "sourceName": existing["source_name"],
                    "uploadedAt": existing["uploaded_at"].isoformat(),
                },
            )

        calendar_row = conn.execute(
            """
            INSERT INTO school_calendars(
                school_key,school_name,academic_year,group_code,uploaded_by,source_name,event_count,
                source_sha256,source_file_size,source_blob
            ) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT(school_key,academic_year,group_code) DO NOTHING
            RETURNING *
            """,
            (
                req.schoolKey, req.schoolName, req.academicYear, group_code,
                actor.parent_name, req.sourceName, len(req.events),
                verified_hash,
                len(source_blob) if source_blob is not None else None,
                source_blob,
            ),
        ).fetchone()
        if calendar_row is None:
            existing = conn.execute(
                """
                SELECT * FROM school_calendars
                WHERE school_key=%s AND academic_year=%s AND group_code=%s
                """,
                (req.schoolKey, req.academicYear, group_code),
            ).fetchone()
            raise HTTPException(
                409,
                detail={
                    "message": "Holiday schedule is already uploaded and considered in the carpool schedule.",
                    "uploadedBy": existing["uploaded_by"] if existing else "another admin",
                    "sourceName": existing["source_name"] if existing else "authoritative calendar",
                    "uploadedAt": existing["uploaded_at"].isoformat() if existing else None,
                },
            )
        for event in req.events:
            conn.execute(
                """
                INSERT INTO calendar_events(id,calendar_id,event_type,title,start_date,end_date,notes)
                VALUES(%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    str(uuid.uuid4()), calendar_row["id"], event.type, event.title,
                    event.startDate.date(), event.endDate.date(), event.notes,
                ),
            )
        record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            "calendar_registered", "calendar", f"{req.schoolKey}-{req.academicYear}",
            {
                "source": req.sourceName,
                "eventCount": len(req.events),
                "sourceSHA256": verified_hash or "not supplied",
                "sourceFileSize": len(source_blob) if source_blob is not None else 0,
            },
        )
        conn.commit()
        event_rows = conn.execute(
            "SELECT * FROM calendar_events WHERE calendar_id=%s ORDER BY start_date", (calendar_row["id"],)
        ).fetchall()
        return {
            "status": "registered",
            "calendar": serialize_calendar(calendar_row),
            "analytics": calendar_analytics(event_rows),
        }


# ---------------------------------------------------------------------------
# Explicit audit append for trip actions still synchronized through snapshots.
# ---------------------------------------------------------------------------


@app.post("/v1/groups/{group_code}/audit")
def append_audit(
    group_code: str,
    req: AuditPayload,
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        require_member(conn, group_code, actor)
        audit_id = record_audit(
            conn, group_code, actor.parent_name, actor.phone,
            req.action, req.entityType, req.entityID, req.details,
        )
        conn.commit()
        return {"status": "recorded", "auditID": audit_id}


@app.post("/v1/groups/{group_code}/events/{event_type}")
def queue_notification(
    group_code: str,
    event_type: str,
    payload: dict[str, Any],
    x_kcp_parent: str = Header(default=""),
    x_kcp_phone: str = Header(default=""),
) -> dict[str, Any]:
    actor = identity(x_kcp_parent, x_kcp_phone)
    with db() as conn:
        require_member(conn, group_code, actor)
        row = conn.execute(
            """
            INSERT INTO notification_outbox(group_code,event_type,payload)
            VALUES(%s,%s,%s::jsonb) RETURNING id
            """,
            (group_code, event_type, json.dumps(payload)),
        ).fetchone()
        conn.commit()
    return {
        "status": "queued",
        "notification_id": row["id"],
        "note": "APNs credentials are required for delivery",
    }
