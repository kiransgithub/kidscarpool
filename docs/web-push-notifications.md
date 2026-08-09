# Web Push notifications

KCP asks for notification permission only after a member opens Settings and taps **Enable reminders**.

## Categories

- upcoming assigned ride
- schedule change
- cover requested, accepted or escalated
- child ride update
- driver confirmation due
- completion confirmation due
- unconfirmed ride
- admin approval
- invitation accepted
- swap requested or resolved
- optional points notification

Users can disable categories globally. Group-specific preferences are supported by the database model.

## Generate VAPID keys

On a trusted workstation:

```bash
npx web-push generate-vapid-keys
```

Keep the private key secret. The public key is safe for authenticated clients.

## Configure Supabase

As the verified Super Admin, store only the public key in the database:

```sql
select public.kcp_set_platform_setting(
  'web_push_public_key',
  'YOUR_PUBLIC_VAPID_KEY'
);
```

Configure Edge Function secrets:

```bash
supabase secrets set \
  VAPID_PUBLIC_KEY='YOUR_PUBLIC_VAPID_KEY' \
  VAPID_PRIVATE_KEY='YOUR_PRIVATE_VAPID_KEY' \
  VAPID_SUBJECT='mailto:YOUR_SUPPORT_EMAIL' \
  NOTIFICATION_DISPATCH_SECRET='A_LONG_RANDOM_SECRET'
```

Deploy:

```bash
supabase functions deploy send-notifications --no-verify-jwt
```

Schedule an authenticated POST every minute to:

```text
/functions/v1/send-notifications
```

with header:

```text
x-kcp-dispatch-secret: A_LONG_RANDOM_SECRET
```

Use Supabase Cron/Scheduled Functions or another trusted scheduler. Do not place the dispatch secret in the PWA.

## Delivery architecture

```text
Database event
  → kcp_notification_outbox
  → send-notifications Edge Function
  → active Web Push subscriptions
  → kcp_notification_deliveries
```

The outbox uses unique dedupe keys. Repeated reminder or trigger processing does not create duplicate notifications. Push endpoints that return HTTP 404/410 are revoked automatically.

## iPhone validation

Web Push requires an installed Home Screen web app on supported iOS versions.

1. Add KCP to the Home Screen.
2. Open KCP from the Home Screen icon.
3. Open More → Settings → Notifications.
4. Tap Enable reminders and allow notifications.
5. Trigger a test cover request from another account.
6. Confirm the notification opens KCP Requests.
