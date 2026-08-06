# Kidscarpool (KCP)

Kidscarpool is a private school-carpool coordination pilot with group invitations, parent availability, admin approvals, one authoritative school calendar, fair schedule generation, volunteer coverage, trip-time controls, points, leaderboard, reminders, multi-group switching, and an append-only audit trail.

## Free cloud pilot — Supabase + GitHub Pages

The quickest way to test the MVP with several families **without paying for Apple Developer Program membership** is the installable web pilot:

```text
https://kiransgithub.github.io/kidscarpool/
```

On iPhone, open the URL in Safari and choose **Share → Add to Home Screen**. It launches like an app and connects to the shared Supabase database from any network.

The web pilot includes:

- device-bound Supabase anonymous authentication
- private group creation and group switching
- invitation creation, sharing and acceptance
- Owner, Admin, Parent and Viewer roles
- parent drop/pickup weekday constraints
- admin approval queue
- one authoritative calendar per group/school/year
- verified BASIS Phoenix Primary 2026–27 PDF fingerprint
- holiday, long-weekend, early-pickup and no-Late-Bird analytics
- server-side fair schedule generation
- cover requests and volunteer acceptance
- server-enforced start/completion rules
- 10 points for regular completed trips and 20 for volunteer trips
- immutable database audit events

See [`SUPABASE_PILOT_SETUP.md`](SUPABASE_PILOT_SETUP.md) for the one-time Supabase and GitHub Pages setup.

> A native iOS `.ipa` downloaded from GitHub cannot be installed directly on arbitrary iPhones without Apple code signing. The PWA is the zero-cost, low-friction MVP distribution route. The native SwiftUI project remains available for Xcode device testing and a later TestFlight release.

## Repository layout

```text
SchoolCarpool/                 Native SwiftUI application
SchoolCarpool.xcodeproj/       Xcode project
SchoolCarpoolTests/            Native scheduling tests
backend/                       Previous laptop-hosted FastAPI/PostgreSQL pilot
supabase/                      Version-controlled Supabase configuration/migrations
web/                           Installable GitHub Pages PWA
.github/workflows/             GitHub Pages deployment
Reference/                     Authoritative pilot reference material
```

## Supabase deployment

The ordered migrations are under:

```text
supabase/migrations/202608060001_kcp_core_rls.sql
supabase/migrations/202608060002_kcp_onboarding_constraints.sql
supabase/migrations/202608060003_kcp_calendar_schedule.sql
supabase/migrations/202608060004_kcp_trips_storage_grants.sql
```

When Supabase's GitHub integration is connected to this repository with working directory `.`, changes merged to `main` deploy automatically. CLI alternative:

```bash
supabase login
supabase link --project-ref xrzofopbknawqsqbiahk
supabase db push
```

Anonymous Sign-Ins must be enabled once under **Supabase Dashboard → Authentication**.

## Native SwiftUI pilot v8

The native project currently includes:

- prominent Groups tab beside Home
- active-group indicator and one-tap switching
- private invitations and multiple admins
- per-parent constraints and approval workflow
- versioned schedules
- calendar duplicate protection and analytics
- trip time gates, volunteering, points and leaderboard
- local reminders and audit history

Open `SchoolCarpool.xcodeproj`, choose your development team, select a physical iPhone, and Run.

## Legacy laptop backend

The `backend/` directory preserves the earlier FastAPI/PostgreSQL trial. It is useful for local development but no longer required for the Supabase web pilot.

```bash
cd backend
docker compose up --build -d
curl http://localhost:8090/health
```

Do not use `docker compose down -v` unless you intentionally want to delete its PostgreSQL volume.

## Security boundary

- The Supabase publishable key is intentionally present in web/mobile client code.
- Row Level Security plus authenticated user JWTs protect the data.
- Never commit a database password, service-role key, secret key, Apple signing certificate, or provisioning profile.
- Anonymous pilot accounts are device-bound. Before broader release, link them to verified email, phone, Sign in with Apple, or passkeys.
