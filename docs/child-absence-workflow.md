# Child absence and separate-pickup workflow

A parent can report that a child will not use one ride or a range of rides.

## Reasons

```text
Absent
Picked up separately
Student hours
After-school activity
Appointment
Other
```

## Parent flow

```text
Home → Report update
Choose child
Choose one ride or a date range
Choose reason
Add optional note
Save
```

The parent can cancel the report until the affected ride starts.

## Driver behavior

The assigned driver sees the report inside Driver mode. The child is visibly marked Not riding with the reported reason and note. The driver does not need to mark the child skipped again.

## Access

- parent: their children and their reports
- assigned driver: reports relevant to the selected ride
- Owner/Admin: reports in the group
- Viewer: no absence reporting or operational absence details

## Notifications

`notify_driver` is persisted now. Push/email delivery is implemented by the notification PR; before that deployment, the driver's live roster and Requests view still update from the database.
