# Coverage escalation and ride swaps

## Cover escalation

An open cover request remains unassigned until an eligible driver volunteers.

```text
More than 60 minutes: Open
Within 60 minutes: Eligible drivers
Within 30 minutes: Group Owner/Admin escalation
Within 15 minutes: Coverage unresolved
```

Escalation changes visibility and notification priority. It never silently chooses a driver.

The request displays a response deadline. Acceptance records the volunteer's name and requires that volunteer to confirm the ride. The requester may withdraw only while the request is open. After acceptance, the volunteer or a group administrator must release it before the ride starts.

## Coordinated swap

A driver may offer one future assigned ride in exchange for another future ride in the same group.

```text
Driver A offers Tuesday
Driver A requests Driver B's Thursday
Driver B accepts or declines
```

Acceptance atomically exchanges the scheduled drivers on both rides. Any prior driver confirmations are cleared, and both new drivers must confirm their new assignments.

Started, covered, unassigned or cross-group rides cannot be swapped.
