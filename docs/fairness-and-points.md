# Workload fairness and optional points

KCP separates operational fairness from gamification.

## Fairness ledger

The fairness view includes:

- completed rides
- volunteer rides
- current upcoming assignments
- estimated driving minutes
- children transported
- weighted workload share
- difference from the group average

The default workload formula is transparent:

```text
completed rides
+ 0.25 × completed driving hours
+ 0.05 × child-rides
```

Owners/Admins can adjust the time and child-load weights. These weights do not change ride eligibility or points.

## Points

Points remain optional recognition:

```text
10 points — confirmed scheduled completion
20 points — confirmed volunteer completion
```

A group can disable future point awards. Disabling points does not remove completed ride history or fairness metrics.

## Visibility

- Owner/Admin: all active driving members
- Parent/Driver: all drivers when public participation is enabled; otherwise only their own row
- Viewer: no operational fairness detail

A group can disable the public participation view while retaining the Owner/Admin operational ledger.

## Safety

Fairness and points never override:

- child-seat capacity
- driver readiness
- availability
- conflicts
- cover acceptance
- explicit ride confirmation
