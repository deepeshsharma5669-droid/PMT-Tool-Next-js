-- Phase: Security cleanup — remove the pre-existing anonymous SELECT
-- policy "Allow public read pmt_users" on public.pmt_users.
--
-- Live definition being removed (as confirmed by inspection, not present
-- in any of 0001-0009):
--   table:   public.pmt_users
--   policy:  Allow public read pmt_users
--   command: SELECT
--   roles:   anon
--   USING:   true
--
-- This granted unauthenticated (anon) callers unconditional SELECT on the
-- full pmt_users roster (id, name, email, role, dept, avatar, status,
-- auth_user_id) — the source-of-truth table every authorization check in
-- 0001-0009 derives identity from. It is not part of any tracked
-- migration and is not required by any legitimate flow: authenticated
-- read access for the roster is already covered by pmt_users_select_self
-- and pmt_users_select_active (0003), both scoped to `authenticated`.
--
-- SCOPE: this migration does exactly one thing — drop this single named
-- policy. Nothing else on pmt_users, no other table, no function, no
-- grant, no data.

begin;

drop policy if exists "Allow public read pmt_users"
on public.pmt_users;

commit;
