# Supabase pilot setup for Kidscarpool

This folder is a deployment blueprint. The current iOS pilot still uses its local/pilot-server service; connect the Swift app to Supabase after creating the project and adding `supabase-swift`.

## 1. Create the project

1. Create a Supabase project in the US West region nearest Phoenix.
2. Save the Project URL and **publishable** key.
3. Never place a secret/service-role key in the iOS app.

## 2. Create the database

Open **SQL Editor**, paste `001_kcp_pilot_schema.sql`, and run it once. It creates:

- private carpool groups and approved memberships
- one authoritative calendar per group/school/academic year
- parent weekday constraints
- trips and cover requests
- idempotent 10/20-point ledger
- APNs device-token storage
- Row Level Security and Realtime publication

## 3. Configure phone OTP

In **Authentication > Providers > Phone**, enable phone sign-in and configure an SMS provider supported by your Supabase project. For a four-family pilot, restrict onboarding to pre-invited phone numbers instead of allowing arbitrary account creation.

## 4. Add the Swift client

In Xcode:

1. **File > Add Package Dependencies**
2. Add `https://github.com/supabase/supabase-swift`
3. Add the `Supabase` product to the SchoolCarpool target.

Create an uncommitted `SupabaseConfig.xcconfig`:

```
SUPABASE_URL = https://YOUR_PROJECT.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_REPLACE_ME
```

Expose these values through Info.plist build settings or a generated configuration file. The publishable key is allowed in a mobile client, but every table must remain protected by RLS.

## 5. Seed the four-family pilot

Recommended onboarding sequence:

1. Kiran signs in first and creates the group as admin.
2. Create four pending memberships tied to the invited phone numbers.
3. Each parent signs in with OTP and claims only the matching pending membership.
4. Kiran approves the membership.
5. The authoritative calendar is inserted once by the admin. The database unique constraint rejects a second calendar for the same group, school, and academic year.
6. Each parent fills in morning-drop and afternoon-pickup weekday constraints.
7. Admin publishes the generated schedule.

## 6. Pilot distribution

Use TestFlight External Testing for Mohan, Pavan, and Santosh. Keep the tester group private and invite by email. Use a separate Supabase project for the pilot so test records never mix with a future production audience.

## 7. Push notifications

Local reminders can continue to run on-device. For shared events, deploy an Edge Function that reads an event/outbox row and sends APNs notifications using credentials stored as Supabase secrets. Do not store the APNs private key in the app or database tables.

## Recommended pilot gates

- maximum four approved parent accounts
- one group and one school
- no public group discovery
- calendar upload restricted to admin
- audit every trip-state transition
- keep “pilot time override” disabled on distributed builds
- collect TestFlight feedback for two school weeks before expanding
