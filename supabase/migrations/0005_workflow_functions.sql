-- Phase 6: server-side workflow engine.
--
-- These are the actual, callable, atomic implementations of the legacy
-- workflow (recalculateStageGate, cascadeCompletion, submission review,
-- Client Approval/Changes, Change Task creation, etc.), ported faithfully
-- from public/pmt-legacy.html. Each function is a single Postgres
-- transaction by construction — if any statement inside fails, the whole
-- call rolls back, so there is no partially-updated workflow state.
--
-- Authorization model: every function re-resolves identity via
-- pmt_current_user() (never trusts a parameter for role/dept/actor),
-- re-reads the target row(s) from the DB, and validates the current state
-- before mutating. Most functions run SECURITY INVOKER (default) — their
-- writes stay inside what the 0003 RLS policies already grant the caller,
-- so RLS is a real, independent backstop, not just decoration. The one
-- exception is pmt_record_client_approval, which legitimately needs to
-- activate a stage in a DIFFERENT department than the acting Manager's
-- own (Gate 2's cascade crosses department boundaries by design) and, on
-- a Deliverable's final stage, complete the Campaign — an Admin-only
-- table under RLS. That one is SECURITY DEFINER, gated by its own
-- explicit checks, with a transaction-local flag so the transition
-- trigger recognizes the cascade as legitimate rather than an arbitrary
-- browser-driven stage activation.

begin;

-- =========================================================================
-- 0. Trigger amendment: recognize the cascade context
-- =========================================================================

create or replace function pmt_validate_stage_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if pmt_is_admin() or current_setting('pmt.cascade_context', true) = 'true' then
    return new;
  end if;

  if old.status = new.status then
    return new;
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

-- =========================================================================
-- 1. Shared internal helper: apply the Gate-1/Gate-2 calculation to a
--    stage after a task's status changes, exactly mirroring
--    recalculateStageGate(). Not exposed to callers directly.
-- =========================================================================

create or replace function pmt_apply_stage_gate(p_stage_id text)
returns void
language plpgsql
as $$
declare
  v_stage pmt_stages%rowtype;
  v_deliverable pmt_deliverables%rowtype;
  v_all_approved boolean;
begin
  select * into v_stage from pmt_stages where id = p_stage_id;
  select * into v_deliverable from pmt_deliverables where id = v_stage.deliverable_id;

  if v_stage.status = 'COMPLETED' then
    return; -- legacy: `stage.status !== 'COMPLETED'` guard
  end if;

  if v_deliverable.client_revision = 0 then
    select bool_and(status = 'APPROVED') and count(*) > 0
      into v_all_approved
      from pmt_tasks
      where stage_id = p_stage_id;
  else
    select bool_and(status = 'APPROVED') and count(*) > 0
      into v_all_approved
      from pmt_tasks
      where stage_id = p_stage_id
        and is_client_change = true
        and client_revision = v_deliverable.client_revision;
  end if;

  if v_all_approved then
    update pmt_stages set rework_pending = false, status = 'CLIENT_DECISION' where id = p_stage_id;
    update pmt_deliverables set status = 'CLIENT_REVIEW' where id = v_deliverable.id;
  end if;
end;
$$;

-- =========================================================================
-- 2. CAMPAIGNS
-- =========================================================================

-- createCampaign(): campaign + N deliverables + their generated stages, one
-- atomic call. p_deliverables: jsonb array of {"name": text, "type": text}.
create or replace function pmt_create_campaign(
  p_client_id text,
  p_name text,
  p_deadline date,
  p_deliverables jsonb
)
returns text
language plpgsql
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_campaign_id text;
  v_deliverable jsonb;
  v_deliverable_id text;
  v_stage_def jsonb;
  v_order int;
  v_stage_id text;
begin
  if not pmt_is_admin() then
    raise exception 'Only an Admin may create a campaign.';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Campaign name is required.';
  end if;
  if jsonb_array_length(p_deliverables) = 0 then
    raise exception 'A campaign needs at least one Deliverable.';
  end if;

  v_campaign_id := gen_random_uuid()::text;
  -- priority is always 'Medium' at creation, matching the legacy wizard —
  -- it is a descriptive campaign-level field, editable afterward via
  -- pmt_update_campaign, never a per-task priority.
  insert into pmt_campaigns (id, client_id, name, priority, deadline, status)
  values (v_campaign_id, p_client_id, p_name, 'Medium', p_deadline, 'ACTIVE');

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'CAMPAIGN', v_campaign_id, 'Created campaign ' || p_name, v_actor);

  for v_deliverable in select * from jsonb_array_elements(p_deliverables)
  loop
    v_deliverable_id := gen_random_uuid()::text;
    insert into pmt_deliverables (id, campaign_id, name, type, client_revision, status)
    values (
      v_deliverable_id, v_campaign_id,
      coalesce(nullif(trim(v_deliverable->>'name'), ''), v_deliverable->>'type'),
      v_deliverable->>'type', 0, 'IN_PROGRESS'
    );
    insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
    values (gen_random_uuid()::text, 'DELIVERABLE', v_deliverable_id, 'Created deliverable ' || (v_deliverable->>'name'), v_actor);

    v_order := 0;
    for v_stage_def in
      select * from jsonb_array_elements(
        case v_deliverable->>'type'
          when 'Static Poster' then '[{"name":"Content Strategy","dept":"Content"},{"name":"Visual Design","dept":"Design"}]'
          when 'Instagram Carousel' then '[{"name":"Copywriting","dept":"Content"},{"name":"Layout Design","dept":"Design"}]'
          when 'Instagram Reel' then '[{"name":"Scripting","dept":"Content"},{"name":"Storyboarding","dept":"Design"},{"name":"Animation","dept":"Animation"}]'
          when 'Presentation' then '[{"name":"Content Drafting","dept":"Content"},{"name":"Slide Design","dept":"Design"}]'
          else '[{"name":"Content Strategy","dept":"Content"},{"name":"Visual Design","dept":"Design"}]'
        end::jsonb
      )
    loop
      v_order := v_order + 1;
      v_stage_id := gen_random_uuid()::text;
      insert into pmt_stages (id, deliverable_id, name, dept, stage_order, status, rework_pending)
      values (v_stage_id, v_deliverable_id, v_stage_def->>'name', v_stage_def->>'dept', v_order,
              case when v_order = 1 then 'ACTIVE' else 'PENDING' end, false);
    end loop;
  end loop;

  return v_campaign_id;
end;
$$;

create or replace function pmt_update_campaign(
  p_campaign_id text,
  p_name text,
  p_priority text,
  p_deadline date,
  p_status text
)
returns void
language plpgsql
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_all_completed boolean;
begin
  if not pmt_is_admin() then
    raise exception 'Only an Admin may edit a campaign.';
  end if;
  if not exists (select 1 from pmt_campaigns where id = p_campaign_id) then
    raise exception 'Campaign not found.';
  end if;
  if p_status not in ('ACTIVE', 'ARCHIVED', 'COMPLETED') then
    raise exception 'Invalid campaign status.';
  end if;

  -- COMPLETED must remain system-controlled — never a direct manual
  -- selection unless every Deliverable already is (matches the legacy
  -- defensive guard in openEditCampaignModal's save handler, even though
  -- the UI's own <select> never actually offers COMPLETED as an option).
  if p_status = 'COMPLETED' then
    select count(*) > 0 and bool_and(status = 'COMPLETED') into v_all_completed
      from pmt_deliverables where campaign_id = p_campaign_id;
    if not v_all_completed then
      raise exception 'Campaign cannot be marked Completed until all Deliverables are completed.';
    end if;
  end if;

  update pmt_campaigns set name = p_name, priority = p_priority, deadline = p_deadline, status = p_status
  where id = p_campaign_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'CAMPAIGN', p_campaign_id, 'Edited campaign details', v_actor);
end;
$$;

create or replace function pmt_archive_campaign(p_campaign_id text)
returns void
language plpgsql
as $$
declare
  v_actor text := pmt_current_pmt_id();
begin
  if not pmt_is_admin() then
    raise exception 'Only an Admin may archive a campaign.';
  end if;
  update pmt_campaigns set status = 'ARCHIVED' where id = p_campaign_id;
  if not found then
    raise exception 'Campaign not found.';
  end if;
  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'CAMPAIGN', p_campaign_id, 'Archived campaign', v_actor);
end;
$$;

-- =========================================================================
-- 3. DELIVERABLES
-- =========================================================================

create or replace function pmt_add_deliverable(p_campaign_id text, p_name text, p_type text)
returns text
language plpgsql
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_campaign pmt_campaigns%rowtype;
  v_deliverable_id text;
  v_stage_def jsonb;
  v_order int := 0;
begin
  if not pmt_is_admin() then
    raise exception 'Only an Admin may add a Deliverable.';
  end if;

  select * into v_campaign from pmt_campaigns where id = p_campaign_id;
  if not found then
    raise exception 'Campaign not found.';
  end if;
  if v_campaign.status in ('COMPLETED', 'ARCHIVED') then
    raise exception 'Campaign is %. Reopen the campaign before adding a Deliverable.', lower(v_campaign.status);
  end if;
  if exists (select 1 from pmt_deliverables where campaign_id = p_campaign_id and lower(trim(name)) = lower(trim(p_name))) then
    raise exception 'A deliverable with that name already exists in this campaign.';
  end if;

  v_deliverable_id := gen_random_uuid()::text;
  insert into pmt_deliverables (id, campaign_id, name, type, client_revision, status)
  values (v_deliverable_id, p_campaign_id, p_name, p_type, 0, 'IN_PROGRESS');

  for v_stage_def in
    select * from jsonb_array_elements(
      case p_type
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
    values (gen_random_uuid()::text, v_deliverable_id, v_stage_def->>'name', v_stage_def->>'dept', v_order,
            case when v_order = 1 then 'ACTIVE' else 'PENDING' end, false);
  end loop;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'DELIVERABLE', v_deliverable_id, 'Added deliverable ' || p_name || ' to campaign', v_actor);

  return v_deliverable_id;
end;
$$;

-- changeDeliverableType(): only before production history exists. Deletes
-- and rebuilds only the pre-production stages/tasks — a hard reject
-- (never a silent rebuild) once real work has started, matching
-- deliverableHasProductionHistory() exactly.
create or replace function pmt_change_deliverable_type(p_deliverable_id text, p_new_type text)
returns void
language plpgsql
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
-- 4. TASKS
-- =========================================================================

create or replace function pmt_create_task(
  p_stage_id text, p_title text, p_description text, p_assignee_id text, p_deadline date
)
returns text
language plpgsql
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_task_id text;
  v_order int;
begin
  if not pmt_can_manage_stage(p_stage_id) then
    raise exception 'Not authorized to create tasks in this stage''s department.';
  end if;
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'Task title is required.';
  end if;

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

-- reorderTasks(): renumbers the ENTIRE reorderable set (excludes APPROVED
-- and IN_REVIEW, which stay locked/read-only), atomically.
create or replace function pmt_reorder_tasks(p_stage_id text, p_dragged_task_id text, p_target_task_id text)
returns void
language plpgsql
as $$
declare
  v_actor text := pmt_current_pmt_id();
  v_ids text[];
  v_dragged_idx int;
  v_target_idx int;
  v_id text;
  v_i int := 0;
begin
  if not pmt_can_manage_stage(p_stage_id) then
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

-- =========================================================================
-- 5. TASK EXECUTION (Member)
-- =========================================================================

create or replace function pmt_start_task(p_task_id text)
returns void
language plpgsql
as $$
declare
  v_task pmt_tasks%rowtype;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not (pmt_current_role() = 'MEMBER' and v_task.assignee_id = pmt_current_pmt_id()) then
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

-- submitTaskForReview(): creates the submission + its options, then flips
-- the task to IN_REVIEW — in that order, so the transition trigger's
-- "submission must already exist" check sees it.
-- p_options: jsonb array of {"name": text, "link": text, "note": text}.
create or replace function pmt_submit_task_for_review(p_task_id text, p_note text, p_options jsonb)
returns text
language plpgsql
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
  if not (pmt_current_role() = 'MEMBER' and v_task.assignee_id = pmt_current_pmt_id()) then
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
  for v_mgr in select id from pmt_users where role = 'MANAGER' and dept = v_stage.dept and status = 'ACTIVE'
  loop
    perform pmt_create_notification(v_mgr.id, 'SUBMISSION_RECEIVED', 'A submission is ready for your review.', null);
  end loop;

  return v_submission_id;
end;
$$;

-- =========================================================================
-- 6. VARIANT REVIEW (Manager)
-- =========================================================================

create or replace function pmt_approve_submission_option(
  p_task_id text, p_selected_option_ids text[], p_manager_feedback text
)
returns void
language plpgsql
as $$
declare
  v_task pmt_tasks%rowtype;
  v_submission_id text;
  v_selected_count int;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not pmt_can_manage_stage(v_task.stage_id) then
    raise exception 'You can only review submissions in your own department.';
  end if;
  if v_task.status <> 'IN_REVIEW' then
    raise exception 'This task is not currently awaiting review.';
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
as $$
declare
  v_task pmt_tasks%rowtype;
  v_submission_id text;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not pmt_can_manage_stage(v_task.stage_id) then
    raise exception 'You can only review submissions in your own department.';
  end if;
  if v_task.status <> 'IN_REVIEW' then
    raise exception 'This task is not currently awaiting review.';
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
as $$
declare
  v_task pmt_tasks%rowtype;
  v_submission_id text;
begin
  select * into v_task from pmt_tasks where id = p_task_id;
  if not found then raise exception 'Task not found.'; end if;
  if not pmt_can_manage_stage(v_task.stage_id) then
    raise exception 'You can only review submissions in your own department.';
  end if;
  if v_task.status <> 'IN_REVIEW' then
    raise exception 'This task is not currently awaiting review.';
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
-- 7. CLIENT DECISIONS
-- =========================================================================

-- recordClientApproval(): SECURITY DEFINER — see header note. Records the
-- decision, then runs cascadeCompletion() exactly: complete this stage,
-- activate the immediate next stage OR complete the Deliverable, and only
-- complete the Campaign if every other Deliverable is already COMPLETED.
create or replace function pmt_record_client_approval(
  p_stage_id text, p_channel text, p_contact_person text, p_notes text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage pmt_stages%rowtype;
  v_deliverable pmt_deliverables%rowtype;
  v_next_stage pmt_stages%rowtype;
  v_all_other_completed boolean;
  v_mgr record;
begin
  select * into v_stage from pmt_stages where id = p_stage_id;
  if not found then raise exception 'Stage not found.'; end if;
  if not pmt_can_manage_stage(p_stage_id) then
    raise exception 'Only an Admin or the owning Manager can record a Client Decision.';
  end if;
  if v_stage.status <> 'CLIENT_DECISION' then
    raise exception 'This stage is not currently ready for a Client Decision.';
  end if;

  select * into v_deliverable from pmt_deliverables where id = v_stage.deliverable_id;

  insert into pmt_client_decisions (id, deliverable_id, decision, client_revision, channel, contact_person, notes, recorded_by)
  values (gen_random_uuid()::text, v_deliverable.id, 'APPROVED', v_deliverable.client_revision, p_channel, p_contact_person, p_notes, pmt_current_pmt_id());

  perform set_config('pmt.cascade_context', 'true', true);

  update pmt_stages set status = 'COMPLETED' where id = p_stage_id;

  select * into v_next_stage from pmt_stages
    where deliverable_id = v_stage.deliverable_id and stage_order > v_stage.stage_order
    order by stage_order asc limit 1;

  if v_next_stage.id is not null then
    update pmt_stages set status = 'ACTIVE' where id = v_next_stage.id;
    update pmt_deliverables set status = 'IN_PROGRESS' where id = v_deliverable.id;

    for v_mgr in select id from pmt_users where role = 'MANAGER' and dept = v_next_stage.dept and status = 'ACTIVE'
    loop
      perform pmt_create_notification(v_mgr.id, 'CLIENT_APPROVED', 'Client approved — ' || v_next_stage.name || ' is now active.', null);
    end loop;
  else
    update pmt_deliverables set status = 'COMPLETED' where id = v_deliverable.id;

    select bool_and(status = 'COMPLETED') into v_all_other_completed
      from pmt_deliverables where campaign_id = v_deliverable.campaign_id and id <> v_deliverable.id;

    if coalesce(v_all_other_completed, true) then
      update pmt_campaigns set status = 'COMPLETED' where id = v_deliverable.campaign_id;
      insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
      values (gen_random_uuid()::text, 'CAMPAIGN', v_deliverable.campaign_id, 'Completed campaign', pmt_current_pmt_id());
    end if;

    insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
    values (gen_random_uuid()::text, 'DELIVERABLE', v_deliverable.id, 'Completed deliverable', pmt_current_pmt_id());
  end if;

  for v_mgr in select id from pmt_users where role = 'ADMIN' and status = 'ACTIVE'
  loop
    perform pmt_create_notification(v_mgr.id, 'CLIENT_APPROVED', 'Client approved ' || v_stage.name || '.', null);
  end loop;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'DELIVERABLE', v_deliverable.id, 'Client approved (Revision ' || v_deliverable.client_revision || ')', pmt_current_pmt_id());
end;
$$;

-- recordClientChanges(): server derives client_revision (never trusts the
-- browser), increments exactly by 1 (also enforced by the
-- pmt_deliverables_validate_transition trigger), records the decision +
-- feedback, and reopens the stage for rework. Deliberately does NOT
-- create Change Tasks — that is a separate, explicit action.
create or replace function pmt_record_client_changes(
  p_stage_id text, p_channel text, p_contact_person text, p_feedback text, p_notes text
)
returns void
language plpgsql
as $$
declare
  v_stage pmt_stages%rowtype;
  v_deliverable pmt_deliverables%rowtype;
  v_new_revision int;
  v_mgr record;
begin
  select * into v_stage from pmt_stages where id = p_stage_id;
  if not found then raise exception 'Stage not found.'; end if;
  if not pmt_can_manage_stage(p_stage_id) then
    raise exception 'Only an Admin or the owning Manager can record a Client Decision.';
  end if;
  if v_stage.status <> 'CLIENT_DECISION' then
    raise exception 'This stage is not currently ready for a Client Decision.';
  end if;
  if p_feedback is null or length(trim(p_feedback)) = 0 then
    raise exception 'Client feedback is required.';
  end if;
  if p_channel is null or length(trim(p_channel)) = 0 then
    raise exception 'Communication channel is required.';
  end if;

  select * into v_deliverable from pmt_deliverables where id = v_stage.deliverable_id;
  v_new_revision := v_deliverable.client_revision + 1;

  insert into pmt_client_decisions (id, deliverable_id, decision, client_revision, channel, contact_person, feedback, notes, recorded_by)
  values (gen_random_uuid()::text, v_deliverable.id, 'CHANGES_REQUESTED', v_new_revision, p_channel, p_contact_person, p_feedback, p_notes, pmt_current_pmt_id());

  insert into pmt_deliverable_feedback (id, deliverable_id, stage_id, client_revision, feedback_text, author_id)
  values (gen_random_uuid()::text, v_deliverable.id, p_stage_id, v_new_revision, p_feedback, pmt_current_pmt_id());

  update pmt_deliverables set client_revision = v_new_revision, status = 'CHANGES_REQUESTED' where id = v_deliverable.id;
  update pmt_stages set status = 'ACTIVE', rework_pending = true where id = p_stage_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'DELIVERABLE', v_deliverable.id, 'Client requested changes (Rev ' || v_new_revision || ')', pmt_current_pmt_id());

  for v_mgr in select id from pmt_users where role = 'MANAGER' and dept = v_stage.dept and status = 'ACTIVE'
  loop
    perform pmt_create_notification(v_mgr.id, 'CLIENT_CHANGES', 'Client requested changes (Revision ' || v_new_revision || ').', null);
  end loop;
end;
$$;

-- createChangeTasks(): multiple rows, one call. RLS's pmt_tasks_insert
-- policy already independently validates is_client_change/client_revision
-- against the current DB state for every inserted row — this function
-- adds the pre-flight checks and batches the inserts.
create or replace function pmt_create_change_tasks(p_stage_id text, p_tasks jsonb)
returns text[]
language plpgsql
as $$
declare
  v_stage pmt_stages%rowtype;
  v_deliverable pmt_deliverables%rowtype;
  v_task jsonb;
  v_next_order int;
  v_task_id text;
  v_ids text[] := '{}';
begin
  if not pmt_can_manage_stage(p_stage_id) then
    raise exception 'Not authorized to create Change Tasks in this stage''s department.';
  end if;

  select * into v_stage from pmt_stages where id = p_stage_id;
  select * into v_deliverable from pmt_deliverables where id = v_stage.deliverable_id;

  if v_deliverable.client_revision = 0 or v_deliverable.status <> 'CHANGES_REQUESTED' then
    raise exception 'Change Tasks can only be created during an active Client Changes cycle.';
  end if;

  select coalesce(max(task_order), 0) into v_next_order from pmt_tasks where stage_id = p_stage_id;

  for v_task in select * from jsonb_array_elements(p_tasks)
  loop
    if v_task->>'title' is null or length(trim(v_task->>'title')) = 0
       or v_task->>'assignee_id' is null or v_task->>'deadline' is null then
      raise exception 'Every Change Task needs a title, assignee, and deadline.';
    end if;
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

  return v_ids;
end;
$$;

commit;
