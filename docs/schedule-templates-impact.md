# Schedule templates and impact review

## Templates

Templates populate the same generic schedule-plan model used by the custom builder. They contain no people, destinations or clock times.

- School weekdays
- One recurring activity
- Multi-day weekly rotation
- Pickup-only group
- Custom schedule

The administrator still enters the actual dates, day-specific times and participating drivers.

## Quick actions

- copy the first entered times to all enabled days
- select all active drivers
- switch to weekly alternating responsibility
- convert selected days to pickup-only

Advanced recurrence, overnight return and multi-session rules remain available.

## Preview and impact review

Preview now performs two server-backed calculations:

1. Generate the candidate occurrences.
2. Compare them with the currently published schedule.

The impact summary reports:

- total future rides
- added or removed rides
- changed times
- changed drivers
- affected people
- cross-group assignment conflicts
- changes occurring within 24 hours

Publishing is blocked until the latest draft has a matching impact preview.

## Cross-group conflicts

KCP compares each candidate driver assignment with that user’s current assignments in other active groups. Overlapping intervals are shown before publish and remain visible to the affected driver under Requests.

The administrator can still publish after an explicit warning because some overlaps may be intentional or resolved outside the schedule. The affected member is notified.

## Urgent acknowledgements

A future change within 24 hours creates an acknowledgement request for each affected driver. The driver can:

```text
Acknowledge
Flag a problem
```

Flagging a problem requires a note and remains visible to the group administrator. All preview, publish and acknowledgement actions are audited.
