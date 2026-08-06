# KCP Supabase + zero-cost pilot setup

The native SwiftUI project remains in this repository. For a zero-cost multi-parent MVP test, the repository also contains an installable Progressive Web App (PWA) under `web/`.

## Why the PWA is the zero-cost distribution path

Apple does not allow an unsigned `.ipa` downloaded from GitHub to be installed directly on arbitrary iPhones. A free Personal Team can install from Xcode only on registered development devices, and free provisioning expires after seven days. The PWA avoids that restriction: parents open the GitHub Pages URL in Safari and choose **Share → Add to Home Screen**.

## Supabase architecture

- Supabase anonymous Auth creates a unique, device-bound authenticated user.
- Row Level Security protects all family and group data.
- Group invitations bind an anonymous user to a private group.
- Owners and admins approve constraints, register one authoritative calendar, publish schedule versions, and review the immutable audit trail.
- Completed regular trips earn 10 points; volunteer trips earn 20 points.
- The database validates the start and completion windows. New pilot groups have a visible time override enabled so workflows can be tested before the school year starts.

## One-time Supabase configuration

1. Open the Supabase Dashboard for project `xrzofopbknawqsqbiahk`.
2. Go to **Authentication → Providers / Sign In** and enable **Anonymous Sign-Ins**.
3. Go to **Project Settings → Integrations → GitHub**.
4. Choose repository `kiransgithub/kidscarpool`.
5. Set **Working directory** to `.` because `supabase/` is at the repository root.
6. Enable deployment from `main`.
7. Merge/push the migrations under `supabase/migrations/` to `main`.

The migrations create the tables, RLS policies, RPC functions, private calendar-PDF bucket, scheduling engine, points ledger, and append-only audit controls.

### Alternative CLI deployment

```bash
supabase login
supabase link --project-ref xrzofopbknawqsqbiahk
supabase db push
```

Do not put the database password, service-role key, or secret key in this public repository.

## Enable GitHub Pages

1. Open the GitHub repository.
2. Go to **Settings → Pages**.
3. Under **Build and deployment**, select **GitHub Actions**.
4. Open **Actions → Deploy KCP pilot to GitHub Pages** and run it once, or push a change under `web/`.

Expected pilot URL:

```text
https://kiransgithub.github.io/kidscarpool/
```

## Parent pilot flow

1. Kiran opens the URL in Safari and adds it to the Home Screen.
2. Kiran enters his parent profile and creates a private group.
3. The admin uploads the authoritative BASIS PDF, reviews the analytics, and publishes the schedule.
4. The admin creates an invitation and shares the generated code plus the Pages URL.
5. Mohan/Pavan/Santosh open the URL, choose **Join with invite**, and enter the matching name, phone (when the invite is phone-bound), and invitation code.
6. Each parent submits their drop and pickup weekdays.
7. An owner/admin approves requests and regenerates the schedule.

## Pilot identity limitation

Anonymous Auth is deliberately frictionless and free, but it is device-bound. If a tester signs out or clears Safari website data, the same anonymous identity cannot be recovered. Before wider launch, link each account to verified email, phone OTP, Sign in with Apple, or passkeys.

## Secret hygiene

The Supabase publishable key is expected to be present in web/mobile client code; RLS is the security boundary. The database password is a secret. Rotate any database password that has been pasted into chat, email, source code, terminal history, or another uncontrolled location.
