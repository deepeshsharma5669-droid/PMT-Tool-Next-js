-- Phase: RLS + registration hardening.
--
-- Replaces the fully permissive `USING(true)/WITH CHECK(true)` policies on
-- the 6 original tables, enables RLS (previously OFF) on the 6 Phase-2
-- tables, and adds real, identity-derived policies across all 12 plus a
-- policy-safety pass on pmt_reminders.
--
-- ARCHITECTURE NOTE: RLS policies here answer "who may touch which rows"
-- (role / department / assignee / identity) — that's what RLS is built
-- for. Multi-row state-machine correctness (valid status transitions,
-- "revision must increment by exactly 1") is instead enforced by small
-- BEFORE UPDATE/INSERT triggers, because RLS's WITH CHECK only sees the
-- proposed NEW row, not the OLD one, and stacking multiple permissive
-- UPDATE policies on the same table risks an unintended OR-composition
-- (Postgres ORs USING clauses and WITH CHECK clauses independently across
-- policies, so a USING match from policy A could pair with a WITH CHECK
-- match from policy B and permit a transition neither policy alone
-- intended). Triggers see both OLD and NEW directly and avoid that risk.
--
-- What this migration does NOT do: implement the full cross-table
-- workflow cascade (gate recalculation, stage-to-stage activation,
-- campaign completion once every deliverable is done). Those remain
-- Phase 6 Server Action responsibilities. This migration's job is to make
-- sure nothing can be tampered with in the meantime — not to finish the
-- workflow engine.

begin;

-- =========================================================================
-- 1. IDENTITY HELPER FUNCTIONS
-- =========================================================================
-- pmt_current_user() is SECURITY DEFINER with a pinned search_path: it has
-- to bypass pmt_users' own RLS to read the caller's row (otherwise
-- pmt_users' policies calling this function would recurse into
-- themselves), it takes no parameters (keyed purely off auth.uid(), which
-- the caller cannot forge), and it never touches anything but pmt_users.
-- No impersonation surface, no service-role capability exposed.

create or replace function pmt_current_user()
returns table (id text, role text, dept text, status text)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select id, role, dept, status
  from pmt_users
  where auth_user_id = auth.uid()
  limit 1
$$;

revoke all on function pmt_current_user() from public;
grant execute on function pmt_current_user() to anon, authenticated;

create or replace function pmt_current_pmt_id() returns text
language sql security definer stable set search_path = public, pg_temp as $$
  select id from pmt_current_user()
$$;

create or replace function pmt_current_role() returns text
language sql security definer stable set search_path = public, pg_temp as $$
  select role from pmt_current_user()
$$;

create or replace function pmt_current_dept() returns text
language sql security definer stable set search_path = public, pg_temp as $$
  select dept from pmt_current_user()
$$;

create or replace function pmt_current_status() returns text
language sql security definer stable set search_path = public, pg_temp as $$
  select status from pmt_current_user()
$$;

create or replace function pmt_is_active() returns boolean
language sql security definer stable set search_path = public, pg_temp as $$
  select coalesce(pmt_current_status() = 'ACTIVE', false)
$$;

create or replace function pmt_is_admin() returns boolean
language sql security definer stable set search_path = public, pg_temp as $$
  select pmt_is_active() and pmt_current_role() = 'ADMIN'
$$;

-- Manager check for a SPECIFIC department (not the caller's own — the
-- caller passes the department the ROW belongs to, e.g. a stage's dept).
create or replace function pmt_is_manager_of(target_dept text) returns boolean
language sql security definer stable set search_path = public, pg_temp as $$
  select pmt_is_active() and pmt_current_role() = 'MANAGER' and pmt_current_dept() = target_dept
$$;

-- NOT security definer: queries pmt_stages (a different table than
-- pmt_users, no self-recursion risk), and deliberately runs under the
-- CALLER's own RLS visibility into pmt_stages — which is correct, since a
-- Manager who can't even SELECT a given stage (wrong department) should
-- also fail this check, and the stages SELECT policy below already scopes
-- that correctly.
create or replace function pmt_can_manage_stage(p_stage_id text) returns boolean
language sql stable as $$
  select pmt_is_admin() or exists (
    select 1 from pmt_stages s
    where s.id = p_stage_id and pmt_is_manager_of(s.dept)
  )
$$;

-- Looks up the parent deliverable's current client_revision/status for a
-- given stage — used to validate Change Task creation against DB state
-- instead of trusting a client-supplied revision number.
create or replace function pmt_deliverable_for_stage(p_stage_id text)
returns table (client_revision integer, status text)
language sql stable as $$
  select d.client_revision, d.status
  from pmt_stages s
  join pmt_deliverables d on d.id = s.deliverable_id
  where s.id = p_stage_id
$$;

-- =========================================================================
-- 2. TRANSITION-VALIDATION TRIGGERS (state-machine correctness)
-- =========================================================================

-- pmt_tasks: exact rules as specified —
--   Member:  {TODO,CHANGES_REQUIRED} -> IN_PROGRESS
--            IN_PROGRESS -> IN_REVIEW, only if a submission already exists
--            Member can never set APPROVED, never touch another user's task,
--            never reassign (assignee_id must stay their own id)
--   Manager: IN_REVIEW -> {APPROVED, CHANGES_REQUIRED} only
--   Admin:   unrestricted (manual correction / future Phase-6 RPCs run as
--            admin can still use this escape hatch if needed)
create or replace function pmt_validate_task_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := pmt_current_role();
begin
  if pmt_is_admin() then
    return new;
  end if;

  if old.status = new.status then
    return new; -- non-status edits (title/deadline/order/etc.) — RLS handles ownership
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
    if not (old.status = 'IN_REVIEW' and new.status in ('APPROVED', 'CHANGES_REQUIRED')) then
      raise exception 'Invalid task status transition for Manager: % -> %', old.status, new.status;
    end if;
  else
    raise exception 'Not authorized to change task status.';
  end if;

  return new;
end;
$$;

drop trigger if exists pmt_tasks_validate_transition on pmt_tasks;
create trigger pmt_tasks_validate_transition
  before update on pmt_tasks
  for each row
  execute function pmt_validate_task_transition();

-- pmt_stages: PENDING and COMPLETED are read-only as STARTING states (no
-- transition allowed out of them by non-admin) — matches "sequential stage
-- progression must be determined server-side" / "do not allow a browser
-- request to arbitrarily activate a stage." Cascade activation of the
-- NEXT stage (PENDING -> ACTIVE) is intentionally left to Phase 6's
-- server-side cascade logic (or manual Admin correction) — it is a
-- cross-row operation this single-table trigger correctly refuses to do
-- unsupervised.
create or replace function pmt_validate_stage_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if pmt_is_admin() then
    return new;
  end if;

  if old.status = new.status then
    return new; -- e.g. rework_pending toggling alone
  end if;

  if not (
    (old.status = 'ACTIVE' and new.status = 'CLIENT_DECISION')
    or (old.status = 'CLIENT_DECISION' and new.status in ('ACTIVE', 'COMPLETED'))
  ) then
    raise exception 'Invalid stage status transition: % -> %', old.status, new.status;
  end if;

  return new;
end;
$$;

drop trigger if exists pmt_stages_validate_transition on pmt_stages;
create trigger pmt_stages_validate_transition
  before update on pmt_stages
  for each row
  execute function pmt_validate_stage_transition();

-- pmt_deliverables: client_revision may only ever move to exactly
-- old+1 — directly enforces "do not accept an arbitrary revision number
-- from the browser."
create or replace function pmt_validate_deliverable_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if pmt_is_admin() then
    return new;
  end if;

  if new.client_revision is distinct from old.client_revision
     and new.client_revision <> old.client_revision + 1 then
    raise exception 'client_revision must increment by exactly 1 (was %, attempted %)',
      old.client_revision, new.client_revision;
  end if;

  return new;
end;
$$;

drop trigger if exists pmt_deliverables_validate_transition on pmt_deliverables;
create trigger pmt_deliverables_validate_transition
  before update on pmt_deliverables
  for each row
  execute function pmt_validate_deliverable_transition();

-- Server-generated timestamps only — "do not trust timestamp from
-- browser" — applied to every table with a caller-visible timestamp
-- column that records when something happened.
create or replace function pmt_force_now()
returns trigger
language plpgsql
as $$
begin
  if tg_argv[0] = 'created_at' then
    new.created_at := now();
  elsif tg_argv[0] = 'submitted_at' then
    new.submitted_at := now();
  elsif tg_argv[0] = 'recorded_at' then
    new.recorded_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists pmt_activity_force_timestamp on pmt_activity;
create trigger pmt_activity_force_timestamp
  before insert on pmt_activity
  for each row execute function pmt_force_now('created_at');

drop trigger if exists pmt_notifications_force_timestamp on pmt_notifications;
create trigger pmt_notifications_force_timestamp
  before insert on pmt_notifications
  for each row execute function pmt_force_now('created_at');

drop trigger if exists pmt_submissions_force_timestamp on pmt_submissions;
create trigger pmt_submissions_force_timestamp
  before insert on pmt_submissions
  for each row execute function pmt_force_now('submitted_at');

drop trigger if exists pmt_client_decisions_force_timestamp on pmt_client_decisions;
create trigger pmt_client_decisions_force_timestamp
  before insert on pmt_client_decisions
  for each row execute function pmt_force_now('recorded_at');

drop trigger if exists pmt_deliverable_feedback_force_timestamp on pmt_deliverable_feedback;
create trigger pmt_deliverable_feedback_force_timestamp
  before insert on pmt_deliverable_feedback
  for each row execute function pmt_force_now('created_at');

-- =========================================================================
-- 3. ENABLE RLS on the 6 Phase-2 tables (currently OFF — fully open today)
-- =========================================================================

alter table pmt_submissions enable row level security;
alter table pmt_submission_options enable row level security;
alter table pmt_client_decisions enable row level security;
alter table pmt_deliverable_feedback enable row level security;
alter table pmt_activity enable row level security;
alter table pmt_notifications enable row level security;

-- =========================================================================
-- 4. REVOKE TRUNCATE (RLS does not govern TRUNCATE at all — a privilege
--    grant is the only thing stopping it, and anon currently has it on
--    every table)
-- =========================================================================

revoke truncate on
  pmt_users, pmt_clients, pmt_campaigns, pmt_deliverables, pmt_stages, pmt_tasks,
  pmt_submissions, pmt_submission_options, pmt_client_decisions,
  pmt_deliverable_feedback, pmt_activity, pmt_notifications, pmt_reminders
from anon, authenticated;

-- =========================================================================
-- 5. DROP old fully-permissive policies
-- =========================================================================

drop policy if exists "read all" on pmt_users;
drop policy if exists "write all" on pmt_users;
drop policy if exists "read all" on pmt_clients;
drop policy if exists "write all" on pmt_clients;
drop policy if exists "read all" on pmt_campaigns;
drop policy if exists "write all" on pmt_campaigns;
drop policy if exists "read all" on pmt_deliverables;
drop policy if exists "write all" on pmt_deliverables;
drop policy if exists "read all" on pmt_stages;
drop policy if exists "write all" on pmt_stages;
drop policy if exists "read all" on pmt_tasks;
drop policy if exists "write all" on pmt_tasks;
drop policy if exists "read all" on pmt_reminders;

-- =========================================================================
-- 6. pmt_users
-- =========================================================================

-- Read own row regardless of status (needed for /pending-access, /no-access).
create policy pmt_users_select_self on pmt_users for select
  using (auth_user_id = auth.uid());

-- Any ACTIVE user can see the team roster (names/depts/avatars are used
-- all over the operational UI — assignee names, manager rosters, etc.).
create policy pmt_users_select_active on pmt_users for select
  using (pmt_is_active());

-- Self-registration only: forces PENDING/NULL/NULL regardless of what the
-- client sends. This is the fix for "do not allow a broad anonymous
-- INSERT policy allowing arbitrary pmt_users rows" — a registrant can only
-- ever insert exactly their own unprivileged pending profile.
create policy pmt_users_insert_self on pmt_users for insert
  with check (
    auth_user_id = auth.uid()
    and status = 'PENDING'
    and role is null
    and dept is null
  );

create policy pmt_users_insert_admin on pmt_users for insert
  with check (pmt_is_admin());

-- Only Admin may ever change role/dept/status (or anything else) on a
-- pmt_users row. No self-update policy exists at all — a user cannot
-- alter their own row, full stop, which is what prevents self-promotion.
create policy pmt_users_update_admin on pmt_users for update
  using (pmt_is_admin())
  with check (pmt_is_admin());

-- No DELETE policy on pmt_users (default-deny) — deactivation, not deletion.

-- =========================================================================
-- 7. pmt_clients / pmt_campaigns / pmt_deliverables — ADMIN-only mutation
--    of the administrative fields; read open to any ACTIVE user; Manager
--    may still update a deliverable's own workflow state (status,
--    client_revision) for deliverables they own a stage of, since that's
--    a normal part of recording a Client Decision.
-- =========================================================================

create policy pmt_clients_select on pmt_clients for select using (pmt_is_active());
create policy pmt_clients_admin_write on pmt_clients for all
  using (pmt_is_admin()) with check (pmt_is_admin());

create policy pmt_campaigns_select on pmt_campaigns for select using (pmt_is_active());
create policy pmt_campaigns_admin_write on pmt_campaigns for all
  using (pmt_is_admin()) with check (pmt_is_admin());

create policy pmt_deliverables_select on pmt_deliverables for select using (pmt_is_active());

create policy pmt_deliverables_admin_write on pmt_deliverables for all
  using (pmt_is_admin()) with check (pmt_is_admin());

-- Manager: only the workflow-state fields, only for a deliverable they own
-- at least one stage of. (RLS grants row-level access here — it does not
-- separately prevent a Manager from also editing name/type/campaign_id
-- through this same row-level grant; that column-level precision is a
-- Phase 6 Server Action responsibility, which will only ever issue
-- targeted `.update({status, client_revision})` calls, not accept an
-- arbitrary row body from the client. Documented as a known limitation.)
create policy pmt_deliverables_manager_write on pmt_deliverables for update
  using (exists (select 1 from pmt_stages s where s.deliverable_id = pmt_deliverables.id and pmt_is_manager_of(s.dept)))
  with check (exists (select 1 from pmt_stages s where s.deliverable_id = pmt_deliverables.id and pmt_is_manager_of(s.dept)));

-- =========================================================================
-- 8. pmt_stages
-- =========================================================================

create policy pmt_stages_select_admin on pmt_stages for select using (pmt_is_admin());
create policy pmt_stages_select_manager on pmt_stages for select using (pmt_is_manager_of(dept));
create policy pmt_stages_select_member on pmt_stages for select using (
  exists (select 1 from pmt_tasks t where t.stage_id = pmt_stages.id and t.assignee_id = pmt_current_pmt_id())
);

create policy pmt_stages_insert_admin on pmt_stages for insert with check (pmt_is_admin());

-- Manager may only touch a stage in their own dept, and only while it's
-- ACTIVE or CLIENT_DECISION (never PENDING or COMPLETED) — the transition
-- trigger above additionally restricts which NEW status is legal.
create policy pmt_stages_update_manager on pmt_stages for update
  using (pmt_is_manager_of(dept) and status in ('ACTIVE', 'CLIENT_DECISION'))
  with check (pmt_is_manager_of(dept));

create policy pmt_stages_update_admin on pmt_stages for update
  using (pmt_is_admin()) with check (pmt_is_admin());

-- =========================================================================
-- 9. pmt_tasks
-- =========================================================================

create policy pmt_tasks_select_admin on pmt_tasks for select using (pmt_is_admin());
create policy pmt_tasks_select_manager on pmt_tasks for select using (pmt_can_manage_stage(stage_id));
create policy pmt_tasks_select_member on pmt_tasks for select using (assignee_id = pmt_current_pmt_id());

-- Manager/Admin create tasks. Normal tasks must start TODO with no
-- revision tag. Client Change Tasks must carry the CURRENT deliverable
-- revision (read from the DB, not the client), start CHANGES_REQUIRED,
-- and only while the deliverable is actually in a Client Changes cycle.
create policy pmt_tasks_insert on pmt_tasks for insert
  with check (
    pmt_can_manage_stage(stage_id)
    and (
      (is_client_change = false and client_revision is null and status = 'TODO')
      or (
        is_client_change = true
        and status = 'CHANGES_REQUIRED'
        and (select client_revision from pmt_deliverable_for_stage(stage_id)) > 0
        and client_revision = (select client_revision from pmt_deliverable_for_stage(stage_id))
        and (select status from pmt_deliverable_for_stage(stage_id)) = 'CHANGES_REQUESTED'
      )
    )
  );

-- Ownership-only row scope — the trigger enforces which status transitions
-- are actually legal, so these policies don't need to encode status
-- ranges (and avoid the multi-policy OR-composition risk noted above).
create policy pmt_tasks_update_member on pmt_tasks for update
  using (assignee_id = pmt_current_pmt_id() and pmt_is_active())
  with check (assignee_id = pmt_current_pmt_id());

create policy pmt_tasks_update_manager on pmt_tasks for update
  using (pmt_can_manage_stage(stage_id))
  with check (pmt_can_manage_stage(stage_id));

create policy pmt_tasks_update_admin on pmt_tasks for update
  using (pmt_is_admin()) with check (pmt_is_admin());

create policy pmt_tasks_delete_admin on pmt_tasks for delete using (pmt_is_admin());

-- =========================================================================
-- 10. pmt_submissions / pmt_submission_options
-- =========================================================================

create policy pmt_submissions_select on pmt_submissions for select using (
  pmt_is_admin()
  or exists (select 1 from pmt_tasks t where t.id = pmt_submissions.task_id and pmt_can_manage_stage(t.stage_id))
  or exists (select 1 from pmt_tasks t where t.id = pmt_submissions.task_id and t.assignee_id = pmt_current_pmt_id())
);

-- A Member may only submit for their OWN assigned task, and only claim to
-- be themselves as the submitter — "Member cannot create fake submissions
-- for another user's task."
create policy pmt_submissions_insert_member on pmt_submissions for insert
  with check (
    submitted_by = pmt_current_pmt_id()
    and exists (select 1 from pmt_tasks t where t.id = pmt_submissions.task_id and t.assignee_id = pmt_current_pmt_id())
  );

-- Manager records the review decision on the submission row (feedback,
-- decision_type) — scoped to their own department via the parent task.
create policy pmt_submissions_update_manager on pmt_submissions for update
  using (exists (select 1 from pmt_tasks t where t.id = pmt_submissions.task_id and pmt_can_manage_stage(t.stage_id)))
  with check (exists (select 1 from pmt_tasks t where t.id = pmt_submissions.task_id and pmt_can_manage_stage(t.stage_id)));

create policy pmt_submissions_admin on pmt_submissions for all
  using (pmt_is_admin()) with check (pmt_is_admin());

create policy pmt_submission_options_select on pmt_submission_options for select using (
  exists (
    select 1 from pmt_submissions sub
    where sub.id = pmt_submission_options.submission_id
    and (
      pmt_is_admin()
      or exists (select 1 from pmt_tasks t where t.id = sub.task_id and pmt_can_manage_stage(t.stage_id))
      or exists (select 1 from pmt_tasks t where t.id = sub.task_id and t.assignee_id = pmt_current_pmt_id())
    )
  )
);

create policy pmt_submission_options_insert_member on pmt_submission_options for insert
  with check (
    exists (
      select 1 from pmt_submissions sub
      join pmt_tasks t on t.id = sub.task_id
      where sub.id = pmt_submission_options.submission_id and t.assignee_id = pmt_current_pmt_id()
    )
  );

-- Manager sets `decision` (SELECTED/REJECTED) on each option during review.
create policy pmt_submission_options_update_manager on pmt_submission_options for update
  using (
    exists (
      select 1 from pmt_submissions sub
      join pmt_tasks t on t.id = sub.task_id
      where sub.id = pmt_submission_options.submission_id and pmt_can_manage_stage(t.stage_id)
    )
  )
  with check (
    exists (
      select 1 from pmt_submissions sub
      join pmt_tasks t on t.id = sub.task_id
      where sub.id = pmt_submission_options.submission_id and pmt_can_manage_stage(t.stage_id)
    )
  );

create policy pmt_submission_options_admin on pmt_submission_options for all
  using (pmt_is_admin()) with check (pmt_is_admin());

-- =========================================================================
-- 11. pmt_client_decisions
-- =========================================================================

-- Read broadly (low-sensitivity historical record, useful operational
-- context for anyone active on the deliverable's pipeline).
create policy pmt_client_decisions_select on pmt_client_decisions for select using (pmt_is_active());

-- The critical one: derives which stage is actually at CLIENT_DECISION
-- server-side (never trusts a client-supplied stage id), requires the
-- acting Manager to own that stage's department (or be Admin), and forces
-- client_revision to match the deliverable's current value exactly.
create policy pmt_client_decisions_insert on pmt_client_decisions for insert
  with check (
    recorded_by = pmt_current_pmt_id()
    and client_revision = (select client_revision from pmt_deliverables d where d.id = pmt_client_decisions.deliverable_id)
    and exists (
      select 1 from pmt_stages s
      where s.deliverable_id = pmt_client_decisions.deliverable_id
      and s.status = 'CLIENT_DECISION'
      and (pmt_is_admin() or pmt_is_manager_of(s.dept))
    )
  );

-- Append-only: no UPDATE/DELETE policy (default-deny).

-- =========================================================================
-- 12. pmt_deliverable_feedback
-- =========================================================================

-- Members explicitly need to read this ("view feedback").
create policy pmt_deliverable_feedback_select on pmt_deliverable_feedback for select using (pmt_is_active());

create policy pmt_deliverable_feedback_insert on pmt_deliverable_feedback for insert
  with check (
    author_id = pmt_current_pmt_id()
    and client_revision = (select client_revision from pmt_deliverables d where d.id = pmt_deliverable_feedback.deliverable_id)
    and exists (
      select 1 from pmt_stages s
      where s.deliverable_id = pmt_deliverable_feedback.deliverable_id
      and s.status = 'CLIENT_DECISION'
      and (pmt_is_admin() or pmt_is_manager_of(s.dept))
    )
  );

-- Allows toggling `resolved` — same department-ownership scope as insert.
create policy pmt_deliverable_feedback_update on pmt_deliverable_feedback for update
  using (
    pmt_is_admin()
    or exists (
      select 1 from pmt_stages s
      where s.deliverable_id = pmt_deliverable_feedback.deliverable_id and pmt_is_manager_of(s.dept)
    )
  )
  with check (
    pmt_is_admin()
    or exists (
      select 1 from pmt_stages s
      where s.deliverable_id = pmt_deliverable_feedback.deliverable_id and pmt_is_manager_of(s.dept)
    )
  );

-- =========================================================================
-- 13. pmt_activity
-- =========================================================================

-- actor_id is forced to the caller's own id — cannot forge activity as
-- someone else. created_at is forced by the trigger above regardless of
-- what's submitted.
create policy pmt_activity_insert on pmt_activity for insert
  with check (pmt_is_active() and actor_id = pmt_current_pmt_id());

create policy pmt_activity_select on pmt_activity for select using (
  pmt_is_admin()
  or actor_id = pmt_current_pmt_id()
  or (entity_type = 'TASK' and exists (
        select 1 from pmt_tasks t where t.id = pmt_activity.entity_id
        and (t.assignee_id = pmt_current_pmt_id() or pmt_can_manage_stage(t.stage_id))
      ))
  or (entity_type in ('DELIVERABLE', 'CAMPAIGN', 'CLIENT', 'STAGE') and pmt_is_active())
);

-- Append-only: no UPDATE/DELETE policy.

-- =========================================================================
-- 14. pmt_notifications
-- =========================================================================

-- Recipients read only their own inbox; Admin has broader visibility.
create policy pmt_notifications_select on pmt_notifications for select using (
  user_id = pmt_current_pmt_id() or pmt_is_admin()
);

-- No direct INSERT policy for regular users at all — normal authenticated
-- users cannot write a row into this table under any circumstance. The
-- ONLY way to create a notification is the trusted RPC below, or Admin's
-- direct-write escape hatch (pmt_notifications_admin), consistent with
-- Admin's override everywhere else in this schema.

-- Recipient may mark their own notification read — cannot reassign it to
-- someone else (`user_id` must stay their own id in the new row too).
create policy pmt_notifications_update_self on pmt_notifications for update
  using (user_id = pmt_current_pmt_id())
  with check (user_id = pmt_current_pmt_id());

create policy pmt_notifications_admin on pmt_notifications for all
  using (pmt_is_admin()) with check (pmt_is_admin());

-- Trusted notification creation. SECURITY DEFINER: bypasses the (now
-- absent) direct-INSERT policy by design — this is the only path a normal
-- authenticated user has for creating a notification at all. The caller
-- must be an ACTIVE PMT user and the recipient must be a real pmt_users
-- row; message/type/action_code are otherwise passed through as given by
-- the caller (a Server Action), since choosing WHO to notify and WHY is
-- exactly the "trusted workflow logic" this is meant to be called from —
-- not something this function can second-guess without knowing the
-- calling context. Grant is restricted to `authenticated` only (never
-- `anon`), and `pmt_is_active()` is re-checked inside regardless.
create or replace function pmt_create_notification(
  p_user_id text,
  p_type text,
  p_message text,
  p_action_code text default null
)
returns pmt_notifications
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row pmt_notifications;
begin
  if not pmt_is_active() then
    raise exception 'Only an active PMT user may create notifications.';
  end if;

  if not exists (select 1 from pmt_users u where u.id = p_user_id) then
    raise exception 'Unknown notification recipient.';
  end if;

  insert into pmt_notifications (id, user_id, type, message, action_code, read)
  values (gen_random_uuid()::text, p_user_id, p_type, p_message, p_action_code, false)
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function pmt_create_notification(text, text, text, text) from public;
grant execute on function pmt_create_notification(text, text, text, text) to authenticated;

-- =========================================================================
-- 15. pmt_reminders — policy safety pass only (per instruction: inspect
--     and keep safe, do not integrate into notifications, do not touch
--     schema). Replaces the single existing fully-permissive "read all"
--     (cmd=ALL, using(true), with_check(true)) policy with the same
--     identity-scoped model used everywhere else, scoped by
--     sent_to_dept directly (no stage/deliverable join needed — the
--     column already carries the department).
-- =========================================================================

create policy pmt_reminders_select on pmt_reminders for select using (
  pmt_is_admin()
  or pmt_is_manager_of(sent_to_dept)
  or sent_by = pmt_current_pmt_id()
  or responded_by = pmt_current_pmt_id()
);

create policy pmt_reminders_insert on pmt_reminders for insert
  with check (
    sent_by = pmt_current_pmt_id()
    and (pmt_is_admin() or pmt_is_manager_of(sent_to_dept))
  );

create policy pmt_reminders_update on pmt_reminders for update
  using (pmt_is_admin() or pmt_is_manager_of(sent_to_dept))
  with check (pmt_is_admin() or pmt_is_manager_of(sent_to_dept));

commit;
