# Cross-device owner-transfer hotfix

Two iPhones running the PWA without permanent sign-in receive different anonymous Supabase Auth UUIDs. Recovering the seeded Owner from one phone to another is therefore an identity transfer, not a second simultaneous Owner membership.

The transfer function creates the replacement Owner and removes the former Owner inside one transaction. The final schema enforces exactly one active Owner with a deferred constraint trigger so this temporary intermediate state is valid.

A deployment race can reintroduce the legacy immediate partial unique index:

1. Supabase GitHub integration applies migrations through `202608060026`.
2. A manual `supabase db push` concurrently begins replaying migration `202608060018`.
3. Migration 018 recreates `kcp_one_active_owner_per_group`.
4. The manual process then fails while inserting the already-existing migration-history row.
5. Migration history shows 026 as applied, but the obsolete immediate index remains in the live schema.

Migration `202608070001_kcp_owner_transfer_index_hotfix.sql` removes either an index or constraint with that legacy name, recreates the deferred invariant trigger, and fails if the immediate index remains.

For shared remote environments, use one migration deployment path at a time:

- Supabase GitHub integration, or
- manual `supabase db push`

Do not run both concurrently.

The current anonymous pilot transfers one parent identity between devices. To use the same parent concurrently on multiple phones, move that parent to a permanent Supabase identity such as email OTP, phone OTP, or Sign in with Apple so both devices can authenticate as the same user.
