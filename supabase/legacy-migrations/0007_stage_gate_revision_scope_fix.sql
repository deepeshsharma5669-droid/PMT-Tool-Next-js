-- Fix Stage gate revision scope while retaining Deliverable-level client_revision.
-- Replaces only the three affected workflow RPC definitions.
-- Does not alter RLS, Auth, permissions, tables, constraints, or existing data.

begin;

create or replace function pmt_apply_stage_gate(p_stage_id text)
returns void
language plpgsql
as $$
declare
  v_stage pmt_stages%rowtype;
  v_deliverable pmt_deliverables%rowtype;
  v_gate_mode text;
  v_all_approved boolean;
begin
  select * into v_stage from pmt_stages where id = p_stage_id;
  select * into v_deliverable from pmt_deliverables where id = v_stage.deliverable_id;

  if v_stage.status = 'COMPLETED' then
    return;
  end if;

  select case when exists (
    select 1 from pmt_tasks
    where stage_id = p_stage_id
      and is_client_change = true
      and client_revision = v_deliverable.client_revision
  ) then 'CLIENT_REWORK' else 'NORMAL_PRODUCTION' end
  into v_gate_mode;

  if v_gate_mode = 'CLIENT_REWORK' then
    select bool_and(status = 'APPROVED') and count(*) > 0
      into v_all_approved
      from pmt_tasks
      where stage_id = p_stage_id
        and is_client_change = true
        and client_revision = v_deliverable.client_revision;
  else
    select bool_and(status = 'APPROVED') and count(*) > 0
      into v_all_approved
      from pmt_tasks
      where stage_id = p_stage_id
        and is_client_change = false
        and client_revision is null;
  end if;

  if v_all_approved then
    update pmt_stages set rework_pending = false, status = 'CLIENT_DECISION' where id = p_stage_id;
    update pmt_deliverables set status = 'CLIENT_REVIEW' where id = v_deliverable.id;
  end if;
end;
$$;

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
  update pmt_stages set status = 'ACTIVE', rework_pending = false where id = p_stage_id;

  insert into pmt_activity (id, entity_type, entity_id, action, actor_id)
  values (gen_random_uuid()::text, 'DELIVERABLE', v_deliverable.id, 'Client requested changes (Rev ' || v_new_revision || ')', pmt_current_pmt_id());

  for v_mgr in select id from pmt_users where role = 'MANAGER' and dept = v_stage.dept and status = 'ACTIVE'
  loop
    perform pmt_create_notification(v_mgr.id, 'CLIENT_CHANGES', 'Client requested changes (Revision ' || v_new_revision || ').', null);
  end loop;
end;
$$;

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

commit;
