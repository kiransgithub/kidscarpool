# Supabase migration lineage

KCP keeps two database artifacts for different purposes:

- `supabase/migrations/` contains the exact forward-only history used by the linked pilot project. Applied files are immutable.
- `supabase/baseline/` contains a consolidated schema for disposable local databases, CI bootstrap, and future new projects. It is never pushed to the existing linked project.

## Linked-project workflow

```bash
supabase migration list --linked
supabase db push --linked --dry-run
supabase db push --linked
```

Use only one deployment path at a time. Do not run a manual push while a Supabase GitHub deployment is applying migrations.

## Rules

1. Never edit, rename, or delete an applied migration.
2. Add every schema change as a new timestamped file under `supabase/migrations/`.
3. Back up the linked project before a production migration.
4. Run the fresh-database and linked-history CI checks before merging.
5. Never run `supabase db reset --linked` against the pilot or production project.

## Fresh database

CI applies `supabase/baseline/00000000000001_kcp_baseline.sql` directly to a disposable local Supabase database, then validates all forward migrations added after the baseline snapshot.
