# Role-adaptive invitations

The invitation form begins with the intended role and asks only for information that role needs.

## Viewer

```text
Name
Email or phone
Role: Viewer
```

- no child required
- no availability record
- no driving assignment
- read-only schedule access

## Parent

```text
Parent name
Email or phone
Child or rider
Grade or level
Can drive?
```

A Parent invitation requires a child or rider. Driving can be disabled.

## Admin

```text
Name
Email or phone
Role: Admin
Can drive?
Child or rider: optional
```

## Deep links

The shared URL contains the invitation token:

```text
https://…/kidscarpool/?invite=TOKEN
```

Opening the link displays the group name, invited role, optional child and driving status before acceptance. Email-bound invitations require the matching verified account.

## Invitation lifecycle

An Owner or Admin can:

- share the current link
- generate a new code and expiry
- revoke a pending invitation

All creation, acceptance, resend and revoke actions are written to the group audit history.
