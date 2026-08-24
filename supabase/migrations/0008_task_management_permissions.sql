-- Phase: Task Management Permission Model + Manager Self-Assignment.
--
-- Introduces the authoritative task-management authorization model:
--   ADMIN   = governance + oversight + audit (read/audit only on tasks)
--   MANAGER = day-to-day task planning and management for their OWN department
--   MEMBER  = task execution + submission
--
-- This migration deliberately does NOT touch pmt_can_manage_stage() (still
-- used, unchanged, by the Client Decision RPCs — pmt_record_client_approval
-- / pmt_record_client_changes — whose Admin governance authority is
-- explicitly preserved), the Stage Gate/Rework model from 0007, the Client
-- Revision model, Auth/registration, or any unrelated table.
--
-- REVISION 2 (this version) hardens the first draft after security review.
-- Three substantive changes from the original draft:
--
--   A. TASK UPDATE INTEGRITY. The original draft still granted a
--      same-department Manager row-level RLS access to run an ARBITRARY
--      raw `UPDATE pmt_tasks SET ...` (any column: client_revision,
--      is_client_change, iteration, created_at, started_at, submitted_at,
--      approved_at, feedback, stage_id, assignee_id, ...) as long as the
--      row belonged to their department — RLS only ever scoped ROWS, never
--      COLUMNS. That is a real integrity hole: client_revision/
--      is_client_change are load-bearing for the Stage Gate (0007) — a
--      Manager could corrupt gate calculation with a raw column edit that
--      never goes near pmt_create_change_tasks' validation.
--
--      Fix: pmt_tasks, pmt_submissions, and pmt_submission_options now have
--      INSERT/UPDATE/DELETE revoked from anon AND authenticated at the
--      table-privilege level (section 9). This is a stronger guarantee
--      than column-level GRANT UPDATE(col,...) allow-listing: a privilege
--      check fails BEFORE Postgres even consults RLS, and there is no
--      column list to keep in sync as the schema evolves — every mutation
--      MUST go through a named function that is independently reviewable.
--      Every function that mutates these three tables is therefore now
--      SECURITY DEFINER with a pinned search_path (section 3-7) — table
--      privilege checks inside a SECURITY DEFINER function's body run as
--      the function's OWNER (who has full table rights, being also the
--      table owner), not the original caller, so the RPCs keep working
--      while the direct-Supabase path is now flatly impossible, not just
--      RLS-denied. All mutation RLS policies made unreachable by this are
--      dropped, not left dangling (section 8) — dead policies that look
--      like they still apply are worse than removing them.
--
--   B. pmt_can_review_task() now ALSO requires task.status = 'IN_REVIEW'
--      (section 2). It previously answered "is this Manager authorized to
--      review this task's DEPARTMENT/ASSIGNMENT", relying on each call
--      site to separately check status. It now answers the full question —
--      "is this Manager authorized to review this task RIGHT NOW" — so it
--      is a complete, self-sufficient authorization predicate wherever
--      it's used (the review RPCs, and the pmt_tasks transition trigger).
--
--   C. EXPLICIT PRIVILEGE HARDENING (section 10). Every function
--      introduced/redefined by this migration gets an explicit
--      revoke-from-public + revoke-from-anon + (for the 12 functions the
--      application actually calls) grant-to-authenticated sequence,
--      matching the established pattern for pmt_create_notification()
--      (0003/0004). The 3 pure helper functions and the trigger function
--      are revoked from BOTH anon and authenticated — they are called only
--      from inside other SECURITY DEFINER functions (which run as the
--      shared owner regardless of the original caller's own grants), never
--      directly by the application, so they are true internal-only helpers.
--
-- Summary of what changes (full list):
--   1. New task-specific authorization helper: pmt_is_task_manager(stage_id)
--      — true only for an ACTIVE Manager of that stage's OWN department.
--      Admin always false (unlike pmt_can_manage_stage()).
--   2. New review authorization helper: pmt_can_review_task(task_id) — same-
--      department Manager, task.status = 'IN_REVIEW', with the self-review
--      rule resolved from the database.
--   3. New assignee-validation helper: pmt_validate_task_assignee() —
--      server-derived; never trusts an arbitrary assignee_id.
--   4. pmt_validate_task_transition() trigger: the blanket Admin bypass is
--      REMOVED, a Manager-as-executor branch is added for self-assignment,
--      and Manager-as-reviewer transitions route through pmt_can_review_task().
--   5. pmt_create_task / pmt_reorder_tasks / pmt_create_change_tasks
--      authorize via pmt_is_task_manager() instead of pmt_can_manage_stage().
--   6. Three new dedicated RPCs: pmt_assign_task, pmt_update_task,
--      pmt_change_deadline — Manager-only, department-scoped, workflow-lock
--      aware.
--   7. pmt_start_task / pmt_submit_task_for_review accept an ACTIVE Manager
--      acting as their own task's assignee (Manager self-execution).
--   8. pmt_approve_submission_option / pmt_request_submission_changes /
--      pmt_reject_all_submission_options authorize via pmt_can_review_task().
--   9. RLS + table privileges: see (A) above — pmt_tasks/pmt_submissions/
--      pmt_submission_options mutation is exclusively through SECURITY
--      DEFINER RPCs now; all now-unreachable mutation RLS policies dropped.
--  10. pmt_change_deliverable_type() is SECURITY DEFINER: the ONLY
--      surviving path that can delete a pmt_tasks/pmt_stages row — never
--      accepts a task/stage id, only a deliverable id, and always
--      re-derives + re-checks "no production history exists" and "caller
--      is Admin" before deleting anything. NOT a general-purpose Admin
--      delete grant.
--  11. Explicit EXECUTE privilege hardening for every function this
--      migration introduces or redefines — see (C) above.

begin;

-- =========================================================================
-- 1. TASK-SPECIFIC AUTHORIZATION HELPERS
-- =========================================================================

-- Task-management authorization for a given Stage. Unlike
-- pmt_can_manage_stage() (still used, unchanged, for Client Decision /
-- general stage governance), this NEVER returns true for Admin — normal
-- task CRUD is exclusively the owning department Manager's authority.
-- SECURITY DEFINER + pinned search_path, matching pmt_can_manage_stage()'s
-- own fix in 0004 (bypasses pmt_stages' RLS to avoid the same recursion
-- class of bug; pure read-only lookup, no impersonation surface).
--
-- INTERNAL ONLY as of this revision: called exclusively from within other
-- SECURITY DEFINER functions below (never from an RLS policy — the
-- policies that used to call it are dropped in section 8) — see the
-- EXECUTE privilege hardening in section 10, which revokes this from both
-- anon and authenticated.
create or replace function pmt_is_task_manager(p_stage_id text) returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from pmt_stages s
    where s.id = p_stage_id and pmt_is_manager_of(s.dept)
  )
$$;

-- Submission-review authorization for a given Task: "is this Manager
-- authorized to review this task RIGHT NOW". Requires the caller to be an
-- ACTIVE Manager of the task's Stage's own department, the task to
-- actually be IN_REVIEW, and — only when the caller is ALSO the task's
-- assignee — that no OTHER ACTIVE Manager exists in that department
-- (otherwise that other Manager must review instead). Computed entirely
-- from the database; never accepts a client-supplied flag.
--
-- The task.status = 'IN_REVIEW' condition makes this a COMPLETE,
-- self-sufficient authorization predicate — every call site (the three
-- review RPCs, the pmt_tasks transition trigger) can rely on it alone
-- rather than separately re-checking status.
--
-- INTERNAL ONLY: same EXECUTE treatment as pmt_is_task_manager() above.
create or replace function pmt_can_review_task(p_task_id text) returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from pmt_tasks t
    join pmt_stages s on s.id = t.stage_id
    where t.id = p_task_id
      and t.status = 'IN_REVIEW'
      and pmt_is_manager_of(s.dept)
      and (
        t.assignee_id is distinct from pmt_current_pmt_id()
        or not exists (
          select 1 from pmt_users u2
          where u2.role = 'MANAGER'
            and u2.status = 'ACTIVE'
            and u2.dept = s.dept
            and u2.id <> pmt_current_pmt_id()
        )
      )
  )
$$;

-- Server-derived assignee validation, shared by every task-creation/
-- assignment RPC below. Never trusts the browser: re-reads the assignee's
-- current status/role/dept from pmt_users and the target Stage's dept from
-- pmt_stages. A Manager may legitimately be the assignee (self-assignment)
-- — this deliberately does NOT require assignee.role = 'MEMBER'.
--
-- INTERNAL ONLY: same EXECUTE treatment as pmt_is_task_manager() above.
create or replace function pmt_validate_task_assignee(p_stage_id text, p_assignee_id text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dept text;
  v_assignee pmt_users%rowtype;
begin
  if p_assignee_id is null then
    return;
  end if;

  select dept into v_dept from pmt_stages where id = p_stage_id;
  if v_dept is null then
    raise exception 'Stage not found.';
  end if;

  select * into v_assignee from pmt_users where id = p_assignee_id;
  if not found then
    raise exception 'Assignee is not a valid PMT user.';
  end if;
  if v_assignee.status <> 'ACTIVE' then
    raise exception 'Assignee must be an ACTIVE user.';
  end if;
  if v_assignee.role not in ('MEMBER', 'MANAGER') then
    raise exception 'Task assignee must be a Member or Manager.';
  end if;
  if v_assignee.dept is distinct from v_dept then
    raise exception 'Assignee must belong to the Stage''s department.';
  end if;
end;
$$;

-- =========================================================================
-- 2. TRANSITION-VALIDATION TRIGGER: remove Admin bypass, add Manager
--    self-execution, route Manager review through pmt_can_review_task()
-- =========================================================================

create or replace function pmt_validate_task_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := pmt_current_role();
  v_actor text := pmt_current_pmt_id();
begin
  if old.status = new.status then
    -- Metadata-only edit (title/description/assignee_id/deadline/task_order).
    -- Admin gets NO bypass here (unlike the pre-0008 version): normal
    -- task-management mutation authority belongs exclusively to the
    -- department Manager. This branch is now defense-in-depth on top of
    -- section 9's table-privilege revoke — every real caller reaching this
    -- point is already inside a SECURITY DEFINER RPC that ran its own
    -- pmt_is_task_manager() check before issuing the UPDATE.
    if pmt_is_task_manager(old.stage_id) then
      return new;
    end if;
    raise exception 'Not authorized to edit this task.';
  end if;

  if v_role = 'MEMBER' then
    if new.assignee_id is distinct from old.assignee_id then
      raise exception 'Members cannot reassign tasks.';
    end if;
    if not (
      (old.status in ('TODO', 'CHANGES_REQUIRED') and new.status = 'IN_PROGRESS')
      or (
        old.status = 'IN_PROGRESS' and new.status = 'IN_REVIEW'
        and exists (select 1 from pmt_submissions s where s.task_id = new.id)
      )
    ) then
      raise exception 'Invalid task status transition for Member: % -> %', old.status, new.status;
    end if;

  elsif v_role = 'MANAGER' then
    -- Manager acting as the task's own executor (self-assignment): the
    -- exact same TODO/CHANGES_REQUIRED -> IN_PROGRESS -> IN_REVIEW lifecycle
    -- as a Member, scoped to a task they are themselves assigned to.
    if old.assignee_id = v_actor and new.assignee_id = v_actor
       and (
         (old.status in ('TODO', 'CHANGES_REQUIRED') and new.status = 'IN_PROGRESS')
         or (
           old.status = 'IN_PROGRESS' and new.status = 'IN_REVIEW'
           and exists (select 1 from pmt_submissions s where s.task_id = new.id)
         )
       )
    then
      return new;
    end if;

    -- Manager acting as reviewer (of another user's task, or of their own
    -- self-assigned task when no other ACTIVE same-department Manager
    -- exists). pmt_can_review_task() resolves BOTH the self-review rule
    -- AND the IN_REVIEW status requirement from the database — this is the
    -- authoritative backstop even if a caller reaches pmt_tasks with an
    -- UPDATE issued from inside a trusted SECURITY DEFINER context.
    if old.status = 'IN_REVIEW' and new.status in ('APPROVED', 'CHANGES_REQUIRED') then
      if not pmt_can_review_task(old.id) then
        raise exception 'Another active Manager in your department must review this task.';
      end if;
      return new;
    end if;

    raise exception 'Invalid task status transition for Manager: % -> %', old.status, new.status;

  else
    raise exception 'Not authorized to change task status.';
  end if;

  return new;
end;
$$;

-- =========================================================================
-- 3. TASK-MANAGEMENT RPCs: pmt_is_task_manager() authorization (removes
--    Admin authority), assignee validation, SECURITY DEFINER (table
--    privilege is revoked from anon/authenticated in section 9 — these
--    RPCs are the only remaining path that can write to pmt_tasks)
-- =========================================================================

create or replace function pmt_create_task(
  p_stage_id text, p_title text, p_description text, p_assignee_id text, p_deadline date
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_task_id text;
  v_order int;
begin
  if not pmt_is_task_manager(p_stage_id) then
    raise exception 'Not authorized to create tasks in this stage''s department.';
  end if;
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'Task title is required.';
  end if;

  perform pmt_validate_task_assignee(p_stage_id, p_assignee_id);

  select coalesce(max(task_order), 0) + 1 into v_order from pmt_tasks where stage_id = p_stage_id and status <> 'APPROVED';

  v_task_id := gen_random_uuid()::text;
  insert into pmt_tasks (id, stage_id, title, description, assignee_id, deadline, status, task_order, iteration, client_revision, is_client_change, created_at)
  values (v_task_id, p_stage_id, p_title, p_description, p_assignee_id, p_deadline, 'TODO', v_order, 1, null, false, now());

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', v_task_id, 'Created normal task', v_actor);

  if p_assignee_id is not null then
    perform pmt_create_notification(p_assignee_id, 'TASK_ASSIGNED', 'You were assigned a task: ' || p_title, null);
  end if;

  return v_task_id;
end;
$$;

create or replace function pmt_reorder_tasks(p_stage_id text, p_dragged_task_id text, p_target_task_id text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_ids text[];
  v_dragged_idx int;
  v_target_idx int;
  v_id text;
  v_i int := 0;
begin
  if not pmt_is_task_manager(p_stage_id) then
    raise exception 'Not authorized to reorder tasks in this stage''s department.';
  end if;

  select array_agg(id order by task_order) into v_ids
    from pmt_tasks where stage_id = p_stage_id and status not in ('APPROVED', 'IN_REVIEW');

  v_dragged_idx := array_position(v_ids, p_dragged_task_id);
  v_target_idx := array_position(v_ids, p_target_task_id);
  if v_dragged_idx is null or v_target_idx is null then
    raise exception 'Both tasks must be in the reorderable (non-APPROVED, non-IN_REVIEW) set.';
  end if;

  v_ids := array_remove(v_ids[1:greatest(v_dragged_idx-1,0)] || v_ids[v_dragged_idx+1:array_length(v_ids,1)], null);
  v_ids := v_ids[1:v_target_idx-1] || p_dragged_task_id || v_ids[v_target_idx:array_length(v_ids,1)];

  foreach v_id in array v_ids loop
    v_i := v_i + 1;
    update pmt_tasks set task_order = v_i where id = v_id;
  end loop;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'STAGE', p_stage_id, 'Reordered tasks', v_actor);
end;
$$;

create or replace function pmt_create_change_tasks(p_stage_id text, p_tasks jsonb)
returns text[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage pmt_stages%rowtype;
  v_deliverable pmt_deliverables%rowtype;
  v_task jsonb;
  v_next_order int;
  v_task_id text;
  v_ids text[] := '{}';
begin
  if not pmt_is_task_manager(p_stage_id) then
    raise exception 'Not authorized to create Change Tasks in this stage''s department.';
  end if;

  select * into v_stage from pmt_stages where id = p_stage_id;
  select * into v_deliverable from pmt_deliverables where id = v_stage.deliverable_id;

  if v_deliverable.client_revision = 0 or v_deliverable.status <> 'CHANGES_REQUESTED' then
    raise exception 'Change Tasks can only be created during an active Client Changes cycle.';
  end if;
  if jsonb_array_length(p_tasks) = 0 then
    raise exception 'Add at least one Change Task.';
  end if;

  select coalesce(max(task_order), 0) into v_next_order from pmt_tasks where stage_id = p_stage_id;

  for v_task in select * from jsonb_array_elements(p_tasks)
  loop
    if v_task->>'title' is null or length(trim(v_task->>'title')) = 0
       or v_task->>'assignee_id' is null or v_task->>'deadline' is null then
      raise exception 'Every Change Task needs a title, assignee, and deadline.';
    end if;

    perform pmt_validate_task_assignee(p_stage_id, v_task->>'assignee_id');

    v_next_order := v_next_order + 1;
    v_task_id := gen_random_uuid()::text;
    insert into pmt_tasks (id, stage_id, title, description, assignee_id, deadline, status, task_order, iteration, client_revision, is_client_change, created_at)
    values (
      v_task_id, p_stage_id, v_task->>'title', v_task->>'description', v_task->>'assignee_id',
      (v_task->>'deadline')::date, 'CHANGES_REQUIRED', v_next_order, 1, v_deliverable.client_revision, true, now()
    );
    v_ids := v_ids || v_task_id;

    insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
    values (gen_random_uuid()::text, 'TASK', v_task_id, 'Created change task ' || (v_task->>'title') || ' (Revision ' || v_deliverable.client_revision || ')', pmt_current_pmt_id());
    perform pmt_create_notification(v_task->>'assignee_id', 'TASK_ASSIGNED', 'You were assigned a Client Change task: ' || (v_task->>'title'), null);
  end loop;

  update pmt_stages set rework_pending = true where id = p_stage_id;

  return v_ids;
end;
$$;

-- =========================================================================
-- 4. NEW DEDICATED TASK-EDITING RPCs (Manager-only, department-scoped,
--    workflow-lock aware, SECURITY DEFINER)
-- =========================================================================

create or replace function pmt_assign_task(p_task_id text, p_assignee_id text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_task pmt_tasks%rowtype;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not pmt_is_task_manager(v_task.stage_id) then
    raise exception 'Not authorized to assign tasks in this stage''s department.';
  end if;
  if v_task.status in ('APPROVED', 'IN_REVIEW') then
    raise exception 'Task is locked and cannot be reassigned (status: %).', v_task.status;
  end if;
  if p_assignee_id is null then
    raise exception 'An assignee is required.';
  end if;

  perform pmt_validate_task_assignee(v_task.stage_id, p_assignee_id);

  update pmt_tasks set assignee_id = p_assignee_id where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Reassigned task', v_actor);

  perform pmt_create_notification(p_assignee_id, 'TASK_ASSIGNED', 'You were assigned a task: ' || v_task.title, null);
end;
$$;

create or replace function pmt_update_task(p_task_id text, p_title text, p_description text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_task pmt_tasks%rowtype;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not pmt_is_task_manager(v_task.stage_id) then
    raise exception 'Not authorized to edit tasks in this stage''s department.';
  end if;
  if v_task.status in ('APPROVED', 'IN_REVIEW') then
    raise exception 'Task is locked and cannot be edited (status: %).', v_task.status;
  end if;
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'Task title is required.';
  end if;

  update pmt_tasks set title = p_title, description = p_description where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Edited task details', v_actor);
end;
$$;

create or replace function pmt_change_deadline(p_task_id text, p_deadline date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_task pmt_tasks%rowtype;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not pmt_is_task_manager(v_task.stage_id) then
    raise exception 'Not authorized to change deadlines in this stage''s department.';
  end if;
  if v_task.status in ('APPROVED', 'IN_REVIEW') then
    raise exception 'Task is locked and its deadline cannot be changed (status: %).', v_task.status;
  end if;
  if p_deadline is null then
    raise exception 'A valid deadline is required.';
  end if;

  update pmt_tasks set deadline = p_deadline where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'DEADLINE_CHANGED', v_actor);
end;
$$;

-- =========================================================================
-- 5. TASK EXECUTION: allow an ACTIVE Manager acting as their own task's
--    assignee (Manager self-execution) — never broadens Member's own
--    permissions, never lets a Manager execute someone ELSE's task, and
--    never grants Admin execution rights. SECURITY DEFINER (table
--    privilege revoked from anon/authenticated in section 9).
-- =========================================================================

create or replace function pmt_start_task(p_task_id text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task pmt_tasks%rowtype;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not (
    pmt_is_active()
    and pmt_current_role() in ('MEMBER', 'MANAGER')
    and v_task.assignee_id = pmt_current_pmt_id()
  ) then
    raise exception 'You can only work on tasks assigned to you.';
  end if;
  if v_task.status not in ('TODO', 'CHANGES_REQUIRED') then
    raise exception 'Task is not in a state that can be started (current status: %).', v_task.status;
  end if;

  update pmt_tasks set status = 'IN_PROGRESS', started_at = now() where id = p_task_id;
  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Task started', pmt_current_pmt_id());
end;
$$;

create or replace function pmt_submit_task_for_review(p_task_id text, p_note text, p_options jsonb)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task pmt_tasks%rowtype;
  v_stage pmt_stages%rowtype;
  v_submission_id text;
  v_option jsonb;
  v_i int := 0;
  v_valid_count int := 0;
  v_mgr record;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not (
    pmt_is_active()
    and pmt_current_role() in ('MEMBER', 'MANAGER')
    and v_task.assignee_id = pmt_current_pmt_id()
  ) then
    raise exception 'You can only submit work on tasks assigned to you.';
  end if;
  if v_task.status <> 'IN_PROGRESS' then
    raise exception 'Task must be In Progress to submit for review (current status: %).', v_task.status;
  end if;

  select count(*) into v_valid_count from jsonb_array_elements(p_options) o where length(trim(o->>'link')) > 0;
  if v_valid_count = 0 then
    raise exception 'Add at least one option with a file link.';
  end if;

  v_submission_id := gen_random_uuid()::text;
  insert into pmt_submissions (id, task_id, submitted_by, note, submitted_at)
  values (v_submission_id, p_task_id, pmt_current_pmt_id(), nullif(trim(p_note), ''), now());

  for v_option in select * from jsonb_array_elements(p_options)
  loop
    if length(trim(v_option->>'link')) = 0 then continue; end if;
    v_i := v_i + 1;
    insert into pmt_submission_options (id, submission_id, name, link, note, decision)
    values (
      gen_random_uuid()::text, v_submission_id,
      coalesce(nullif(trim(v_option->>'name'), ''), 'Option ' || v_i),
      trim(v_option->>'link'), nullif(trim(v_option->>'note'), ''), 'PENDING'
    );
  end loop;

  update pmt_tasks set status = 'IN_REVIEW', submitted_at = now() where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Submitted task for review', pmt_current_pmt_id());

  select * into v_stage from pmt_stages where id = v_task.stage_id;
  for v_mgr in
    select id from pmt_users
    where role = 'MANAGER' and dept = v_stage.dept and status = 'ACTIVE' and id <> pmt_current_pmt_id()
  loop
    perform pmt_create_notification(v_mgr.id, 'SUBMISSION_RECEIVED', 'A submission is ready for your review.', null);
  end loop;

  return v_submission_id;
end;
$$;

-- =========================================================================
-- 6. VARIANT REVIEW: authorize via pmt_can_review_task() — removes
--    Admin's implicit review authority and enforces the self-review +
--    IN_REVIEW rules together, at the RPC layer. Status is checked FIRST
--    (for a specific, distinct error message) before the authorization
--    check, even though pmt_can_review_task() would also reject a
--    non-IN_REVIEW task — this ordering only affects which exception
--    message is raised, not what is ultimately allowed. SECURITY DEFINER
--    (table privilege revoked from anon/authenticated in section 9).
-- =========================================================================

create or replace function pmt_approve_submission_option(
  p_task_id text, p_selected_option_ids text[], p_manager_feedback text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task pmt_tasks%rowtype;
  v_submission_id text;
  v_selected_count int;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if v_task.status <> 'IN_REVIEW' then
    raise exception 'This task is not currently awaiting review.';
  end if;
  if not pmt_can_review_task(p_task_id) then
    raise exception 'You are not authorized to review this submission (outside your department, or another active Manager in your department must review your own submitted work).';
  end if;

  select id into v_submission_id from pmt_submissions where task_id = p_task_id order by submitted_at desc limit 1;
  if v_submission_id is null then raise exception 'No submission found for this task.'; end if;

  select count(*) into v_selected_count from unnest(p_selected_option_ids);
  if v_selected_count = 0 then
    raise exception 'Select at least one option to approve.';
  end if;

  update pmt_submission_options
  set decision = case when id = any(p_selected_option_ids) then 'SELECTED' else 'REJECTED' end
  where submission_id = v_submission_id;

  update pmt_submissions set decision_type = 'APPROVED', manager_feedback = nullif(trim(p_manager_feedback), '')
  where id = v_submission_id;

  update pmt_tasks set status = 'APPROVED', approved_at = now(), feedback = nullif(trim(p_manager_feedback), '')
  where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Approved submission', pmt_current_pmt_id());
  perform pmt_create_notification(v_task.assignee_id, 'TASK_APPROVED', 'Your submission was approved.', null);

  perform pmt_apply_stage_gate(v_task.stage_id);
end;
$$;

create or replace function pmt_request_submission_changes(
  p_task_id text, p_manager_feedback text, p_selected_option_ids text[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task pmt_tasks%rowtype;
  v_submission_id text;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if v_task.status <> 'IN_REVIEW' then
    raise exception 'This task is not currently awaiting review.';
  end if;
  if not pmt_can_review_task(p_task_id) then
    raise exception 'You are not authorized to review this submission (outside your department, or another active Manager in your department must review your own submitted work).';
  end if;
  if p_manager_feedback is null or length(trim(p_manager_feedback)) = 0 then
    raise exception 'Feedback is required to request changes.';
  end if;

  select id into v_submission_id from pmt_submissions where task_id = p_task_id order by submitted_at desc limit 1;
  if v_submission_id is null then raise exception 'No submission found for this task.'; end if;

  update pmt_submission_options
  set decision = case when id = any(p_selected_option_ids) then 'SELECTED' else 'REJECTED' end
  where submission_id = v_submission_id;

  update pmt_submissions set decision_type = 'CHANGES_REQUESTED', manager_feedback = trim(p_manager_feedback)
  where id = v_submission_id;

  update pmt_tasks set status = 'CHANGES_REQUIRED', feedback = trim(p_manager_feedback), iteration = coalesce(iteration, 1) + 1
  where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Requested changes on submission', pmt_current_pmt_id());
  perform pmt_create_notification(v_task.assignee_id, 'CHANGES_REQUESTED', 'Changes were requested for your task.', null);
end;
$$;

create or replace function pmt_reject_all_submission_options(p_task_id text, p_manager_feedback text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task pmt_tasks%rowtype;
  v_submission_id text;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if v_task.status <> 'IN_REVIEW' then
    raise exception 'This task is not currently awaiting review.';
  end if;
  if not pmt_can_review_task(p_task_id) then
    raise exception 'You are not authorized to review this submission (outside your department, or another active Manager in your department must review your own submitted work).';
  end if;
  if p_manager_feedback is null or length(trim(p_manager_feedback)) = 0 then
    raise exception 'Feedback is required to reject all options.';
  end if;

  select id into v_submission_id from pmt_submissions where task_id = p_task_id order by submitted_at desc limit 1;
  if v_submission_id is null then raise exception 'No submission found for this task.'; end if;

  update pmt_submission_options set decision = 'REJECTED' where submission_id = v_submission_id;
  update pmt_submissions set decision_type = 'REJECTED_ALL', manager_feedback = trim(p_manager_feedback) where id = v_submission_id;
  update pmt_tasks set status = 'CHANGES_REQUIRED', feedback = trim(p_manager_feedback), iteration = coalesce(iteration, 1) + 1
  where id = p_task_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'TASK', p_task_id, 'Rejected all options', pmt_current_pmt_id());
  perform pmt_create_notification(v_task.assignee_id, 'CHANGES_REQUESTED', 'All options were rejected for your task.', null);
end;
$$;

-- =========================================================================
-- 7. PRE-PRODUCTION DELIVERABLE TYPE REBUILD: narrowly-scoped SECURITY
--    DEFINER path — the only surviving way any pmt_tasks/pmt_stages row
--    can be deleted. Never accepts a task/stage id; only a deliverable id.
--    Re-derives + re-checks "caller is Admin" and "no production history
--    exists" from the database on every call, then deletes ONLY the rows
--    scoped to that deliverable's own (pre-production) stages/tasks. This
--    is NOT a general-purpose Admin delete grant.
-- =========================================================================

create or replace function pmt_change_deliverable_type(p_deliverable_id text, p_new_type text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_deliverable pmt_deliverables%rowtype;
  v_has_history boolean;
  v_stage_def jsonb;
  v_order int := 0;
begin
  if not pmt_is_admin() then
    raise exception 'Only an Admin may change a Deliverable''s type.';
  end if;

  select * into v_deliverable from pmt_deliverables where id = p_deliverable_id;
  if not found then
    raise exception 'Deliverable not found.';
  end if;

  select
    v_deliverable.client_revision > 0
    or exists (select 1 from pmt_deliverable_feedback where deliverable_id = p_deliverable_id)
    or exists (
      select 1 from pmt_tasks t
      join pmt_stages s on s.id = t.stage_id
      where s.deliverable_id = p_deliverable_id
        and (t.status <> 'TODO' or exists (select 1 from pmt_submissions sub where sub.task_id = t.id))
    )
  into v_has_history;

  if v_has_history then
    raise exception 'Deliverable type cannot be changed after production has started.';
  end if;

  if p_new_type = v_deliverable.type then
    return; -- no-op
  end if;

  delete from pmt_tasks where stage_id in (select id from pmt_stages where deliverable_id = p_deliverable_id);
  delete from pmt_stages where deliverable_id = p_deliverable_id;

  update pmt_deliverables set type = p_new_type, client_revision = 0, status = 'IN_PROGRESS' where id = p_deliverable_id;

  for v_stage_def in
    select * from jsonb_array_elements(
      case p_new_type
        when 'Static Poster' then '[{"name":"Content Strategy","dept":"Content"},{"name":"Visual Design","dept":"Design"}]'
        when 'Instagram Carousel' then '[{"name":"Copywriting","dept":"Content"},{"name":"Layout Design","dept":"Design"}]'
        when 'Instagram Reel' then '[{"name":"Scripting","dept":"Content"},{"name":"Storyboarding","dept":"Design"},{"name":"Animation","dept":"Animation"}]'
        when 'Presentation' then '[{"name":"Content Drafting","dept":"Content"},{"name":"Slide Design","dept":"Design"}]'
        else '[{"name":"Content Strategy","dept":"Content"},{"name":"Visual Design","dept":"Design"}]'
      end::jsonb
    )
  loop
    v_order := v_order + 1;
    insert into pmt_stages (id, deliverable_id, name, dept, stage_order, status, rework_pending)
    values (gen_random_uuid()::text, p_deliverable_id, v_stage_def->>'name', v_stage_def->>'dept', v_order,
            case when v_order = 1 then 'ACTIVE' else 'PENDING' end, false);
  end loop;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'DELIVERABLE', p_deliverable_id, 'Changed type to ' || p_new_type || ' — workflow rebuilt', v_actor);
end;
$$;

-- =========================================================================
-- 8. RLS: drop every mutation policy on pmt_tasks / pmt_submissions /
--    pmt_submission_options that section 9 makes permanently unreachable.
--    Dead policies that look like they still apply are worse than removing
--    them — mutation authority for all three tables now lives exclusively
--    in the SECURITY DEFINER RPCs above. SELECT policies are UNCHANGED and
--    UNTOUCHED (pmt_tasks_select_admin/manager/member,
--    pmt_submissions_select, pmt_submission_options_select) — reads still
--    go through the normal client path and remain RLS-governed.
-- =========================================================================

-- pmt_tasks: no INSERT/UPDATE/DELETE policy of any kind survives this
-- migration. (pmt_tasks_update_admin and pmt_tasks_delete_admin were
-- already dropped with no replacement in the first draft of this
-- migration; pmt_tasks_insert/update_manager were recreated narrower in
-- that draft, and are now dropped outright; pmt_tasks_update_member — the
-- Member/self-assigned-Manager execution policy — is also dropped, since
-- pmt_start_task/pmt_submit_task_for_review are SECURITY DEFINER and no
-- longer need row-level UPDATE granted to the caller at all.)
drop policy if exists pmt_tasks_insert on pmt_tasks;
drop policy if exists pmt_tasks_update_manager on pmt_tasks;
drop policy if exists pmt_tasks_update_admin on pmt_tasks;
drop policy if exists pmt_tasks_update_member on pmt_tasks;
drop policy if exists pmt_tasks_delete_admin on pmt_tasks;

-- pmt_submissions / pmt_submission_options: same treatment. Member
-- submission creation now happens exclusively inside the SECURITY DEFINER
-- pmt_submit_task_for_review(); Manager review decisions exclusively
-- inside the SECURITY DEFINER review RPCs above.
drop policy if exists pmt_submissions_insert_member on pmt_submissions;
drop policy if exists pmt_submissions_update_manager on pmt_submissions;
drop policy if exists pmt_submissions_admin on pmt_submissions;

drop policy if exists pmt_submission_options_insert_member on pmt_submission_options;
drop policy if exists pmt_submission_options_update_manager on pmt_submission_options;
drop policy if exists pmt_submission_options_admin on pmt_submission_options;

-- =========================================================================
-- 9. TABLE-LEVEL PRIVILEGE REVOCATION: the actual enforcement mechanism
--    behind section 8. Once these are revoked, a raw Supabase
--    `.from('pmt_tasks').update(...)` (or insert/delete, and same for the
--    other two tables) fails with a privilege error BEFORE Postgres even
--    evaluates RLS — no column, however sensitive (client_revision,
--    is_client_change, iteration, created_at, started_at, submitted_at,
--    approved_at, feedback, stage_id, assignee_id, or any future column),
--    is reachable via direct mutation, by ANY role, under ANY RLS policy,
--    because there is no longer any RLS policy to evaluate in the first
--    place for these commands. SELECT is deliberately NOT revoked — reads
--    remain on the normal RLS-governed client path.
-- =========================================================================

revoke insert, update, delete on pmt_tasks from anon, authenticated;
revoke insert, update, delete on pmt_submissions from anon, authenticated;
revoke insert, update, delete on pmt_submission_options from anon, authenticated;

-- =========================================================================
-- 10. EXECUTE PRIVILEGE HARDENING for every function this migration
--     introduces or redefines. Pattern matches pmt_create_notification()
--     in 0003/0004: revoke from PUBLIC (catches any privilege NOT granted
--     directly to a named role), then explicitly revoke from anon (a
--     PUBLIC revoke does not remove a grant Supabase's defaults made
--     directly TO anon on function creation), then grant back to
--     authenticated ONLY for the functions actually intended to be called
--     directly by the application.
--
--     Three helper functions + the trigger function are INTERNAL ONLY:
--     revoked from BOTH anon and authenticated. They are never called
--     directly via `.rpc(...)` anywhere in app/actions/*.ts — only from
--     inside the SECURITY DEFINER functions below, where the nested call
--     runs under the (shared) function owner's own privileges regardless
--     of what anon/authenticated were granted, so revoking them here does
--     not break any legitimate internal call.
-- =========================================================================

revoke all on function pmt_is_task_manager(text) from public;
revoke execute on function pmt_is_task_manager(text) from anon;
revoke execute on function pmt_is_task_manager(text) from authenticated;

revoke all on function pmt_can_review_task(text) from public;
revoke execute on function pmt_can_review_task(text) from anon;
revoke execute on function pmt_can_review_task(text) from authenticated;

revoke all on function pmt_validate_task_assignee(text, text) from public;
revoke execute on function pmt_validate_task_assignee(text, text) from anon;
revoke execute on function pmt_validate_task_assignee(text, text) from authenticated;

revoke all on function pmt_validate_task_transition() from public;
revoke execute on function pmt_validate_task_transition() from anon;
revoke execute on function pmt_validate_task_transition() from authenticated;

-- The 12 functions below ARE called directly by app/actions/*.ts (via
-- supabase.rpc(...)) under the signed-in user's own session — authenticated
-- retains EXECUTE; anon never does. Fine-grained "which authenticated user
-- may actually succeed" (Manager-only, Admin-only, assignee-only, etc.) is
-- enforced inside each function body, not by the coarse anon/authenticated
-- grant — Postgres/Supabase has no native per-application-role (ADMIN /
-- MANAGER / MEMBER) grant target, only anon/authenticated.

revoke all on function pmt_create_task(text, text, text, text, date) from public;
revoke execute on function pmt_create_task(text, text, text, text, date) from anon;
grant execute on function pmt_create_task(text, text, text, text, date) to authenticated;

revoke all on function pmt_reorder_tasks(text, text, text) from public;
revoke execute on function pmt_reorder_tasks(text, text, text) from anon;
grant execute on function pmt_reorder_tasks(text, text, text) to authenticated;

revoke all on function pmt_create_change_tasks(text, jsonb) from public;
revoke execute on function pmt_create_change_tasks(text, jsonb) from anon;
grant execute on function pmt_create_change_tasks(text, jsonb) to authenticated;

revoke all on function pmt_assign_task(text, text) from public;
revoke execute on function pmt_assign_task(text, text) from anon;
grant execute on function pmt_assign_task(text, text) to authenticated;

revoke all on function pmt_update_task(text, text, text) from public;
revoke execute on function pmt_update_task(text, text, text) from anon;
grant execute on function pmt_update_task(text, text, text) to authenticated;

revoke all on function pmt_change_deadline(text, date) from public;
revoke execute on function pmt_change_deadline(text, date) from anon;
grant execute on function pmt_change_deadline(text, date) to authenticated;

revoke all on function pmt_start_task(text) from public;
revoke execute on function pmt_start_task(text) from anon;
grant execute on function pmt_start_task(text) to authenticated;

revoke all on function pmt_submit_task_for_review(text, text, jsonb) from public;
revoke execute on function pmt_submit_task_for_review(text, text, jsonb) from anon;
grant execute on function pmt_submit_task_for_review(text, text, jsonb) to authenticated;

revoke all on function pmt_approve_submission_option(text, text[], text) from public;
revoke execute on function pmt_approve_submission_option(text, text[], text) from anon;
grant execute on function pmt_approve_submission_option(text, text[], text) to authenticated;

revoke all on function pmt_request_submission_changes(text, text, text[]) from public;
revoke execute on function pmt_request_submission_changes(text, text, text[]) from anon;
grant execute on function pmt_request_submission_changes(text, text, text[]) to authenticated;

revoke all on function pmt_reject_all_submission_options(text, text) from public;
revoke execute on function pmt_reject_all_submission_options(text, text) from anon;
grant execute on function pmt_reject_all_submission_options(text, text) to authenticated;

-- pmt_change_deliverable_type(): SECURITY DEFINER with elevated DELETE
-- capability (section 7). Postgres/Supabase has no "ADMIN-role" grant
-- target — ACTIVE ADMIN is enforced INSIDE the function body via
-- pmt_is_admin(), which is why this still must be granted to the whole
-- `authenticated` bucket (every real Admin user connects as `authenticated`,
-- same as every Manager/Member) — but anon is explicitly, permanently
-- excluded, and any authenticated caller who is not an ACTIVE Admin is
-- rejected on the function's first line before any read or write occurs.
revoke all on function pmt_change_deliverable_type(text, text) from public;
revoke execute on function pmt_change_deliverable_type(text, text) from anon;
grant execute on function pmt_change_deliverable_type(text, text) to authenticated;

commit;
