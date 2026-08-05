#!/usr/bin/env python3
"""End-to-end smoke test for the KCP pilot group workflow.

Uses only the Python standard library. It creates an isolated throwaway group,
invites a parent, accepts the invitation, submits and approves availability,
promotes the parent to admin, uploads a calendar, verifies duplicate-calendar
protection, and checks schedule/audit persistence.
"""

from __future__ import annotations

import json
import os
import random
import string
import sys
import urllib.error
import urllib.request
import uuid

BASE = os.getenv("KCP_BASE_URL", "http://127.0.0.1:8090").rstrip("/")
SUFFIX = "".join(random.choice(string.ascii_uppercase + string.digits) for _ in range(6))
GROUP_CODE = f"KCP-SMOKE-{SUFFIX}"
SECOND_GROUP_CODE = f"KCP-SMOKE-ALT-{SUFFIX}"
OWNER = f"SmokeOwner{SUFFIX}"
PARENT = f"SmokeParent{SUFFIX}"
OWNER_PHONE = "602555" + "".join(random.choice(string.digits) for _ in range(4))
PARENT_PHONE = "480555" + "".join(random.choice(string.digits) for _ in range(4))


def call(method: str, path: str, *, body=None, parent=OWNER, phone=OWNER_PHONE, expected=(200, 201)):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"{BASE}{path}",
        data=data,
        method=method,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-KCP-Parent": parent,
            "X-KCP-Phone": phone,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
            if response.status not in expected:
                raise AssertionError(f"{method} {path}: expected {expected}, got {response.status}")
            return response.status, payload
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        if exc.code in expected:
            try:
                return exc.code, json.loads(raw)
            except json.JSONDecodeError:
                return exc.code, raw
        raise AssertionError(f"{method} {path}: HTTP {exc.code}: {raw}") from exc


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def event(event_type: str, title: str, start: str, end: str | None = None):
    return {
        "id": str(uuid.uuid4()),
        "type": event_type,
        "title": title,
        "startDate": f"{start}T12:00:00Z",
        "endDate": f"{end or start}T12:00:00Z",
        "notes": "Smoke-test calendar event",
    }


def main() -> int:
    print(f"Testing {BASE} with group {GROUP_CODE}")
    status, health = call("GET", "/health", expected=(200,))
    require(health.get("status") == "ok", "Health endpoint did not report ok")

    _, workspace = call(
        "POST",
        "/v1/groups",
        body={
            "code": GROUP_CODE,
            "name": "KCP Workflow Smoke Group",
            "schoolKey": "kcp-smoke-school",
            "schoolName": "KCP Smoke School",
            "academicYear": "2026-27",
            "creatorChildName": "Owner Child",
            "creatorGrade": 4,
            "initialDropWeekdays": [2, 3, 4, 5, 6],
            "initialPickupWeekdays": [2, 3, 4, 5, 6],
            "initialNotes": "Owner seed availability",
        },
    )
    require(workspace["group"]["code"] == GROUP_CODE, "Group code mismatch")
    require(workspace["members"][0]["role"] == "owner", "Creator was not made owner")
    require(workspace["constraints"][0]["parentName"] == OWNER, "Owner availability was not persisted")

    # The same parent can own multiple groups, and the list endpoint must make
    # every one of them available to the iOS Groups tab.
    call(
        "POST",
        "/v1/groups",
        body={
            "code": SECOND_GROUP_CODE,
            "name": "KCP Alternate Smoke Group",
            "schoolKey": "kcp-smoke-school",
            "schoolName": "KCP Smoke School",
            "academicYear": "2026-27",
            "creatorChildName": "Owner Child",
            "creatorGrade": 4,
            "initialDropWeekdays": [2, 3, 4, 5, 6],
            "initialPickupWeekdays": [2, 3, 4, 5, 6],
            "initialNotes": "Second group for switch testing",
        },
    )
    _, groups_payload = call("GET", "/v1/groups", expected=(200,))
    listed_codes = {item["group"]["code"] for item in groups_payload["groups"]}
    require({GROUP_CODE, SECOND_GROUP_CODE}.issubset(listed_codes), "Multi-group list did not retain both groups")

    # Reusing the signed-in owner's phone for another parent must return a
    # useful 409, rather than falling through to a PostgreSQL unique violation.
    conflict_status, conflict_payload = call(
        "POST",
        f"/v1/groups/{GROUP_CODE}/invitations",
        body={
            "invitedParentName": f"WrongPhone{SUFFIX}",
            "phone": OWNER_PHONE,
            "childName": "Wrong Phone Child",
            "grade": 4,
            "role": "parent",
        },
        expected=(409,),
    )
    require(conflict_status == 409, "Owner phone reuse was not rejected cleanly")
    require("already linked" in str(conflict_payload), "Phone conflict did not return a useful diagnostic")

    _, invite_response = call(
        "POST",
        f"/v1/groups/{GROUP_CODE}/invitations",
        body={
            "invitedParentName": PARENT,
            "phone": PARENT_PHONE,
            "childName": "Invited Child",
            "grade": 5,
            "role": "parent",
        },
    )
    token = invite_response["invitation"]["token"]

    _, accepted = call(
        "POST",
        f"/v1/invitations/{token}/accept",
        body={"phone": PARENT_PHONE, "parentName": PARENT},
        parent=PARENT,
        phone=PARENT_PHONE,
    )
    require(any(m["parentName"] == PARENT and m["status"] == "active" for m in accepted["members"]),
            "Invitation acceptance did not activate the member")
    _, parent_groups = call("GET", "/v1/groups", parent=PARENT, phone=PARENT_PHONE, expected=(200,))
    require(any(item["group"]["code"] == GROUP_CODE for item in parent_groups["groups"]),
            "Accepted parent could not discover the joined group")

    _, request_response = call(
        "POST",
        f"/v1/groups/{GROUP_CODE}/constraint-requests",
        body={
            "requestedDropWeekdays": [2, 4, 6],
            "requestedPickupWeekdays": [3, 5],
            "notes": "Smoke-test preference",
        },
        parent=PARENT,
        phone=PARENT_PHONE,
    )
    request_id = request_response["request"]["id"]
    require(request_response["request"]["status"] == "pending", "Constraint request was not pending")

    _, review = call(
        "POST",
        f"/v1/groups/{GROUP_CODE}/constraint-requests/{request_id}/review",
        body={"decision": "approved", "reviewNote": "Approved by smoke test"},
    )
    require(review["request"]["status"] == "approved", "Constraint request was not approved")
    require(set(review["constraint"]["pickupWeekdays"]) == {3, 5}, "Approved constraint was not persisted")
    require(review["scheduleVersion"] is not None, "Approval did not create a schedule version")

    _, role_workspace = call(
        "PATCH",
        f"/v1/groups/{GROUP_CODE}/members/{PARENT}/role",
        body={"role": "admin"},
    )
    require(any(m["parentName"] == PARENT and m["role"] == "admin" for m in role_workspace["members"]),
            "Second admin was not persisted")

    calendar_payload = {
        "schoolKey": "kcp-smoke-school",
        "schoolName": "KCP Smoke School",
        "academicYear": "2026-27",
        "sourceName": "KCP smoke authoritative calendar",
        "events": [
            event("first_day", "First Day", "2026-08-05"),
            event("no_school", "Labor Day", "2026-09-07"),
            event("early_release", "Early Pickup", "2026-10-07"),
            event("no_school", "Winter Break", "2026-12-21", "2027-01-01"),
            event("last_day", "Last Day", "2027-05-28"),
        ],
    }
    _, calendar = call("POST", f"/v1/groups/{GROUP_CODE}/calendar", body=calendar_payload)
    require(calendar["calendar"]["eventCount"] == 5, "Calendar event count mismatch")
    require(calendar["analytics"]["holidayPeriods"] == 2, "Calendar analytics mismatch")
    require(calendar["analytics"]["earlyPickups"] == 2, "Early-pickup analytics mismatch")

    duplicate_status, _ = call(
        "POST",
        f"/v1/groups/{GROUP_CODE}/calendar",
        body=calendar_payload,
        expected=(409,),
    )
    require(duplicate_status == 409, "Duplicate calendar was not rejected")

    _, final_workspace = call("GET", f"/v1/groups/{GROUP_CODE}/workspace", expected=(200,))
    actions = {event_row["action"] for event_row in final_workspace["auditEvents"]}
    expected_actions = {
        "group_created",
        "invitation_created",
        "invitation_accepted",
        "constraint_request_submitted",
        "constraint_request_approved",
        "member_role_changed",
        "calendar_registered",
    }
    require(expected_actions.issubset(actions), f"Missing audit actions: {sorted(expected_actions - actions)}")
    require(len(final_workspace["scheduleVersions"]) >= 2, "Schedule versions were not retained")

    print("PASS: multi-group listing/switch support, invitation diagnostics, onboarding, constraints, multi-admin, calendar, analytics, duplicate prevention and audit")
    print(f"Created audit test group: {GROUP_CODE}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - show a direct diagnostic for pilot users
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
