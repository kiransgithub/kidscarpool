# Permanent email identity setup

KCP keeps anonymous sign-in available only as a temporary onboarding bridge. A user can link a verified email without changing their Supabase user ID, so existing memberships, stable participants, schedules, trips and points remain attached.

## One-time Supabase configuration

In **Authentication → Providers → Email**:

1. Enable Email.
2. Enable manual identity linking.
3. Keep email confirmations enabled.
4. Configure the Site URL as the GitHub Pages KCP URL.
5. Add the same Pages URL to Redirect URLs, including a trailing wildcard when supported.
6. Review the email rate limit before inviting the pilot families.

Do not disable anonymous sign-in until every pilot member has upgraded or has a permanent invitation flow.

## User flow

Existing pilot user:

```text
Settings → Secure with email → open verification link → account becomes permanent
```

Second phone:

```text
Email sign in → open magic link → same user ID and groups load
```

## Validation

1. Upgrade one pilot account.
2. Confirm `kcp_identity_status()` returns `identity_verified = true`.
3. Open KCP on a second phone and use Email sign in.
4. Verify both phones show the same groups and roles.
5. In Settings, remove one device and confirm only that device is signed out on its next sync.

## Security notes

- The publishable key remains in the PWA; no service-role key is used.
- Device removal is an application access control. Supabase Auth session administration can be added later through a trusted Edge Function.
- Email addresses are not shown to other group members.
