# Transportation safety profiles

KCP stores only operational information needed to transport children safely.

## Child profile

- pickup and drop-off address
- authorized pickup people
- emergency contact
- booster, car-seat or other seating requirement
- critical transportation alert
- pickup instructions
- consent timestamp

Do not store a general medical history. Critical alerts should contain only what the assigned driver must know.

## Driver profile

- emergency contact
- license acknowledgement
- insurance acknowledgement
- group safety acknowledgement
- optional driver note

KCP records acknowledgements; it does not independently verify licenses or insurance.

## Vehicle

- description
- child-seat capacity
- booster capacity
- car-seat capacity
- active/inactive status

## Capacity check

For each ride, KCP compares the child roster with the selected driver's active vehicle. It reports seat, booster and car-seat mismatches before the assignment is accepted or started.

## Privacy

- Viewer: no safety profile access
- Parent: own child and own driver/vehicle details
- Owner/Admin: operational management access for the group
- Assigned driver: trip-scoped access is implemented separately and limited to the ride window
- Super Admin: sensitive details remain outside ordinary support summaries and require audited break-glass access

A group can initially treat profiles as recommended, then enable **Require completed safety profiles** after every active driver has completed setup.
