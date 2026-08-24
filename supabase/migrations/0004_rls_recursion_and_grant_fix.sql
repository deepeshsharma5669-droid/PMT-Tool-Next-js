-- Fix for two bugs found during post-migration verification of 0003:
--
-- 1. Infinite RLS recursion: pmt_can_manage_stage() queried pmt_stages
--    without SECURITY DEFINER, so it was subject to pmt_stages' own RLS —
--    whose member-visibility policy queries pmt_tasks, whose
--    manager-visibility policy calls pmt_can_manage_stage() again.
--    Crashed with "stack depth limit exceeded" on the very first
--    anon-role read of pmt_tasks/pmt_users. Fixed by making the
--    cross-table lookup helpers SECURITY DEFINER (same justification as
--    pmt_current_user(): pure read-only identity/lookup, no parameters
--    that enable impersonation, pinned search_path), which bypasses the
--    callee tables' RLS and breaks the cycle — exactly the pattern
--    already used for pmt_current_user().
--
-- 2. pmt_create_notification()'s "REVOKE ALL ... FROM PUBLIC" did not
--    remove anon's EXECUTE privilege, because Supabase's default
--    privileges grant EXECUTE directly TO anon/authenticated on every new
--    function — a PUBLIC revoke doesn't touch a grant made directly to a
--    named role. Fixed with an explicit REVOKE naming anon.

begin;

create or replace function pmt_can_manage_stage(p_stage_id text) returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select pmt_is_admin() or exists (
    select 1 from pmt_stages s
    where s.id = p_stage_id and pmt_is_manager_of(s.dept)
  )
$$;

create or replace function pmt_deliverable_for_stage(p_stage_id text)
returns table (client_revision integer, status text)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select d.client_revision, d.status
  from pmt_stages s
  join pmt_deliverables d on d.id = s.deliverable_id
  where s.id = p_stage_id
$$;

revoke execute on function pmt_create_notification(text, text, text, text) from anon;

commit;
