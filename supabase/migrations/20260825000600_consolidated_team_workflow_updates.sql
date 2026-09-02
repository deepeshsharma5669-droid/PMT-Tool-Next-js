-- Consolidated Project workflow. Requires canonical migrations 001-005.
begin;
alter table public.pmt_campaigns add column start_at timestamptz, add column end_at timestamptz,
 add column operational_status text not null default 'ACTIVE' check(operational_status in('ACTIVE','ON_HOLD')),
 add constraint pmt_projects_schedule_check check(end_at is null or start_at is null or end_at>=start_at);
alter table public.pmt_deliverables add column start_at timestamptz, add column end_at timestamptz,
 add column operational_status text not null default 'ACTIVE' check(operational_status in('ACTIVE','ON_HOLD')),
 add constraint pmt_deliverables_schedule_check check(end_at is null or start_at is null or end_at>=start_at);
alter table public.pmt_deliverables drop constraint pmt_deliverables_status_check;
alter table public.pmt_deliverables add constraint pmt_deliverables_status_check check(status in('IN_PROGRESS','CLIENT_REVIEW','CHANGES_REQUESTED','COMPLETED','DROPPED'));
alter table public.pmt_tasks add column start_at timestamptz, add column end_at timestamptz,
 add column reviewer_id uuid references public.pmt_users(id) on delete restrict,
 add column priority text not null default 'Medium' check(priority in('Low','Medium','High')),
 add column task_type text not null default 'PRODUCTION' check(task_type in('PRODUCTION','CLIENT_CHANGE')),
 add column operational_status text not null default 'ACTIVE' check(operational_status in('ACTIVE','ON_HOLD')),
 add constraint pmt_tasks_schedule_check check(end_at is null or start_at is null or end_at>=start_at);
-- Preserve legacy date-only deadlines as end-of-day Asia/Kolkata instants.
update public.pmt_campaigns set end_at=((deadline+1)::timestamp at time zone 'Asia/Kolkata')-interval '1 microsecond' where deadline is not null;
update public.pmt_tasks set end_at=((deadline+1)::timestamp at time zone 'Asia/Kolkata')-interval '1 microsecond',
 task_type=case when is_client_change then 'CLIENT_CHANGE' else 'PRODUCTION' end;
create index pmt_tasks_reviewer_queue_idx on public.pmt_tasks(reviewer_id,status,end_at);
create index pmt_projects_end_at_idx on public.pmt_campaigns(end_at);
create index pmt_deliverables_end_at_idx on public.pmt_deliverables(end_at);
create index pmt_tasks_end_at_idx on public.pmt_tasks(end_at);

create table public.pmt_change_requests(
 id uuid primary key default gen_random_uuid(),
 deliverable_id uuid not null references public.pmt_deliverables(id) on delete restrict,
 client_revision integer not null check(client_revision>0),
 client_poc_id uuid references public.pmt_client_pocs(id) on delete restrict,
 target_stage_id uuid not null references public.pmt_stages(id) on delete restrict,
 feedback text not null check(length(btrim(feedback))>0),
 status text not null default 'OPEN' check(status in('OPEN','IN_PROGRESS','ADDRESSED','RESOLVED','CANCELLED')),
 created_by uuid references public.pmt_users(id) on delete set null,
 created_at timestamptz not null default now(),resolved_by uuid references public.pmt_users(id) on delete set null,
 resolved_at timestamptz,
 unique(id,target_stage_id)
);
create index pmt_change_requests_revision_idx on public.pmt_change_requests(deliverable_id,client_revision,target_stage_id,status);
alter table public.pmt_stages add constraint pmt_stages_id_deliverable_key unique(id,deliverable_id);
alter table public.pmt_change_requests add constraint pmt_change_requests_stage_fk foreign key(target_stage_id,deliverable_id) references public.pmt_stages(id,deliverable_id);
alter table public.pmt_tasks add constraint pmt_tasks_id_stage_key unique(id,stage_id);
create table public.pmt_change_request_tasks(
 id uuid primary key default gen_random_uuid(),
 change_request_id uuid not null,task_id uuid not null,stage_id uuid not null,
 created_at timestamptz not null default now(),unique(change_request_id,task_id),
 foreign key(change_request_id,stage_id) references public.pmt_change_requests(id,target_stage_id) on delete restrict,
 foreign key(task_id,stage_id) references public.pmt_tasks(id,stage_id) on delete restrict
);
create index pmt_change_request_tasks_task_idx on public.pmt_change_request_tasks(task_id);
create table public.pmt_task_regularizations(
 id uuid primary key default gen_random_uuid(),task_id uuid not null references public.pmt_tasks(id) on delete restrict,
 user_id uuid not null references public.pmt_users(id) on delete restrict,
 actual_start_at timestamptz not null,actual_end_at timestamptz not null,
 reason text not null check(length(btrim(reason))>0),
 status text not null default 'PENDING' check(status in('PENDING','APPROVED','REJECTED')),
 requested_at timestamptz not null default now(),reviewed_by uuid references public.pmt_users(id) on delete restrict,
 reviewed_at timestamptz,manager_comment text,
 check(actual_end_at>=actual_start_at),
 check((status='PENDING' and reviewed_at is null and reviewed_by is null) or (status<>'PENDING' and reviewed_at is not null and reviewed_by is not null))
);
create index pmt_regularizations_task_idx on public.pmt_task_regularizations(task_id,requested_at desc);
create unique index pmt_regularizations_pending_idx on public.pmt_task_regularizations(task_id) where status='PENDING';

create function public.pmt_workflow_open(p_stage_id uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.pmt_stages s join public.pmt_deliverables d on d.id=s.deliverable_id join public.pmt_campaigns c on c.id=d.campaign_id
 where s.id=p_stage_id and d.status not in('DROPPED','COMPLETED') and d.operational_status='ACTIVE' and c.status='ACTIVE' and c.operational_status='ACTIVE')
$$;
create function public.pmt_guard_task_progress() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 -- Serialize workflow mutations against Deliverable drop/approval and Project holds.
 perform 1 from public.pmt_campaigns c join public.pmt_deliverables d on d.campaign_id=c.id join public.pmt_stages s on s.deliverable_id=d.id where s.id=new.stage_id for update of c,d;
 if not public.pmt_workflow_open(new.stage_id) then raise exception 'Project/Deliverable is closed, dropped, or on hold.';end if;
 if tg_op='UPDATE' and old.operational_status='ON_HOLD' and new.status<>old.status then raise exception 'Resume the Task before progressing its workflow.';end if;
 if new.status in('IN_PROGRESS','IN_REVIEW') and new.reviewer_id is null then raise exception 'Assign a Reviewer before progressing this Task.';end if;
 return new;
end;$$;
create trigger pmt_tasks_progress_guard before insert or update on public.pmt_tasks for each row execute function public.pmt_guard_task_progress();

create function public.pmt_validate_reviewer(p_stage_id uuid,p_reviewer_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not exists(select 1 from public.pmt_users u join public.pmt_stages s on s.dept=u.dept where s.id=p_stage_id and u.id=p_reviewer_id and u.status='ACTIVE' and u.role='MANAGER') then
 raise exception 'Choose an active Manager in the Stage department as Reviewer.';end if;
end;$$;
create or replace function public.pmt_can_review_task(p_task_id uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.pmt_tasks t where t.id=p_task_id and t.status='IN_REVIEW' and t.reviewer_id=public.pmt_current_pmt_id()
 and public.pmt_is_task_manager(t.stage_id) and public.pmt_workflow_open(t.stage_id) and t.operational_status='ACTIVE')
$$;

create function public.pmt_create_task_v2(p_stage_id uuid,p_title text,p_description text,p_assignee_id uuid,p_reviewer_id uuid,p_start_at timestamptz,p_end_at timestamptz,p_priority text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
 if not public.pmt_is_task_manager(p_stage_id) or not public.pmt_workflow_open(p_stage_id) then raise exception 'Only the responsible Manager can create Tasks in an open workflow.';end if;
 if p_end_at is null then raise exception 'Task end date/time is required.';end if;
 perform public.pmt_validate_reviewer(p_stage_id,p_reviewer_id);
 v_id:=public.pmt_create_task(p_stage_id,p_title,p_description,p_assignee_id,(p_end_at at time zone 'Asia/Kolkata')::date);
 update public.pmt_tasks set reviewer_id=p_reviewer_id,start_at=p_start_at,end_at=p_end_at,priority=p_priority where id=v_id;
 perform public.pmt_create_notification(p_reviewer_id,'REVIEWER_ASSIGNED','You are assigned to review: '||p_title,'TASK',v_id,'/tasks/'||v_id);
 return v_id;
end;$$;
create function public.pmt_update_task_v2(p_task_id uuid,p_title text,p_description text,p_assignee_id uuid,p_reviewer_id uuid,p_start_at timestamptz,p_end_at timestamptz,p_priority text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_tasks%rowtype;
begin
 select * into v from public.pmt_tasks where id=p_task_id for update;
 if not found or not public.pmt_is_task_manager(v.stage_id) then raise exception 'Only the responsible Manager may edit this Task.';end if;
 if v.status='APPROVED' and (v.title is distinct from p_title or v.description is distinct from p_description or v.assignee_id is distinct from p_assignee_id) then raise exception 'Approved work is immutable; only Reviewer/schedule governance is allowed until reopening.';end if;
 if v.status='IN_REVIEW' and (v.assignee_id is distinct from p_assignee_id or v.title is distinct from p_title or v.description is distinct from p_description) then raise exception 'Do not change submitted work or assignee during review.';end if;
 perform public.pmt_validate_task_assignee(v.stage_id,p_assignee_id);
 perform public.pmt_validate_reviewer(v.stage_id,p_reviewer_id);
 if p_end_at is null then raise exception 'Task end date/time is required.';end if;
 update public.pmt_tasks set title=p_title,description=p_description,assignee_id=p_assignee_id,reviewer_id=p_reviewer_id,start_at=p_start_at,end_at=p_end_at,deadline=(p_end_at at time zone 'Asia/Kolkata')::date,priority=p_priority where id=p_task_id;
 perform public.pmt_log_activity('TASK',p_task_id,'TASK_UPDATED');
 if v.assignee_id is distinct from p_assignee_id then
 perform public.pmt_log_activity('TASK',p_task_id,'TASK_REASSIGNED',jsonb_build_object('assignee_id',p_assignee_id));
 perform public.pmt_create_notification(p_assignee_id,'TASK_ASSIGNED','Task assigned: '||p_title,'TASK',p_task_id,'/tasks/'||p_task_id);end if;
 if v.reviewer_id is distinct from p_reviewer_id then
 perform public.pmt_log_activity('TASK',p_task_id,'TASK_REVIEWER_CHANGED',jsonb_build_object('reviewer_id',p_reviewer_id));
 perform public.pmt_create_notification(p_reviewer_id,'REVIEWER_ASSIGNED','Review responsibility: '||p_title,'TASK',p_task_id,'/tasks/'||p_task_id);end if;
end;$$;

create function public.pmt_set_operational_state(p_entity text,p_id uuid,p_state text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_allowed boolean;v_table text;v_rows bigint;
begin
 if p_state is null or p_state not in('ACTIVE','ON_HOLD') then raise exception 'Only Active or On Hold may be set manually.';end if;
 if p_entity='CAMPAIGN' then
 v_table:='pmt_campaigns';select public.pmt_is_admin() or exists(select 1 from public.pmt_deliverables d join public.pmt_stages s on s.deliverable_id=d.id where d.campaign_id=p_id and public.pmt_is_task_manager(s.id)) into v_allowed;
 elsif p_entity='DELIVERABLE' then
 v_table:='pmt_deliverables';select public.pmt_is_admin() or exists(select 1 from public.pmt_stages s where s.deliverable_id=p_id and public.pmt_is_task_manager(s.id)) into v_allowed;
 elsif p_entity='TASK' then
 v_table:='pmt_tasks';select public.pmt_is_admin() or public.pmt_is_task_manager(t.stage_id) into v_allowed from public.pmt_tasks t where t.id=p_id;
 else raise exception 'Invalid operational entity.';end if;
 if not coalesce(v_allowed,false) then raise exception 'Not authorized to manage this operational state.';end if;
 execute format('update public.%I set operational_status=$1 where id=$2 and status not in (''DROPPED'',''COMPLETED'',''APPROVED'')',v_table) using p_state,p_id;
 get diagnostics v_rows=row_count;
 if v_rows=0 then raise exception 'Object not found or workflow already closed.';end if;
 perform public.pmt_log_activity(p_entity,p_id,'STATUS_CHANGED',jsonb_build_object('operational_status',p_state));
end;$$;

create function public.pmt_set_schedule(p_entity text,p_id uuid,p_start_at timestamptz,p_end_at timestamptz)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_allowed boolean;v_table text;v_rows bigint;
begin
 if p_entity='CAMPAIGN' then v_table:='pmt_campaigns';select public.pmt_is_admin() or exists(select 1 from public.pmt_deliverables d join public.pmt_stages s on s.deliverable_id=d.id where d.campaign_id=p_id and public.pmt_is_task_manager(s.id)) into v_allowed;
 elsif p_entity='DELIVERABLE' then v_table:='pmt_deliverables';select public.pmt_is_admin() or exists(select 1 from public.pmt_stages s where s.deliverable_id=p_id and public.pmt_is_task_manager(s.id)) into v_allowed;
 else raise exception 'Use Task editing to change Task schedules.';end if;
 if not coalesce(v_allowed,false) then raise exception 'Not authorized.';end if;
 execute format('update public.%I set start_at=$1,end_at=$2 where id=$3',v_table) using p_start_at,p_end_at,p_id;
 get diagnostics v_rows=row_count;
 if v_rows=0 then raise exception 'Object not found.';end if;
 if p_entity='CAMPAIGN' then update public.pmt_campaigns set deadline=(p_end_at at time zone 'Asia/Kolkata')::date where id=p_id;end if;
 perform public.pmt_log_activity(p_entity,p_id,case when p_entity='CAMPAIGN' then 'PROJECT_UPDATED' else 'DELIVERABLE_UPDATED' end,jsonb_build_object('start_at',p_start_at,'end_at',p_end_at));
end;$$;

create function public.pmt_drop_deliverable(p_deliverable_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_deliverables%rowtype;r record;
begin
 select * into v from public.pmt_deliverables where id=p_deliverable_id for update;
 if not found or not(public.pmt_is_admin() or exists(select 1 from public.pmt_stages s where s.deliverable_id=v.id and public.pmt_is_task_manager(s.id))) then raise exception 'Not authorized to drop this Deliverable.';end if;
 if v.status in('COMPLETED','DROPPED') then raise exception 'This Deliverable is already closed.';end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'A drop reason is required.';end if;
 update public.pmt_change_requests set status='CANCELLED',resolved_at=now(),resolved_by=public.pmt_current_pmt_id() where deliverable_id=v.id and status not in('RESOLVED','CANCELLED');
 for r in update public.pmt_reworks set status='CANCELLED',completed_at=null,completed_by=null where deliverable_id=v.id and status in('OPEN','IN_PROGRESS') returning id loop
 perform public.pmt_log_activity('REWORK',r.id,'REWORK_CANCELLED',jsonb_build_object('reason',p_reason));end loop;
 update public.pmt_deliverables set status='DROPPED' where id=v.id;
 update public.pmt_stages set rework_pending=false where deliverable_id=v.id;
 perform public.pmt_log_activity('DELIVERABLE',v.id,'DELIVERABLE_DROPPED',jsonb_build_object('reason',p_reason));
end;$$;

-- Reopened Tasks keep their production evidence even after becoming Client Change Tasks.
create or replace function public.pmt_is_rework_target_eligible(p_deliverable_id uuid,p_stage_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.pmt_stages s where s.id=p_stage_id and s.deliverable_id=p_deliverable_id
 and (s.status in('COMPLETED','CLIENT_DECISION') or exists(select 1 from public.pmt_tasks t where t.stage_id=s.id
 and (t.status in('IN_REVIEW','CHANGES_REQUIRED','APPROVED') or exists(select 1 from public.pmt_submissions sub where sub.task_id=t.id)))))
$$;

create function public.pmt_revision_source_stage(p_deliverable_id uuid,p_client_revision integer)
returns uuid language sql stable security definer set search_path=public,pg_temp as $$
 select cd.stage_id from public.pmt_client_decisions cd
 where cd.deliverable_id=p_deliverable_id and cd.client_revision=p_client_revision and cd.decision='CHANGES_REQUESTED'
 order by cd.recorded_at,cd.id limit 1
$$;

create function public.pmt_revision_is_open(p_deliverable_id uuid,p_client_revision integer)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select public.pmt_revision_source_stage(p_deliverable_id,p_client_revision) is not null
 and not exists(
  select 1 from public.pmt_client_decisions cd
  where cd.deliverable_id=p_deliverable_id and cd.client_revision=p_client_revision and cd.decision='APPROVED'
    and cd.stage_id=public.pmt_revision_source_stage(p_deliverable_id,p_client_revision)
 )
$$;

create function public.pmt_is_valid_decision_source(p_deliverable_id uuid,p_stage_id uuid,p_client_revision integer)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.pmt_stages s where s.id=p_stage_id and s.deliverable_id=p_deliverable_id
 and (s.status='CLIENT_DECISION' or exists(select 1 from public.pmt_reworks rw where rw.deliverable_id=p_deliverable_id and rw.client_revision=p_client_revision and (rw.source_stage_id=s.id or rw.target_stage_id=s.id)))
 and (public.pmt_is_rework_target_eligible(p_deliverable_id,s.id) or exists(select 1 from public.pmt_reworks rw where rw.deliverable_id=p_deliverable_id and rw.client_revision=p_client_revision and (rw.source_stage_id=s.id or rw.target_stage_id=s.id))))
$$;

create function public.pmt_add_change_request(p_decision_stage_id uuid,p_target_stage_id uuid,p_client_poc_id uuid,p_channel text,p_feedback text,p_notes text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.pmt_stages%rowtype;t public.pmt_stages%rowtype;d public.pmt_deliverables%rowtype;p public.pmt_client_pocs%rowtype;
v_open boolean;v_id uuid:=gen_random_uuid();v_rework uuid;v_rework_exists boolean;
begin
 select * into s from public.pmt_stages where id=p_decision_stage_id for update;
 if not found or not public.pmt_can_manage_stage(s.id) or not public.pmt_workflow_open(s.id) then raise exception 'Only Admin or the responsible Manager can record Client Changes in an open workflow.';end if;
 select * into d from public.pmt_deliverables where id=s.deliverable_id for update;
 select * into t from public.pmt_stages where id=p_target_stage_id and deliverable_id=d.id for update;
 if not found or not public.pmt_is_rework_target_eligible(d.id,t.id) then raise exception 'Select a Stage that has actually produced work for this Deliverable.';end if;
 select p0.* into p from public.pmt_client_pocs p0 join public.pmt_campaign_pocs cp on cp.client_poc_id=p0.id
 where p0.id=p_client_poc_id and p0.status='ACTIVE' and cp.campaign_id=d.campaign_id and cp.client_id=p0.client_id;
 if not found then raise exception 'An active Project POC is required.';end if;
 if p_channel is null or p_channel not in('Email','Phone','WhatsApp','Meeting') or nullif(btrim(p_feedback),'') is null then raise exception 'Channel and feedback are required.';end if;
 v_open:=public.pmt_revision_is_open(d.id,d.client_revision);
 if not public.pmt_is_valid_decision_source(d.id,s.id,d.client_revision) then
  raise exception 'Feedback source must be a worked Stage participating in the current Client Decision or rework cycle.';
 end if;
 if not v_open then
  if s.status<>'CLIENT_DECISION' then raise exception 'A new revision requires a Stage awaiting Client Decision.';end if;
  d.client_revision:=d.client_revision+1;
 end if;
 insert into public.pmt_client_decisions(deliverable_id,stage_id,decision,client_revision,channel,contact_person,feedback,notes,recorded_by,client_poc_id)
 values(d.id,s.id,'CHANGES_REQUESTED',d.client_revision,p_channel,p.name,btrim(p_feedback),p_notes,public.pmt_current_pmt_id(),p.id);
 insert into public.pmt_change_requests(id,deliverable_id,client_revision,client_poc_id,target_stage_id,feedback,created_by)
 values(v_id,d.id,d.client_revision,p.id,t.id,btrim(p_feedback),public.pmt_current_pmt_id());
 select exists(select 1 from public.pmt_reworks where deliverable_id=d.id and client_revision=d.client_revision and target_stage_id=t.id) into v_rework_exists;
 insert into public.pmt_reworks(deliverable_id,source_stage_id,target_stage_id,client_revision,feedback,department,assigned_by,status)
 values(d.id,s.id,t.id,d.client_revision,btrim(p_feedback),t.dept,public.pmt_current_pmt_id(),'OPEN')
 on conflict(deliverable_id,client_revision,target_stage_id) do update set status='OPEN',completed_at=null,completed_by=null returning id into v_rework;
 update public.pmt_stages set status='PENDING' where id=s.id and id<>t.id and status='CLIENT_DECISION';
 update public.pmt_stages set status='ACTIVE',rework_pending=true where id=t.id;
 update public.pmt_deliverables set status='CHANGES_REQUESTED',client_revision=d.client_revision where id=d.id;
 perform public.pmt_log_activity('DELIVERABLE',d.id,'CLIENT_DECISION_CHANGES_REQUESTED',jsonb_build_object('change_request_id',v_id,'client_revision',d.client_revision));
 perform public.pmt_log_activity('DELIVERABLE',d.id,'CHANGE_REQUEST_CREATED',jsonb_build_object('change_request_id',v_id,'target_stage_id',t.id,'client_revision',d.client_revision));
 perform public.pmt_log_activity('REWORK',v_rework,case when v_rework_exists then 'REWORK_UPDATED' else 'REWORK_CREATED' end,jsonb_build_object('change_request_id',v_id));
 perform public.pmt_notify_department_managers(t.dept,'CLIENT_CHANGES','New Client feedback in Revision '||d.client_revision,'STAGE',t.id,'/stages/'||t.id);
 return v_id;
end;$$;

create function public.pmt_link_change_request(p_request_id uuid,p_task_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.pmt_change_requests%rowtype;t public.pmt_tasks%rowtype;v_revision integer;
begin
 select * into r from public.pmt_change_requests where id=p_request_id for update;
 if not found or not public.pmt_is_task_manager(r.target_stage_id) or not public.pmt_workflow_open(r.target_stage_id) then raise exception 'Only the target Stage Manager can link feedback.';end if;
 select client_revision into v_revision from public.pmt_deliverables where id=r.deliverable_id for update;
 if r.client_revision<>v_revision or r.status in('RESOLVED','CANCELLED') then raise exception 'Only current open revision feedback can be linked.';end if;
 select * into t from public.pmt_tasks where id=p_task_id and stage_id=r.target_stage_id for update;
 if not found then raise exception 'Task must belong to the targeted Stage.';end if;
 if exists(select 1 from public.pmt_change_request_tasks where change_request_id=r.id and task_id=t.id) then return;end if;
 perform public.pmt_validate_reviewer(t.stage_id,t.reviewer_id);
 if t.status='IN_REVIEW' then raise exception 'Wait for the assigned review before attaching more work.';end if;
 if t.status not in('APPROVED','IN_PROGRESS','CHANGES_REQUIRED','TODO') then raise exception 'Task cannot accept feedback now.';end if;
 if t.status='APPROVED' then
  update public.pmt_tasks set status='IN_PROGRESS',iteration=iteration+1,is_client_change=true,client_revision=v_revision,task_type='CLIENT_CHANGE' where id=t.id;
  perform public.pmt_log_activity('TASK',t.id,'TASK_REOPENED',jsonb_build_object('iteration',t.iteration+1,'client_revision',v_revision));
 else
  update public.pmt_tasks set is_client_change=true,client_revision=v_revision,task_type='CLIENT_CHANGE' where id=t.id;
 end if;
 insert into public.pmt_change_request_tasks(change_request_id,task_id,stage_id) values(r.id,t.id,t.stage_id);
 update public.pmt_change_requests set status='IN_PROGRESS' where id=r.id;
 update public.pmt_reworks set status='IN_PROGRESS',completed_at=null,completed_by=null where deliverable_id=r.deliverable_id and client_revision=v_revision and target_stage_id=r.target_stage_id;
 update public.pmt_stages set status='ACTIVE',rework_pending=true where id=t.stage_id;
 update public.pmt_deliverables set status='CHANGES_REQUESTED' where id=r.deliverable_id;
 perform public.pmt_log_activity('TASK',t.id,'CHANGE_REQUEST_LINKED_TO_TASK',jsonb_build_object('change_request_id',r.id));
 perform public.pmt_create_notification(t.assignee_id,'CLIENT_CHANGES','Client feedback attached to your Task.','TASK',t.id,'/tasks/'||t.id);
end;$$;

create function public.pmt_create_change_task_v2(p_request_id uuid,p_title text,p_description text,p_assignee_id uuid,p_reviewer_id uuid,p_start_at timestamptz,p_end_at timestamptz,p_priority text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.pmt_change_requests%rowtype;v_id uuid:=gen_random_uuid();v_order integer;v_revision integer;
begin
 select * into r from public.pmt_change_requests where id=p_request_id for update;
 if not found or not public.pmt_is_task_manager(r.target_stage_id) or not public.pmt_workflow_open(r.target_stage_id) then raise exception 'Only the target Stage Manager may create Change Tasks.';end if;
 select client_revision into v_revision from public.pmt_deliverables where id=r.deliverable_id for update;
 if r.client_revision<>v_revision or r.status in('RESOLVED','CANCELLED') then raise exception 'Feedback is not in an open current revision.';end if;
 perform 1 from public.pmt_stages where id=r.target_stage_id for update;
 perform public.pmt_validate_reviewer(r.target_stage_id,p_reviewer_id);
 perform public.pmt_validate_task_assignee(r.target_stage_id,p_assignee_id);
 if nullif(btrim(p_title),'') is null or p_end_at is null then raise exception 'Title and end date/time are required.';end if;
 select coalesce(max(task_order),0)+1 into v_order from public.pmt_tasks where stage_id=r.target_stage_id;
 insert into public.pmt_tasks(id,stage_id,title,description,assignee_id,reviewer_id,start_at,end_at,deadline,priority,status,task_order,is_client_change,client_revision,task_type)
 values(v_id,r.target_stage_id,p_title,coalesce(p_description,''),p_assignee_id,p_reviewer_id,p_start_at,p_end_at,(p_end_at at time zone 'Asia/Kolkata')::date,p_priority,'TODO',v_order,true,v_revision,'CLIENT_CHANGE');
 perform public.pmt_link_change_request(r.id,v_id);
 perform public.pmt_log_activity('TASK',v_id,'TASK_CREATED',jsonb_build_object('change_request_id',r.id,'reviewer_id',p_reviewer_id));
 perform public.pmt_create_notification(p_reviewer_id,'REVIEWER_ASSIGNED','You will review a new Change Task.','TASK',v_id,'/tasks/'||v_id);
 return v_id;
end;$$;

create function public.pmt_repair_task_reviewer(p_task_id uuid,p_reviewer_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.pmt_tasks%rowtype;
begin
 select * into t from public.pmt_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found.';end if;
 if not(public.pmt_is_admin() or public.pmt_is_task_manager(t.stage_id)) then
  raise exception 'Only Admin or the responsible Manager may repair a Task Reviewer.';
 end if;
 if t.reviewer_id is not null and exists(
  select 1 from public.pmt_users u join public.pmt_stages s on s.id=t.stage_id
  where u.id=t.reviewer_id and u.status='ACTIVE' and u.role='MANAGER' and u.dept=s.dept
 ) then raise exception 'The current Reviewer is still eligible; use normal Task editing to reassign them.';end if;
 perform public.pmt_validate_reviewer(t.stage_id,p_reviewer_id);
 if t.reviewer_id is not distinct from p_reviewer_id then return;end if;
 update public.pmt_tasks set reviewer_id=p_reviewer_id where id=t.id;
 perform public.pmt_log_activity('TASK',t.id,'TASK_REVIEWER_CHANGED',
  jsonb_build_object('old_reviewer_id',t.reviewer_id,'new_reviewer_id',p_reviewer_id,'legacy_repair',true));
 perform public.pmt_create_notification(p_reviewer_id,'REVIEWER_ASSIGNED',
  'You are assigned to review: '||t.title,'TASK',t.id,'/tasks/'||t.id);
end;$$;

create or replace function public.pmt_apply_stage_gate(p_stage_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.pmt_stages%rowtype;d public.pmt_deliverables%rowtype;v_count integer;v_pending integer;v_source uuid;r record;u record;
begin
 select * into s from public.pmt_stages where id=p_stage_id for update;
 if not found or s.status='COMPLETED' or not public.pmt_workflow_open(s.id) then return;end if;
 select * into d from public.pmt_deliverables where id=s.deliverable_id for update;
 select count(*) into v_count from public.pmt_change_requests where target_stage_id=s.id and client_revision=d.client_revision;
 if v_count>0 then
  for r in update public.pmt_change_requests cr set status='ADDRESSED'
   where cr.target_stage_id=s.id and cr.client_revision=d.client_revision and cr.status in('OPEN','IN_PROGRESS')
   and exists(select 1 from public.pmt_change_request_tasks l where l.change_request_id=cr.id)
   and not exists(select 1 from public.pmt_change_request_tasks l join public.pmt_tasks t on t.id=l.task_id where l.change_request_id=cr.id and t.status<>'APPROVED') returning id loop
    perform public.pmt_log_activity('DELIVERABLE',d.id,'CHANGE_REQUEST_UPDATED',jsonb_build_object('change_request_id',r.id,'status','ADDRESSED'));
  end loop;
  select count(*) into v_pending from public.pmt_change_requests where target_stage_id=s.id and client_revision=d.client_revision and status not in('ADDRESSED','RESOLVED','CANCELLED');
 else
  select count(*),count(*)filter(where status<>'APPROVED') into v_count,v_pending from public.pmt_tasks where stage_id=s.id;
 end if;
 if v_count=0 or v_pending>0 then return;end if;
 -- Feedback must never waive unfinished production or current-revision work.
 if exists(select 1 from public.pmt_tasks where stage_id=s.id and status<>'APPROVED' and (not is_client_change or client_revision=d.client_revision)) then return;end if;
 -- A cancelled feedback-only cycle is closed without discarding any linked work.
 if exists(select 1 from public.pmt_change_requests where target_stage_id=s.id and client_revision=d.client_revision)
 and not exists(select 1 from public.pmt_change_requests where target_stage_id=s.id and client_revision=d.client_revision and status<>'CANCELLED') then
  for r in update public.pmt_reworks set status='CANCELLED',completed_at=null,completed_by=null where target_stage_id=s.id and client_revision=d.client_revision and status in('OPEN','IN_PROGRESS') returning id loop
   perform public.pmt_log_activity('REWORK',r.id,'REWORK_CANCELLED');
  end loop;
 end if;
 for r in update public.pmt_reworks set status='COMPLETED',completed_at=now(),completed_by=public.pmt_current_pmt_id()
 where target_stage_id=s.id and client_revision=d.client_revision and status in('OPEN','IN_PROGRESS') returning id loop
  perform public.pmt_log_activity('REWORK',r.id,'REWORK_COMPLETED');
 end loop;
 if public.pmt_revision_is_open(d.id,d.client_revision) then
  update public.pmt_stages set status='COMPLETED',rework_pending=false where id=s.id;
  if not exists(select 1 from public.pmt_reworks where deliverable_id=d.id and client_revision=d.client_revision and status in('OPEN','IN_PROGRESS'))
     and not exists(select 1 from public.pmt_change_requests where deliverable_id=d.id and client_revision=d.client_revision and status in('OPEN','IN_PROGRESS')) then
   v_source:=public.pmt_revision_source_stage(d.id,d.client_revision);
   if v_source is null then raise exception 'Open revision has no canonical Client Decision source Stage.';end if;
   update public.pmt_stages set status='CLIENT_DECISION',rework_pending=false where id=v_source;
   update public.pmt_deliverables set status='CLIENT_REVIEW' where id=d.id;
   perform public.pmt_log_activity('STAGE',v_source,'STAGE_READY_FOR_CLIENT_DECISION',jsonb_build_object('client_revision',d.client_revision,'restored_after_targeted_rework',true));
   for u in select pu.id from public.pmt_users pu join public.pmt_stages src on src.id=v_source where pu.status='ACTIVE' and (pu.role='ADMIN' or(pu.role='MANAGER' and pu.dept=src.dept)) loop
    perform public.pmt_create_notification(u.id,'CLIENT_DECISION_READY','All targeted rework is complete; the original Stage is ready for the final Client Decision.','STAGE',v_source,'/stages/'||v_source);
   end loop;
  end if;
 else
  update public.pmt_stages set status='CLIENT_DECISION',rework_pending=false where id=s.id;
  update public.pmt_deliverables set status='CLIENT_REVIEW' where id=d.id;
  perform public.pmt_log_activity('STAGE',s.id,'STAGE_READY_FOR_CLIENT_DECISION');
  for u in select id from public.pmt_users where status='ACTIVE' and (role='ADMIN' or(role='MANAGER' and dept=s.dept)) loop
   perform public.pmt_create_notification(u.id,'CLIENT_DECISION_READY','Work is ready for Client Decision.','STAGE',s.id,'/stages/'||s.id);
  end loop;
 end if;
end;$$;

create or replace function public.pmt_record_client_approval_with_poc(p_stage_id uuid,p_client_poc_id uuid,p_channel text,p_notes text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.pmt_stages%rowtype;d public.pmt_deliverables%rowtype;p public.pmt_client_pocs%rowtype;
 v_anchor integer;v_source uuid;v_next public.pmt_stages%rowtype;v_id uuid:=gen_random_uuid();r record;x record;
begin
 select * into s from public.pmt_stages where id=p_stage_id for update;
 if not found or not public.pmt_can_manage_stage(s.id) or not public.pmt_workflow_open(s.id) then raise exception 'Only Admin or the responsible Manager may record this Client Decision.';end if;
 if s.status<>'CLIENT_DECISION' then raise exception 'Stage is not awaiting Client Decision.';end if;
 select * into d from public.pmt_deliverables where id=s.deliverable_id for update;
 if public.pmt_revision_is_open(d.id,d.client_revision) then
  v_source:=public.pmt_revision_source_stage(d.id,d.client_revision);
  if v_source is distinct from s.id then raise exception 'Final Client Approval must be recorded against the original Client Decision Stage.';end if;
 end if;
 if exists(select 1 from public.pmt_change_requests where deliverable_id=d.id and client_revision=d.client_revision and status not in('ADDRESSED','RESOLVED','CANCELLED')) then raise exception 'All feedback in this revision must be addressed before Client Approval.';end if;
 if exists(select 1 from public.pmt_change_requests cr left join public.pmt_change_request_tasks l on l.change_request_id=cr.id where cr.deliverable_id=d.id and cr.client_revision=d.client_revision and cr.status not in('RESOLVED','CANCELLED') and l.id is null) then raise exception 'Every active feedback item must have reviewed work before Client Approval.';end if;
 if exists(select 1 from public.pmt_change_requests cr join public.pmt_change_request_tasks l on l.change_request_id=cr.id join public.pmt_tasks t on t.id=l.task_id where cr.deliverable_id=d.id and cr.client_revision=d.client_revision and t.status<>'APPROVED') then raise exception 'Linked work still requires review, including work attached to cancelled feedback.';end if;
 if exists(select 1 from public.pmt_reworks where deliverable_id=d.id and client_revision=d.client_revision and status in('OPEN','IN_PROGRESS')) then raise exception 'Every affected rework Stage must finish before Client Approval.';end if;
 select p0.* into p from public.pmt_client_pocs p0 join public.pmt_campaign_pocs cp on cp.client_poc_id=p0.id where p0.id=p_client_poc_id and p0.status='ACTIVE' and cp.campaign_id=d.campaign_id and cp.client_id=p0.client_id;
 if not found then raise exception 'Select an active Project POC.';end if;
 if p_channel is null or p_channel not in('Email','Phone','WhatsApp','Meeting') then raise exception 'Invalid channel.';end if;
 v_anchor:=s.stage_order;
 for x in select * from public.pmt_stages where deliverable_id=d.id and stage_order<=v_anchor order by stage_order for update loop
  if x.status='COMPLETED' then continue;end if;
  if x.id=s.id and x.status='CLIENT_DECISION' then continue;end if;
  if exists(select 1 from public.pmt_reworks rw where rw.deliverable_id=d.id and rw.client_revision=d.client_revision and rw.source_stage_id=x.id)
     and public.pmt_is_valid_decision_source(d.id,x.id,d.client_revision) then continue;end if;
  if exists(select 1 from public.pmt_reworks rw where rw.deliverable_id=d.id and rw.client_revision=d.client_revision and rw.target_stage_id=x.id and rw.status in('COMPLETED','CANCELLED'))
     and x.status='CLIENT_DECISION' then continue;end if;
  raise exception 'Stage % cannot be completed because its workflow boundary is not independently satisfied.',x.name;
 end loop;
 if exists(select 1 from public.pmt_tasks t join public.pmt_stages st on st.id=t.stage_id where st.deliverable_id=d.id and st.stage_order<=v_anchor and t.status<>'APPROVED' and (not t.is_client_change or t.client_revision=d.client_revision)) then
  raise exception 'Unfinished work exists inside the proposed Client Approval boundary.';
 end if;
 insert into public.pmt_client_decisions(id,deliverable_id,stage_id,decision,client_revision,client_poc_id,contact_person,channel,notes,recorded_by)
 values(v_id,d.id,s.id,'APPROVED',d.client_revision,p.id,p.name,p_channel,p_notes,public.pmt_current_pmt_id());
 for r in update public.pmt_change_requests set status='RESOLVED',resolved_at=now(),resolved_by=public.pmt_current_pmt_id() where deliverable_id=d.id and client_revision=d.client_revision and status='ADDRESSED' returning id loop
  perform public.pmt_log_activity('DELIVERABLE',d.id,'CHANGE_REQUEST_RESOLVED',jsonb_build_object('change_request_id',r.id));
 end loop;
 update public.pmt_deliverable_feedback set resolved=true where deliverable_id=d.id and client_revision=d.client_revision;
 update public.pmt_stages set status='COMPLETED',rework_pending=false where deliverable_id=d.id and (
  id=s.id
  or id in(select source_stage_id from public.pmt_reworks where deliverable_id=d.id and client_revision=d.client_revision)
  or id in(select target_stage_id from public.pmt_reworks where deliverable_id=d.id and client_revision=d.client_revision and status in('COMPLETED','CANCELLED'))
 );
 perform public.pmt_log_activity('STAGE',s.id,'STAGE_COMPLETED',jsonb_build_object('client_revision',d.client_revision));
 select * into v_next from public.pmt_stages where deliverable_id=d.id and stage_order>v_anchor and status<>'COMPLETED' order by stage_order limit 1;
 if found then
  update public.pmt_stages set status='ACTIVE' where id=v_next.id;
  perform public.pmt_log_activity('STAGE',v_next.id,'STAGE_ACTIVATED');
  update public.pmt_deliverables set status='IN_PROGRESS' where id=d.id;
  perform public.pmt_notify_department_managers(v_next.dept,'CLIENT_APPROVED','Next Stage activated.','STAGE',v_next.id,'/stages/'||v_next.id);
 else
  update public.pmt_deliverables set status='COMPLETED' where id=d.id;
  perform public.pmt_log_activity('DELIVERABLE',d.id,'DELIVERABLE_COMPLETED');
  if not exists(select 1 from public.pmt_deliverables where campaign_id=d.campaign_id and status not in('COMPLETED','DROPPED')) then
   update public.pmt_campaigns set status='COMPLETED' where id=d.campaign_id;
   perform public.pmt_log_activity('CAMPAIGN',d.campaign_id,'PROJECT_COMPLETED');
  end if;
 end if;
 perform public.pmt_log_activity('DELIVERABLE',d.id,'CLIENT_DECISION_APPROVED',jsonb_build_object('decision_id',v_id,'client_revision',d.client_revision));
end;$$;

create or replace function public.pmt_change_deliverable_type(p_deliverable_id uuid,p_new_type text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.pmt_deliverables%rowtype;s record;j jsonb;v_template jsonb;v_count integer;v_order integer:=0;v_id uuid;
begin
 select * into d from public.pmt_deliverables where id=p_deliverable_id for update;
 if not found or not(public.pmt_is_admin() or exists(select 1 from public.pmt_stages where deliverable_id=d.id and public.pmt_is_task_manager(id))) then raise exception 'Not authorized to change this Deliverable type.';end if;
 if d.status<>'IN_PROGRESS' or d.operational_status<>'ACTIVE' then raise exception 'Type changes require active production, outside client review/rework.';end if;
 if not exists(select 1 from public.pmt_campaigns where id=d.campaign_id and status='ACTIVE' and operational_status='ACTIVE') then raise exception 'Project is closed or on hold.';end if;
 v_template:=public.pmt_stage_template(p_new_type);
 if v_template is null then raise exception 'Invalid Deliverable type.';end if;
 select count(*) into v_count from public.pmt_stages where deliverable_id=d.id;
 if v_count>jsonb_array_length(v_template) then raise exception 'This change would remove existing Stages. Their history must be preserved.';end if;
 for s in select * from public.pmt_stages where deliverable_id=d.id order by stage_order for update loop
  -- Preserve historical stage names and IDs; compatibility is department/order.
  if s.dept is distinct from (v_template->(s.stage_order-1)->>'dept') then raise exception 'New template would reorder or replace existing Stage responsibilities; this change is unsafe.';end if;
 end loop;
 for j in select value from jsonb_array_elements(v_template) loop
  v_order:=v_order+1;
  if v_order>v_count then
   insert into public.pmt_stages(deliverable_id,name,dept,stage_order,status) values(d.id,j->>'name',j->>'dept',v_order,'PENDING') returning id into v_id;
  end if;
 end loop;
 update public.pmt_deliverables set type=p_new_type where id=d.id;
 perform public.pmt_log_activity('DELIVERABLE',d.id,'DELIVERABLE_TYPE_CHANGED',jsonb_build_object('old_type',d.type,'new_type',p_new_type));
end;$$;

create function public.pmt_create_project_bundle(p_client_id uuid,p_name text,p_priority text,p_start_at timestamptz,p_end_at timestamptz,p_poc_ids uuid[],p_primary_poc_id uuid,p_ideation jsonb,p_brief jsonb,p_deliverables jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;j jsonb;v_doc uuid;
begin
 if not public.pmt_is_admin() then raise exception 'Only Admin may create Projects.';end if;
 if p_ideation is null or p_brief is null or nullif(btrim(p_ideation->>'title'),'') is null or nullif(btrim(p_brief->>'title'),'') is null then raise exception 'Ideation and Brief titles are required before Project creation.';end if;
 if jsonb_typeof(p_ideation)<>'object' or jsonb_typeof(p_brief)<>'object' then raise exception 'Ideation and Brief must be document objects.';end if;
 if jsonb_typeof(coalesce(p_ideation->'files','[]'))<>'array' or jsonb_typeof(coalesce(p_brief->'files','[]'))<>'array' then raise exception 'Document files must be arrays.';end if;
 if p_deliverables is null or jsonb_typeof(p_deliverables)<>'array' then raise exception 'Deliverables must be an array.';end if;
 if (select count(*)<>count(distinct btrim(value->>'name')) from jsonb_array_elements(p_deliverables)) then raise exception 'Use distinct Deliverable names within the Project.';end if;
 if (nullif(btrim(p_ideation->>'content'),'') is null and jsonb_array_length(coalesce(p_ideation->'files','[]'))=0)
 or (nullif(btrim(p_brief->>'content'),'') is null and jsonb_array_length(coalesce(p_brief->'files','[]'))=0) then raise exception 'Ideation and Brief each require content or a file link.';end if;
 v_id:=public.pmt_create_campaign_bundle(p_client_id,p_name,p_priority,(p_end_at at time zone 'Asia/Kolkata')::date,p_poc_ids,p_primary_poc_id,p_deliverables);
 update public.pmt_campaigns set start_at=p_start_at,end_at=p_end_at where id=v_id;
 perform public.pmt_create_campaign_document(v_id,'IDEATION',p_ideation->>'title',p_ideation->>'content',coalesce(p_ideation->'files','[]'));
 perform public.pmt_create_campaign_document(v_id,'BRIEF',p_brief->>'title',p_brief->>'content',coalesce(p_brief->'files','[]'));
 for j in select value from jsonb_array_elements(p_deliverables) loop
  update public.pmt_deliverables set start_at=nullif(j->>'start_at','')::timestamptz,end_at=nullif(j->>'end_at','')::timestamptz where campaign_id=v_id and name=btrim(j->>'name');
 end loop;
 perform public.pmt_log_activity('CAMPAIGN',v_id,'PROJECT_CREATED',jsonb_build_object('deliverable_count',jsonb_array_length(p_deliverables)));
 return v_id;
end;$$;

create function public.pmt_document_business_event() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_op='DELETE' then
  perform public.pmt_log_activity('CAMPAIGN',old.campaign_id,old.document_type||'_DELETED',jsonb_build_object('document_id',old.id));return old;
 else
  perform public.pmt_log_activity('CAMPAIGN',new.campaign_id,new.document_type||case when tg_op='INSERT' then '_CREATED' else '_UPDATED' end,jsonb_build_object('document_id',new.id));return new;
 end if;
end;$$;
create trigger pmt_documents_business_event after insert or update or delete on public.pmt_campaign_documents for each row execute function public.pmt_document_business_event();

create function public.pmt_request_regularization(p_task_id uuid,p_actual_start_at timestamptz,p_actual_end_at timestamptz,p_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.pmt_tasks%rowtype;v_id uuid;
begin
 select * into t from public.pmt_tasks where id=p_task_id for update;
 if not found or not public.pmt_is_active() or t.assignee_id is distinct from public.pmt_current_pmt_id() then raise exception 'You may request regularization only for your own Task.';end if;
 if p_actual_start_at is null or p_actual_end_at is null or p_actual_end_at>now() or p_actual_end_at<p_actual_start_at then raise exception 'Supply a valid completed actual time interval, not in the future.';end if;
 insert into public.pmt_task_regularizations(task_id,user_id,actual_start_at,actual_end_at,reason) values(t.id,public.pmt_current_pmt_id(),p_actual_start_at,p_actual_end_at,btrim(p_reason)) returning id into v_id;
 perform public.pmt_log_activity('TASK',t.id,'REGULARIZATION_REQUESTED',jsonb_build_object('regularization_id',v_id));
 perform public.pmt_notify_department_managers((select dept from public.pmt_stages where id=t.stage_id),'REGULARIZATION_REQUESTED','Review a Task time correction.','TASK',t.id,'/tasks/'||t.id,public.pmt_current_pmt_id());
 return v_id;
end;$$;
create function public.pmt_review_regularization(p_id uuid,p_approve boolean,p_comment text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.pmt_task_regularizations%rowtype;t public.pmt_tasks%rowtype;
begin
 select * into r from public.pmt_task_regularizations where id=p_id for update;
 if not found or r.status<>'PENDING' then raise exception 'Pending regularization not found.';end if;
 select * into t from public.pmt_tasks where id=r.task_id;
 if not public.pmt_is_task_manager(t.stage_id) or r.user_id=public.pmt_current_pmt_id() then raise exception 'A responsible Manager other than the requesting user must review.';end if;
 if p_approve is null or nullif(btrim(p_comment),'') is null then raise exception 'Decision and Manager comment are required.';end if;
 update public.pmt_task_regularizations set status=case when p_approve then 'APPROVED' else 'REJECTED' end,reviewed_by=public.pmt_current_pmt_id(),reviewed_at=now(),manager_comment=p_comment where id=r.id;
 perform public.pmt_log_activity('TASK',t.id,case when p_approve then 'REGULARIZATION_APPROVED' else 'REGULARIZATION_REJECTED' end,jsonb_build_object('regularization_id',r.id));
 perform public.pmt_create_notification(r.user_id,'REGULARIZATION_REVIEWED','Your time correction was '||case when p_approve then 'approved.' else 'rejected.' end,'TASK',t.id,'/tasks/'||t.id);
end;$$;

create function public.pmt_cancel_change_request(p_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.pmt_change_requests%rowtype;
begin
 select * into r from public.pmt_change_requests where id=p_id for update;
 if not found or not public.pmt_can_manage_stage(r.target_stage_id) or r.status in('RESOLVED','CANCELLED') then raise exception 'Not authorized or feedback already closed.';end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'A cancellation reason is required.';end if;
 if exists(select 1 from public.pmt_change_request_tasks l join public.pmt_tasks t on t.id=l.task_id where l.change_request_id=r.id and t.status<>'APPROVED') then
  raise exception 'Feedback cannot be cancelled while linked executable work remains unfinished.';
 end if;
 update public.pmt_change_requests set status='CANCELLED',resolved_by=public.pmt_current_pmt_id(),resolved_at=now() where id=r.id;
 perform public.pmt_log_activity('DELIVERABLE',r.deliverable_id,'CHANGE_REQUEST_UPDATED',jsonb_build_object('change_request_id',r.id,'status','CANCELLED','reason',p_reason));
 perform public.pmt_apply_stage_gate(r.target_stage_id);
end;$$;

-- Preserve active pre-006 rework as individual feedback; historical records remain intact.
do $$ declare r record;v_id uuid;begin
 for r in select * from public.pmt_reworks where status in('OPEN','IN_PROGRESS') loop
  insert into public.pmt_change_requests(deliverable_id,client_revision,target_stage_id,feedback,created_by,status)
  values(r.deliverable_id,r.client_revision,r.target_stage_id,r.feedback,r.assigned_by,'OPEN') returning id into v_id;
  insert into public.pmt_change_request_tasks(change_request_id,task_id,stage_id)
  select v_id,id,stage_id from public.pmt_tasks where stage_id=r.target_stage_id and client_revision=r.client_revision and is_client_change;
 end loop;
end;$$;

alter table public.pmt_change_requests enable row level security;
alter table public.pmt_change_request_tasks enable row level security;
alter table public.pmt_task_regularizations enable row level security;
create policy pmt_change_requests_select on public.pmt_change_requests for select to authenticated using(exists(select 1 from public.pmt_stages s where s.id=target_stage_id));
create policy pmt_change_request_tasks_select on public.pmt_change_request_tasks for select to authenticated using(exists(select 1 from public.pmt_tasks t where t.id=task_id));
create policy pmt_regularizations_select on public.pmt_task_regularizations for select to authenticated using(public.pmt_is_admin() or user_id=public.pmt_current_pmt_id() or exists(select 1 from public.pmt_tasks t where t.id=task_id and public.pmt_is_task_manager(t.stage_id)));
revoke all on table public.pmt_change_requests,public.pmt_change_request_tasks,public.pmt_task_regularizations from public,anon,authenticated;
grant select on table public.pmt_change_requests,public.pmt_change_request_tasks,public.pmt_task_regularizations to authenticated;

create or replace function public.pmt_start_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task public.pmt_tasks%rowtype;
begin
  select * into v_task from public.pmt_tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found.'; end if;
  if not public.pmt_is_active()
     or (public.pmt_current_user()).role not in ('MEMBER', 'MANAGER')
     or v_task.assignee_id is distinct from public.pmt_current_pmt_id() then
    raise exception 'You may only start work assigned to you.';
  end if;
  if v_task.status not in ('TODO', 'CHANGES_REQUIRED') then
    raise exception 'Task cannot be started from status %.', v_task.status;
  end if;

  update public.pmt_tasks
  set status = 'IN_PROGRESS',
      started_at = coalesce(started_at, now()),
      approved_at = null
  where id = p_task_id;

  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_STARTED',
    jsonb_build_object('previous_status', v_task.status, 'iteration', v_task.iteration)
  );
end;
$$;

create or replace function public.pmt_submit_task_for_review(
  p_task_id uuid,
  p_note text,
  p_options jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task public.pmt_tasks%rowtype;
  v_stage public.pmt_stages%rowtype;
  v_submission_id uuid := gen_random_uuid();
  v_option jsonb;
  v_option_id uuid;
  v_valid_count integer;
  v_i integer := 0;
begin
  select * into v_task from public.pmt_tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found.'; end if;
  if not public.pmt_is_active()
     or (public.pmt_current_user()).role not in ('MEMBER', 'MANAGER')
     or v_task.assignee_id is distinct from public.pmt_current_pmt_id() then
    raise exception 'You may only submit work assigned to you.';
  end if;
  if v_task.status <> 'IN_PROGRESS' then
    raise exception 'Task must be in progress before submission.';
  end if;
  perform public.pmt_validate_reviewer(v_task.stage_id,v_task.reviewer_id);
  if not public.pmt_workflow_open(v_task.stage_id) or v_task.operational_status<>'ACTIVE' then raise exception 'Workflow is closed or on hold.';end if;
  if p_options is null or jsonb_typeof(p_options) <> 'array' then
    raise exception 'Submission options must be an array.';
  end if;

  select count(*) into v_valid_count
  from jsonb_array_elements(p_options) option_row
  where length(btrim(option_row->>'name')) > 0
    and length(btrim(option_row->>'link')) > 0;
  if v_valid_count = 0 then
    raise exception 'Add at least one named option with a link.';
  end if;

  insert into public.pmt_submissions (
    id, task_id, submitted_by, note, submitted_at
  )
  values (
    v_submission_id, p_task_id, public.pmt_current_pmt_id(),
    nullif(btrim(p_note), ''), now()
  );

  for v_option in select value from jsonb_array_elements(p_options)
  loop
    if length(btrim(v_option->>'name')) = 0
       or length(btrim(v_option->>'link')) = 0 then
      continue;
    end if;
    v_i := v_i + 1;
    v_option_id := gen_random_uuid();
    insert into public.pmt_submission_options (
      id, submission_id, name, link, note, decision
    )
    values (
      v_option_id, v_submission_id,
      btrim(v_option->>'name'), btrim(v_option->>'link'),
      nullif(btrim(v_option->>'note'), ''), 'PENDING'
    );
  end loop;

  update public.pmt_tasks
  set status = 'IN_REVIEW', submitted_at = now()
  where id = p_task_id;

  perform public.pmt_log_activity(
    'SUBMISSION', v_submission_id, 'SUBMISSION_CREATED',
    jsonb_build_object('task_id', p_task_id, 'option_count', v_i)
  );
  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_SUBMITTED',
    jsonb_build_object('submission_id', v_submission_id, 'iteration', v_task.iteration)
  );

  select * into v_stage from public.pmt_stages where id = v_task.stage_id;
  perform public.pmt_create_notification(
    v_task.reviewer_id, 'SUBMISSION_RECEIVED', 'A submission is ready for your review: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text
  );

  return v_submission_id;
end;
$$;

create or replace function public.pmt_update_campaign(
  p_campaign_id uuid,
  p_name text,
  p_priority text,
  p_deadline date,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_old public.pmt_campaigns%rowtype;
  v_all_completed boolean;
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may update a campaign.';
  end if;
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception 'Campaign name is required.';
  end if;
  if p_priority not in ('Low', 'Medium', 'High') then
    raise exception 'Invalid campaign priority.';
  end if;
  if p_status not in ('ACTIVE', 'ARCHIVED', 'COMPLETED') then
    raise exception 'Invalid campaign status.';
  end if;

  select * into v_old from public.pmt_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Campaign not found.'; end if;

  if p_status = 'COMPLETED' then
    select count(*) > 0 and bool_and(status in ('COMPLETED','DROPPED'))
    into v_all_completed
    from public.pmt_deliverables
    where campaign_id = p_campaign_id;
    if not coalesce(v_all_completed, false) then
      raise exception 'Campaign cannot complete until all deliverables are completed.';
    end if;
  end if;

  update public.pmt_campaigns
  set name = btrim(p_name), priority = p_priority,
      deadline = p_deadline,
      end_at = case when p_deadline is distinct from v_old.deadline then ((p_deadline+1)::timestamp at time zone 'Asia/Kolkata')-interval '1 microsecond' else end_at end,
      status = p_status
  where id = p_campaign_id;

  perform public.pmt_log_activity(
    'CAMPAIGN', p_campaign_id, 'PROJECT_UPDATED',
    jsonb_build_object(
      'old_name', v_old.name, 'new_name', btrim(p_name),
      'old_priority', v_old.priority, 'new_priority', p_priority,
      'old_deadline', v_old.deadline, 'new_deadline', p_deadline,
      'old_status', v_old.status, 'new_status', p_status
    )
  );
end;
$$;

-- Replaced mutation entry points are internal only; callers use the v2/Project RPCs.
revoke execute on function public.pmt_create_campaign(uuid,text,date,jsonb),public.pmt_create_campaign_bundle(uuid,text,text,date,uuid[],uuid,jsonb),
 public.pmt_create_task(uuid,text,text,uuid,date),public.pmt_create_change_tasks(uuid,jsonb),
 public.pmt_update_task(uuid,text,text),public.pmt_assign_task(uuid,uuid),public.pmt_change_deadline(uuid,date),
 public.pmt_record_targeted_client_changes(uuid,uuid,uuid,text,text,text),public.pmt_cancel_rework(uuid) from public,anon,authenticated;
do $$ declare r record;begin
 for r in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('pmt_workflow_open','pmt_guard_task_progress','pmt_validate_reviewer','pmt_revision_is_open','pmt_revision_source_stage','pmt_is_valid_decision_source','pmt_create_task_v2','pmt_update_task_v2','pmt_repair_task_reviewer','pmt_set_operational_state','pmt_set_schedule','pmt_drop_deliverable','pmt_add_change_request','pmt_link_change_request','pmt_create_change_task_v2','pmt_create_project_bundle','pmt_document_business_event','pmt_request_regularization','pmt_review_regularization','pmt_cancel_change_request') loop
  execute format('revoke all on function %s from public,anon,authenticated',r.signature);
  if r.proname in('pmt_create_task_v2','pmt_update_task_v2','pmt_repair_task_reviewer','pmt_set_operational_state','pmt_set_schedule','pmt_drop_deliverable','pmt_add_change_request','pmt_link_change_request','pmt_create_change_task_v2','pmt_create_project_bundle','pmt_request_regularization','pmt_review_regularization','pmt_cancel_change_request') then execute format('grant execute on function %s to authenticated',r.signature);end if;
 end loop;
end;$$;
commit;
