# Canonical PMT migrations

This directory contains the migration chain for the new canonical PMT Supabase project.

- Migrations here must bootstrap an empty Supabase database.
- The legacy/prototype history is archived in `supabase/legacy-migrations/`.
- Never copy legacy migrations back into this directory or apply them to the canonical project.
- Apply migrations only through an explicitly reviewed deployment step. Nothing in this repository task was applied remotely.

The baseline intentionally enables row-level security without adding policies. Canonical workflow functions, grants, and role-aware RLS policies belong in separately reviewed follow-up migrations.