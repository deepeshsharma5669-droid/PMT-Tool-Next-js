-- Phase: Security cleanup — remove pre-existing permissive pmt_dev_* RLS
-- policies discovered post-0008-deployment review.
--
-- These policies predate 0001-0008 entirely — they were not created by any
-- tracked migration in this repository — and are reported as
-- USING(true)/WITH CHECK(true) for anon+authenticated (i.e. fully open,
-- unconditional read/write, no identity/department/status scoping at all)
-- on:
--   pmt_campaigns, pmt_clients, pmt_deliverables, pmt_reminders,
--   pmt_stages, pmt_tasks, pmt_users
--
-- Because Postgres RLS ORs together every PERMISSIVE policy that matches a
-- given command on a given table, a single leftover policy like this
-- silently defeats every restrictive policy 0001-0008 carefully built for
-- the same table/command — the department scoping in 0003, the
-- pmt_is_task_manager()/pmt_can_review_task() work in 0008, all of it,
-- would be moot on any table still carrying one of these: a permissive
-- USING(true) OR'd with a restrictive policy still evaluates to true.
--
-- SCOPE: this migration does exactly one thing — drop every RLS policy on
-- these seven tables whose name matches the pmt_dev_% pattern. Nothing
-- else. It does NOT touch:
--   - "Allow public read pmt_users" (explicitly out of scope per
--     instruction, pending separate review — see the report accompanying
--     this migration for why: it does not match the pmt_dev_% pattern and
--     is not present in any 0001-0008 migration file either, so it needs
--     its own dedicated investigation before any action is taken on it)
--   - any pmt_* policy created by 0001-0008 (pmt_users_select_self,
--     pmt_tasks_select_manager, pmt_stages_update_manager, etc.)
--   - any policy on any table not in the list above
--   - any function, trigger, grant, or table structure
--
-- MECHANISM: the DROP is driven by a live pg_policies catalog query at
-- apply time, not a hand-typed list of guessed policy names. This is
-- deliberate — a hand-typed `drop policy if exists <guessed-name>` that
-- doesn't exactly match the policy's REAL name silently no-ops (IF EXISTS
-- swallows the "policy doesn't exist" case with no error), which would
-- leave the dangerous fully-open policy in place while the migration
-- appears to have succeeded. Matching by pattern against the live catalog
-- removes that failure mode entirely: whatever the exact pmt_dev_*
-- policies are actually named, this finds and drops precisely those and
-- nothing else. It is also naturally idempotent — safe to re-run, and a
-- no-op (with a NOTICE saying so) on any table where no such policy exists.

begin;

do $$
declare
  v_pol record;
  v_count int := 0;
begin
  for v_pol in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'pmt_campaigns', 'pmt_clients', 'pmt_deliverables', 'pmt_reminders',
        'pmt_stages', 'pmt_tasks', 'pmt_users'
      )
      and policyname like 'pmt\_dev\_%' escape '\'
    order by tablename, policyname
  loop
    execute format('drop policy if exists %I on %I.%I', v_pol.policyname, v_pol.schemaname, v_pol.tablename);
    raise notice 'Dropped dev policy: % on %.%', v_pol.policyname, v_pol.schemaname, v_pol.tablename;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise notice 'No pmt_dev_* policies found on the seven target tables — either already clean, or the live names do not actually start with the pmt_dev_ prefix and need manual review before assuming this migration accomplished anything.';
  else
    raise notice 'Dropped % pmt_dev_* polic(y/ies) total across the seven target tables.', v_count;
  end if;
end $$;

commit;
