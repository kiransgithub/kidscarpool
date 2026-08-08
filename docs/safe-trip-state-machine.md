# Safe trip state machine

KCP never treats elapsed time as proof that child transportation occurred.

## States

```text
Scheduled
  → Driver confirmation due
  → Driver ready
  → In progress
  → Completion confirmation due
  → Completed
```

When confirmation is missing:

```text
Scheduled or Ready
  → Unconfirmed

Completion confirmation due
  → Unconfirmed
```

`Unconfirmed` means the actual ride outcome must be resolved by the driver or a group Owner/Admin. It does not mean the ride failed; it means the system has no verified fact.

## Driver actions

1. **Confirm ride** — available beginning 24 hours before the scheduled time.
2. **Start ride** — requires Driver ready and opens 10 minutes before the scheduled time.
3. **Report arrival** — moves In progress to Completion confirmation due.
4. **Confirm completed** — explicitly completes the ride and awards points.

## Administrative confirmation

An Owner/Admin may resolve an In-progress, Completion-due or Unconfirmed ride only with a written reason. The event and note are audited.

## Points

- scheduled confirmed completion: 10
- volunteer confirmed completion: 20
- no points for Scheduled, Ready, In progress, Completion due or Unconfirmed
- one points row per trip

## Lifecycle scheduler

The minute-based lifecycle job can:

- request driver confirmation when scheduled time arrives
- mark an unanswered ride Unconfirmed after the grace period
- request completion confirmation when expected duration passes
- mark an unanswered completion Unconfirmed

It cannot start a ride, complete a ride, or award points.

## Cover behavior

A cover request remembers the prior safe state. Withdrawing an open request restores that state. A newly accepted volunteer must confirm the ride. After acceptance, only the volunteer or an Owner/Admin can release the ride before it starts.
