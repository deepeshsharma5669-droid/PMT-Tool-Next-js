-- Client POCs, campaign contacts/documents, multi-deliverable creation, and targeted rework.
-- Requires: 20260825000300_client_management.sql
begin;

create table public.pmt_client_pocs(
 id uuid primary key default gen_random_uuid(),client_id uuid not null references public.pmt_clients(id) on delete cascade,
 name text not null check(length(btrim(name))>0),designation text,email text,phone text,whatsapp text,
 is_primary boolean not null default false,status text not null default 'ACTIVE' check(status in('ACTIVE','INACTIVE')),notes text,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 constraint pmt_client_pocs_inactive_not_primary check(status='ACTIVE' or not is_primary),
 constraint pmt_client_pocs_id_client_key unique(id,client_id)
);
create index pmt_client_pocs_client_status_idx on public.pmt_client_pocs(client_id,status);
create unique index pmt_client_pocs_one_primary_idx on public.pmt_client_pocs(client_id) where is_primary;
create trigger pmt_client_pocs_set_updated_at before update on public.pmt_client_pocs for each row execute function public.pmt_set_updated_at();

alter table public.pmt_campaigns add constraint pmt_campaigns_id_client_key unique(id,client_id);
create table public.pmt_campaign_pocs(
 id uuid primary key default gen_random_uuid(),campaign_id uuid not null,client_id uuid not null,client_poc_id uuid not null,
 is_primary boolean not null default false,created_at timestamptz not null default now(),unique(campaign_id,client_poc_id),
 constraint pmt_campaign_pocs_campaign_client_fk foreign key(campaign_id,client_id) references public.pmt_campaigns(id,client_id) on delete cascade,
 constraint pmt_campaign_pocs_poc_client_fk foreign key(client_poc_id,client_id) references public.pmt_client_pocs(id,client_id) on delete restrict
);
create index pmt_campaign_pocs_campaign_idx on public.pmt_campaign_pocs(campaign_id);
create unique index pmt_campaign_pocs_one_primary_idx on public.pmt_campaign_pocs(campaign_id) where is_primary;

-- Check final transaction state: intermediate demotion/promotion is permitted.
-- Campaign deletion cascades may remove every association; surviving Campaigns may not.
create function public.pmt_assert_campaign_primary_poc(p_campaign_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_count integer;v_primary_count integer;v_primary_active boolean;
begin
 perform 1 from public.pmt_campaigns where id=p_campaign_id for update;
 if not found then return;end if;
 -- Keep a concurrently deactivated POC from passing an active-primary check.
 perform 1 from public.pmt_client_pocs p join public.pmt_campaign_pocs cp on cp.client_poc_id=p.id
  where cp.campaign_id=p_campaign_id and cp.is_primary for share of p;
 select count(*),count(*) filter(where cp.is_primary),coalesce(bool_and(not cp.is_primary or p.status='ACTIVE'),true)
 into v_count,v_primary_count,v_primary_active
 from public.pmt_campaign_pocs cp join public.pmt_client_pocs p on p.id=cp.client_poc_id and p.client_id=cp.client_id
 where cp.campaign_id=p_campaign_id;
 if v_count=0 then raise exception 'A Campaign requires at least one POC.';end if;
 if v_primary_count<>1 then raise exception 'A Campaign requires exactly one Primary POC.';end if;
 if not v_primary_active then raise exception 'A Campaign Primary POC must be active.';end if;
end;$$;

create function public.pmt_check_campaign_primary_poc()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_campaign_id uuid;
begin
 if tg_table_name='pmt_client_pocs' then
  for v_campaign_id in select distinct campaign_id from public.pmt_campaign_pocs where client_poc_id=new.id order by campaign_id loop
   perform public.pmt_assert_campaign_primary_poc(v_campaign_id);
  end loop;
 else
  if tg_op<>'INSERT' then perform public.pmt_assert_campaign_primary_poc(old.campaign_id);end if;
  if tg_op<>'DELETE' then perform public.pmt_assert_campaign_primary_poc(new.campaign_id);end if;
 end if;
 return null;
end;$$;
create constraint trigger pmt_campaign_pocs_exactly_one_primary
 after insert or update or delete on public.pmt_campaign_pocs
 deferrable initially deferred for each row execute function public.pmt_check_campaign_primary_poc();
create constraint trigger pmt_client_pocs_campaign_primary_active
 after update of status on public.pmt_client_pocs
 deferrable initially deferred for each row when(old.status is distinct from new.status)
 execute function public.pmt_check_campaign_primary_poc();

-- Internal helper: callers hold the Client/POC locks and subsequently set INACTIVE.
create function public.pmt_prepare_client_poc_inactivation(p_poc_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;v_campaign_id uuid;v_next uuid;
begin
 select * into v from public.pmt_client_pocs where id=p_poc_id for update;
 if not found then raise exception 'Client POC not found.';end if;
 if v.is_primary then
  update public.pmt_client_pocs set is_primary=false where id=p_poc_id;
  select id into v_next from public.pmt_client_pocs where client_id=v.client_id and id<>p_poc_id and status='ACTIVE' order by created_at,id limit 1 for update;
  if v_next is not null then
   update public.pmt_client_pocs set is_primary=true where id=v_next;
   perform public.pmt_log_activity('CLIENT',v_next,'CLIENT_POC_PRIMARY_CHANGED',jsonb_build_object('client_id',v.client_id,'previous_poc_id',p_poc_id));
  end if;
 end if;
 for v_campaign_id in select campaign_id from public.pmt_campaign_pocs where client_poc_id=p_poc_id and is_primary order by campaign_id loop
  perform 1 from public.pmt_campaigns where id=v_campaign_id for update;
  select cp.id into v_next from public.pmt_campaign_pocs cp join public.pmt_client_pocs p on p.id=cp.client_poc_id
   where cp.campaign_id=v_campaign_id and cp.client_poc_id<>p_poc_id and p.status='ACTIVE' order by cp.created_at,cp.id limit 1;
  if v_next is null then raise exception 'Add another active Campaign POC before deactivating its Primary POC.';end if;
  update public.pmt_campaign_pocs set is_primary=false where campaign_id=v_campaign_id and is_primary;
  update public.pmt_campaign_pocs set is_primary=true where id=v_next;
  perform public.pmt_log_activity('CAMPAIGN',v_campaign_id,'CAMPAIGN_POC_PRIMARY_CHANGED',jsonb_build_object('previous_client_poc_id',p_poc_id,'campaign_poc_id',v_next));
 end loop;
end;$$;
revoke all on function public.pmt_assert_campaign_primary_poc(uuid),public.pmt_check_campaign_primary_poc(),public.pmt_prepare_client_poc_inactivation(uuid) from public,anon,authenticated;

create table public.pmt_campaign_documents(
 id uuid primary key default gen_random_uuid(),campaign_id uuid not null references public.pmt_campaigns(id) on delete cascade,
 document_type text not null check(document_type in('IDEATION','BRIEF')),title text not null check(length(btrim(title))>0),content text not null default '',
 created_by uuid references public.pmt_users(id) on delete set null,updated_by uuid references public.pmt_users(id) on delete set null,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(campaign_id,document_type)
);
create trigger pmt_campaign_documents_set_updated_at before update on public.pmt_campaign_documents for each row execute function public.pmt_set_updated_at();
create table public.pmt_campaign_document_files(
 id uuid primary key default gen_random_uuid(),document_id uuid not null references public.pmt_campaign_documents(id) on delete cascade,
 file_name text not null check(length(btrim(file_name))>0),file_url text not null check(length(btrim(file_url))>0),
 created_by uuid references public.pmt_users(id) on delete set null,created_at timestamptz not null default now()
);
create index pmt_campaign_document_files_document_idx on public.pmt_campaign_document_files(document_id);

alter table public.pmt_client_decisions add column client_poc_id uuid references public.pmt_client_pocs(id) on delete set null;
create index pmt_client_decisions_poc_idx on public.pmt_client_decisions(client_poc_id);

create function public.pmt_create_client_poc(p_client_id uuid,p_name text,p_designation text,p_email text,p_phone text,p_whatsapp text,p_is_primary boolean,p_notes text)
returns public.pmt_client_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may create Client POCs.';end if;
 perform 1 from public.pmt_clients where id=p_client_id for update;if not found then raise exception 'Client not found.';end if;
 if p_name is null or length(btrim(p_name))=0 then raise exception 'POC name is required.';end if;
 if p_is_primary then update public.pmt_client_pocs set is_primary=false where client_id=p_client_id and is_primary;end if;
 insert into public.pmt_client_pocs(client_id,name,designation,email,phone,whatsapp,is_primary,notes)
 values(p_client_id,btrim(p_name),nullif(btrim(p_designation),''),nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_whatsapp),''),coalesce(p_is_primary,false),nullif(btrim(p_notes),'')) returning * into v;
 perform public.pmt_log_activity('CLIENT',v.id,'CLIENT_POC_CREATED',jsonb_build_object('client_id',p_client_id,'name',v.name,'is_primary',v.is_primary));return v;
end;$$;
create function public.pmt_update_client_poc(p_poc_id uuid,p_name text,p_designation text,p_email text,p_phone text,p_whatsapp text,p_is_primary boolean,p_status text,p_notes text)
returns public.pmt_client_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may update Client POCs.';end if;
 perform 1 from public.pmt_clients where id=(select client_id from public.pmt_client_pocs where id=p_poc_id) for update;
 select * into v from public.pmt_client_pocs where id=p_poc_id for update;if not found then raise exception 'Client POC not found.';end if;
 if p_name is null or length(btrim(p_name))=0 then raise exception 'POC name is required.';end if;if p_status is null or p_status not in('ACTIVE','INACTIVE') then raise exception 'Invalid POC status.';end if;
 if p_status='INACTIVE' then perform public.pmt_prepare_client_poc_inactivation(p_poc_id);
 elsif p_is_primary then update public.pmt_client_pocs set is_primary=false where client_id=v.client_id and id<>p_poc_id and is_primary;end if;
 update public.pmt_client_pocs set name=btrim(p_name),designation=nullif(btrim(p_designation),''),email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),whatsapp=nullif(btrim(p_whatsapp),''),is_primary=(p_status='ACTIVE' and coalesce(p_is_primary,false)),status=p_status,notes=nullif(btrim(p_notes),'') where id=p_poc_id returning * into v;
 perform public.pmt_log_activity('CLIENT',p_poc_id,'CLIENT_POC_UPDATED',jsonb_build_object('client_id',v.client_id,'name',v.name,'status',v.status));return v;
end;$$;
create function public.pmt_deactivate_client_poc(p_poc_id uuid) returns public.pmt_client_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may deactivate Client POCs.';end if;
 perform 1 from public.pmt_clients where id=(select client_id from public.pmt_client_pocs where id=p_poc_id) for update;
 perform public.pmt_prepare_client_poc_inactivation(p_poc_id);
 update public.pmt_client_pocs set status='INACTIVE',is_primary=false where id=p_poc_id returning * into v;
 perform public.pmt_log_activity('CLIENT',p_poc_id,'CLIENT_POC_DEACTIVATED',jsonb_build_object('client_id',v.client_id,'name',v.name));return v;
end;$$;

create function public.pmt_add_campaign_poc(p_campaign_id uuid,p_client_poc_id uuid,p_is_primary boolean) returns public.pmt_campaign_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_campaign_pocs%rowtype;v_client_id uuid;v_make_primary boolean;
begin if not public.pmt_is_admin() then raise exception 'Only an Admin may manage Campaign POCs.';end if;
 perform 1 from public.pmt_clients where id=(select client_id from public.pmt_campaigns where id=p_campaign_id) for update;
 select client_id into v_client_id from public.pmt_campaigns where id=p_campaign_id for update;if not found then raise exception 'Campaign not found.';end if;
 if not exists(select 1 from public.pmt_client_pocs where id=p_client_poc_id and client_id=v_client_id and status='ACTIVE') then raise exception 'Active POC does not belong to the Campaign Client.';end if;
 v_make_primary:=coalesce(p_is_primary,false) or not exists(select 1 from public.pmt_campaign_pocs where campaign_id=p_campaign_id);
 if v_make_primary then update public.pmt_campaign_pocs set is_primary=false where campaign_id=p_campaign_id and is_primary;end if;
 insert into public.pmt_campaign_pocs(campaign_id,client_id,client_poc_id,is_primary) values(p_campaign_id,v_client_id,p_client_poc_id,v_make_primary)
 on conflict(campaign_id,client_poc_id) do update set is_primary=(excluded.is_primary or pmt_campaign_pocs.is_primary) returning * into v;
 perform public.pmt_log_activity('CAMPAIGN',p_campaign_id,'CAMPAIGN_POC_ADDED',jsonb_build_object('client_poc_id',p_client_poc_id,'is_primary',v.is_primary));return v;end;$$;
create function public.pmt_remove_campaign_poc(p_campaign_id uuid,p_client_poc_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_primary boolean;v_remaining uuid;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may manage Campaign POCs.';end if;
 perform 1 from public.pmt_clients where id=(select client_id from public.pmt_campaigns where id=p_campaign_id) for update;
 perform 1 from public.pmt_campaigns where id=p_campaign_id for update;if not found then raise exception 'Campaign not found.';end if;
 if(select count(*) from public.pmt_campaign_pocs where campaign_id=p_campaign_id)<=1 then raise exception 'A Campaign requires at least one POC.';end if;
 delete from public.pmt_campaign_pocs where campaign_id=p_campaign_id and client_poc_id=p_client_poc_id returning is_primary into v_primary;
 if not found then raise exception 'Campaign POC not found.';end if;
 if v_primary then
  select cp.id into v_remaining from public.pmt_campaign_pocs cp join public.pmt_client_pocs p on p.id=cp.client_poc_id
   where cp.campaign_id=p_campaign_id and p.status='ACTIVE' order by cp.created_at,cp.id limit 1;
  if v_remaining is null then raise exception 'Another active Campaign POC is required before removing its Primary POC.';end if;
  update public.pmt_campaign_pocs set is_primary=true where id=v_remaining;
  perform public.pmt_log_activity('CAMPAIGN',p_campaign_id,'CAMPAIGN_POC_PRIMARY_CHANGED',jsonb_build_object('previous_client_poc_id',p_client_poc_id,'campaign_poc_id',v_remaining));
 end if;
 perform public.pmt_log_activity('CAMPAIGN',p_campaign_id,'CAMPAIGN_POC_REMOVED',jsonb_build_object('client_poc_id',p_client_poc_id));
end;$$;

create function public.pmt_create_campaign_bundle(p_client_id uuid,p_name text,p_priority text,p_deadline date,p_poc_ids uuid[],p_primary_poc_id uuid,p_deliverables jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_campaign uuid:=gen_random_uuid();v_poc uuid;v_primary_poc_id uuid;v_d jsonb;v_did uuid;v_s jsonb;v_sid uuid;v_order int;v_type text;v_name text;v_manager record;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may create a Campaign.';end if;perform 1 from public.pmt_clients where id=p_client_id and status='ACTIVE' for update;if not found then raise exception 'Active Client not found.';end if;
 if p_name is null or length(btrim(p_name))=0 then raise exception 'Campaign name is required.';end if;if p_priority not in('Low','Medium','High') then raise exception 'Invalid Campaign priority.';end if;
 if coalesce(array_length(p_poc_ids,1),0)=0 then raise exception 'At least one Campaign POC is required.';end if;
 v_primary_poc_id:=coalesce(p_primary_poc_id,p_poc_ids[array_lower(p_poc_ids,1)]);
 if v_primary_poc_id is null or not(v_primary_poc_id=any(p_poc_ids)) then raise exception 'The Primary POC must be selected for this Campaign.';end if;
 if (select count(distinct id) from public.pmt_client_pocs where id=any(p_poc_ids) and client_id=p_client_id and status='ACTIVE')<>array_length(p_poc_ids,1) then raise exception 'Every Campaign POC must be active and belong to the selected Client.';end if;
 if p_deliverables is null or jsonb_typeof(p_deliverables)<>'array' or jsonb_array_length(p_deliverables)=0 then raise exception 'At least one Deliverable is required.';end if;
 insert into public.pmt_campaigns(id,client_id,name,priority,deadline,status,created_by) values(v_campaign,p_client_id,btrim(p_name),p_priority,p_deadline,'ACTIVE',public.pmt_current_pmt_id());
 perform public.pmt_log_activity('CAMPAIGN',v_campaign,'CAMPAIGN_CREATED',jsonb_build_object('name',btrim(p_name),'client_id',p_client_id,'deliverable_count',jsonb_array_length(p_deliverables)));
 foreach v_poc in array p_poc_ids loop insert into public.pmt_campaign_pocs(campaign_id,client_id,client_poc_id,is_primary) values(v_campaign,p_client_id,v_poc,v_poc=v_primary_poc_id);perform public.pmt_log_activity('CAMPAIGN',v_campaign,'CAMPAIGN_POC_ADDED',jsonb_build_object('client_poc_id',v_poc,'is_primary',v_poc=v_primary_poc_id));end loop;
 for v_d in select value from jsonb_array_elements(p_deliverables) loop v_type:=v_d->>'type';v_name:=btrim(v_d->>'name');if v_name is null or length(v_name)=0 then raise exception 'Every Deliverable requires a name.';end if;if public.pmt_stage_template(v_type)is null then raise exception 'Invalid Deliverable type.';end if;
  v_did:=gen_random_uuid();insert into public.pmt_deliverables(id,campaign_id,name,type,status,client_revision)values(v_did,v_campaign,v_name,v_type,'IN_PROGRESS',0);perform public.pmt_log_activity('DELIVERABLE',v_did,'DELIVERABLE_CREATED',jsonb_build_object('campaign_id',v_campaign,'type',v_type));v_order:=0;
  for v_s in select value from jsonb_array_elements(public.pmt_stage_template(v_type)) loop v_order:=v_order+1;v_sid:=gen_random_uuid();insert into public.pmt_stages(id,deliverable_id,name,dept,stage_order,status,rework_pending)values(v_sid,v_did,v_s->>'name',v_s->>'dept',v_order,case when v_order=1 then'ACTIVE'else'PENDING'end,false);if v_order=1 then perform public.pmt_log_activity('STAGE',v_sid,'STAGE_ACTIVATED',jsonb_build_object('deliverable_id',v_did,'dept',v_s->>'dept'));perform public.pmt_notify_department_managers(v_s->>'dept','STAGE_ACTIVATED','A new Campaign stage is ready: '||(v_s->>'name'),'STAGE',v_sid,'/stages/'||v_sid::text);end if;end loop;
 end loop;return v_campaign;end;$$;

create function public.pmt_is_rework_target_eligible(p_deliverable_id uuid,p_stage_id uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.pmt_stages s where s.id=p_stage_id and s.deliverable_id=p_deliverable_id and (s.status in('COMPLETED','CLIENT_DECISION') or exists(select 1 from public.pmt_tasks t where t.stage_id=s.id and not t.is_client_change and (t.status in('IN_REVIEW','CHANGES_REQUIRED','APPROVED') or exists(select 1 from public.pmt_submissions sub where sub.task_id=t.id)))))
$$;

create function public.pmt_record_client_approval_with_poc(p_stage_id uuid,p_client_poc_id uuid,p_channel text,p_notes text) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_poc public.pmt_client_pocs%rowtype;v_did uuid;v_revision int;
begin if not public.pmt_is_admin() then raise exception 'Only an Admin may record Client Decisions.';end if;
 select s.deliverable_id,d.client_revision into v_did,v_revision from public.pmt_stages s join public.pmt_deliverables d on d.id=s.deliverable_id where s.id=p_stage_id;
 select p.* into v_poc from public.pmt_client_pocs p join public.pmt_campaign_pocs cp on cp.client_poc_id=p.id join public.pmt_deliverables d on d.campaign_id=cp.campaign_id where p.id=p_client_poc_id and d.id=v_did and p.status='ACTIVE';if not found then raise exception 'Select an active POC associated with this Campaign.';end if;
 perform public.pmt_record_client_approval(p_stage_id,p_channel,v_poc.name,p_notes);update public.pmt_client_decisions set client_poc_id=p_client_poc_id where id=(select id from public.pmt_client_decisions where stage_id=p_stage_id and client_revision=v_revision order by recorded_at desc limit 1);
end;$$;

create function public.pmt_record_targeted_client_changes(p_decision_stage_id uuid,p_target_stage_id uuid,p_client_poc_id uuid,p_channel text,p_feedback text,p_notes text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_source public.pmt_stages%rowtype;v_target public.pmt_stages%rowtype;v_d public.pmt_deliverables%rowtype;v_poc public.pmt_client_pocs%rowtype;v_rev int;v_dec uuid:=gen_random_uuid();v_feedback uuid:=gen_random_uuid();v_rework uuid:=gen_random_uuid();
begin if not public.pmt_is_admin() then raise exception 'Only an Admin may record Client Changes.';end if;
 select * into v_source from public.pmt_stages where id=p_decision_stage_id for update;if not found or v_source.status<>'CLIENT_DECISION' then raise exception 'Stage is not ready for a Client Decision.';end if;select * into v_d from public.pmt_deliverables where id=v_source.deliverable_id for update;select * into v_target from public.pmt_stages where id=p_target_stage_id and deliverable_id=v_d.id for update;if not found then raise exception 'Target Stage does not belong to this Deliverable.';end if;if not public.pmt_is_rework_target_eligible(v_d.id,p_target_stage_id) then raise exception 'Target Stage has not submitted or completed production work.';end if;
 select p.* into v_poc from public.pmt_client_pocs p join public.pmt_campaign_pocs cp on cp.client_poc_id=p.id where p.id=p_client_poc_id and cp.campaign_id=v_d.campaign_id and p.status='ACTIVE';if not found then raise exception 'Select an active POC associated with this Campaign.';end if;if p_channel not in('Email','Phone','WhatsApp','Meeting') then raise exception 'Invalid channel.';end if;if p_feedback is null or length(btrim(p_feedback))=0 then raise exception 'Client Changes are required.';end if;
 v_rev:=v_d.client_revision+1;insert into public.pmt_client_decisions(id,deliverable_id,stage_id,decision,client_revision,channel,contact_person,feedback,notes,recorded_by,recorded_at,client_poc_id)values(v_dec,v_d.id,p_decision_stage_id,'CHANGES_REQUESTED',v_rev,p_channel,v_poc.name,btrim(p_feedback),nullif(btrim(p_notes),''),public.pmt_current_pmt_id(),now(),p_client_poc_id);
 insert into public.pmt_deliverable_feedback(id,deliverable_id,stage_id,client_revision,feedback_text,author_id,resolved)values(v_feedback,v_d.id,p_target_stage_id,v_rev,btrim(p_feedback),public.pmt_current_pmt_id(),false);
 insert into public.pmt_reworks(id,deliverable_id,source_stage_id,target_stage_id,client_revision,feedback,department,assigned_by,assigned_at,status,metadata)values(v_rework,v_d.id,p_decision_stage_id,p_target_stage_id,v_rev,btrim(p_feedback),v_target.dept,public.pmt_current_pmt_id(),now(),'OPEN',jsonb_build_object('client_decision_id',v_dec,'client_poc_id',p_client_poc_id,'deliverable_feedback_id',v_feedback,'channel',p_channel));
 update public.pmt_deliverables set client_revision=v_rev,status='CHANGES_REQUESTED' where id=v_d.id;update public.pmt_stages set rework_pending=false where deliverable_id=v_d.id;update public.pmt_stages set status=case when id=p_target_stage_id then'ACTIVE'when id=p_decision_stage_id then'PENDING'else status end,rework_pending=(id=p_target_stage_id) where deliverable_id=v_d.id;
 perform public.pmt_log_activity('CLIENT_DECISION',v_dec,'CLIENT_DECISION_CHANGES_REQUESTED',jsonb_build_object('deliverable_id',v_d.id,'source_stage_id',p_decision_stage_id,'target_stage_id',p_target_stage_id,'client_revision',v_rev,'client_poc_id',p_client_poc_id));perform public.pmt_log_activity('REWORK',v_rework,'REWORK_CREATED',jsonb_build_object('deliverable_id',v_d.id,'target_stage_id',p_target_stage_id,'department',v_target.dept,'client_revision',v_rev));perform public.pmt_notify_department_managers(v_target.dept,'CLIENT_CHANGES','Client requested changes for Revision '||v_rev::text||'.','REWORK',v_rework,'/stages/'||p_target_stage_id::text,public.pmt_current_pmt_id());return v_rework;end;$$;

create function public.pmt_create_campaign_document(p_campaign_id uuid,p_document_type text,p_title text,p_content text,p_files jsonb) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid:=gen_random_uuid();v_file jsonb;v_fid uuid;
begin if not public.pmt_is_admin() then raise exception 'Only an Admin may manage Campaign documents.';end if;if p_document_type not in('IDEATION','BRIEF')then raise exception 'Invalid document type.';end if;if p_title is null or length(btrim(p_title))=0 then raise exception 'Document title is required.';end if;insert into public.pmt_campaign_documents(id,campaign_id,document_type,title,content,created_by,updated_by)values(v_id,p_campaign_id,p_document_type,btrim(p_title),coalesce(p_content,''),public.pmt_current_pmt_id(),public.pmt_current_pmt_id());perform public.pmt_log_activity('CAMPAIGN',p_campaign_id,'CAMPAIGN_DOCUMENT_CREATED',jsonb_build_object('document_id',v_id,'document_type',p_document_type));for v_file in select value from jsonb_array_elements(coalesce(p_files,'[]'::jsonb))loop if length(btrim(v_file->>'file_name'))=0 or length(btrim(v_file->>'file_url'))=0 then raise exception 'Every file requires a name and link.';end if;v_fid:=gen_random_uuid();insert into public.pmt_campaign_document_files(id,document_id,file_name,file_url,created_by)values(v_fid,v_id,btrim(v_file->>'file_name'),btrim(v_file->>'file_url'),public.pmt_current_pmt_id());perform public.pmt_log_activity('CAMPAIGN',p_campaign_id,'CAMPAIGN_DOCUMENT_FILE_ADDED',jsonb_build_object('document_id',v_id,'file_id',v_fid,'file_name',btrim(v_file->>'file_name')));end loop;return v_id;end;$$;
create function public.pmt_update_campaign_document(p_document_id uuid,p_title text,p_content text,p_files jsonb) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_doc public.pmt_campaign_documents%rowtype;v_old record;v_file jsonb;v_fid uuid;
begin if not public.pmt_is_admin() then raise exception 'Only an Admin may manage Campaign documents.';end if;select * into v_doc from public.pmt_campaign_documents where id=p_document_id for update;if not found then raise exception 'Document not found.';end if;if p_title is null or length(btrim(p_title))=0 then raise exception 'Document title is required.';end if;for v_old in select * from public.pmt_campaign_document_files where document_id=p_document_id loop perform public.pmt_log_activity('CAMPAIGN',v_doc.campaign_id,'CAMPAIGN_DOCUMENT_FILE_REMOVED',jsonb_build_object('document_id',p_document_id,'file_id',v_old.id,'file_name',v_old.file_name));end loop;delete from public.pmt_campaign_document_files where document_id=p_document_id;update public.pmt_campaign_documents set title=btrim(p_title),content=coalesce(p_content,''),updated_by=public.pmt_current_pmt_id() where id=p_document_id;for v_file in select value from jsonb_array_elements(coalesce(p_files,'[]'::jsonb))loop if length(btrim(v_file->>'file_name'))=0 or length(btrim(v_file->>'file_url'))=0 then raise exception 'Every file requires a name and link.';end if;v_fid:=gen_random_uuid();insert into public.pmt_campaign_document_files(id,document_id,file_name,file_url,created_by)values(v_fid,p_document_id,btrim(v_file->>'file_name'),btrim(v_file->>'file_url'),public.pmt_current_pmt_id());perform public.pmt_log_activity('CAMPAIGN',v_doc.campaign_id,'CAMPAIGN_DOCUMENT_FILE_ADDED',jsonb_build_object('document_id',p_document_id,'file_id',v_fid,'file_name',btrim(v_file->>'file_name')));end loop;perform public.pmt_log_activity('CAMPAIGN',v_doc.campaign_id,'CAMPAIGN_DOCUMENT_UPDATED',jsonb_build_object('document_id',p_document_id,'document_type',v_doc.document_type));end;$$;
create function public.pmt_delete_campaign_document(p_document_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_campaign_documents%rowtype;f record;begin if not public.pmt_is_admin() then raise exception 'Only an Admin may manage Campaign documents.';end if;select * into v from public.pmt_campaign_documents where id=p_document_id for update;if not found then raise exception 'Document not found.';end if;for f in select * from public.pmt_campaign_document_files where document_id=p_document_id loop perform public.pmt_log_activity('CAMPAIGN',v.campaign_id,'CAMPAIGN_DOCUMENT_FILE_REMOVED',jsonb_build_object('document_id',p_document_id,'file_id',f.id,'file_name',f.file_name));end loop;delete from public.pmt_campaign_documents where id=p_document_id;perform public.pmt_log_activity('CAMPAIGN',v.campaign_id,'CAMPAIGN_DOCUMENT_DELETED',jsonb_build_object('document_id',p_document_id,'document_type',v.document_type));end;$$;
create function public.pmt_add_campaign_document_file(p_document_id uuid,p_file_name text,p_file_url text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid:=gen_random_uuid();v_campaign uuid;begin if not public.pmt_is_admin()then raise exception 'Only an Admin may manage Campaign document files.';end if;select campaign_id into v_campaign from public.pmt_campaign_documents where id=p_document_id;if not found then raise exception 'Document not found.';end if;if length(btrim(p_file_name))=0 or length(btrim(p_file_url))=0 then raise exception 'File name and link are required.';end if;insert into public.pmt_campaign_document_files(id,document_id,file_name,file_url,created_by)values(v_id,p_document_id,btrim(p_file_name),btrim(p_file_url),public.pmt_current_pmt_id());perform public.pmt_log_activity('CAMPAIGN',v_campaign,'CAMPAIGN_DOCUMENT_FILE_ADDED',jsonb_build_object('document_id',p_document_id,'file_id',v_id,'file_name',btrim(p_file_name)));return v_id;end;$$;
create function public.pmt_remove_campaign_document_file(p_file_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v record;begin if not public.pmt_is_admin()then raise exception 'Only an Admin may manage Campaign document files.';end if;select f.*,d.campaign_id into v from public.pmt_campaign_document_files f join public.pmt_campaign_documents d on d.id=f.document_id where f.id=p_file_id;if not found then raise exception 'Document file not found.';end if;delete from public.pmt_campaign_document_files where id=p_file_id;perform public.pmt_log_activity('CAMPAIGN',v.campaign_id,'CAMPAIGN_DOCUMENT_FILE_REMOVED',jsonb_build_object('document_id',v.document_id,'file_id',p_file_id,'file_name',v.file_name));end;$$;

create or replace function public.pmt_record_client_approval_with_poc(p_stage_id uuid,p_client_poc_id uuid,p_channel text,p_notes text) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_poc public.pmt_client_pocs%rowtype;v_did uuid;v_revision int;v_rework public.pmt_reworks%rowtype;v_target_order int;v_source_order int;v_admin record;
begin if not public.pmt_is_admin() then raise exception 'Only an Admin may record Client Decisions.';end if;
 select s.deliverable_id,d.client_revision into v_did,v_revision from public.pmt_stages s join public.pmt_deliverables d on d.id=s.deliverable_id where s.id=p_stage_id;
 select p.* into v_poc from public.pmt_client_pocs p join public.pmt_campaign_pocs cp on cp.client_poc_id=p.id join public.pmt_deliverables d on d.campaign_id=cp.campaign_id where p.id=p_client_poc_id and d.id=v_did and p.status='ACTIVE';if not found then raise exception 'Select an active POC associated with this Campaign.';end if;
 select * into v_rework from public.pmt_reworks where deliverable_id=v_did and target_stage_id=p_stage_id and client_revision=v_revision and status='COMPLETED' order by completed_at desc limit 1;
 perform public.pmt_record_client_approval(p_stage_id,p_channel,v_poc.name,p_notes);update public.pmt_client_decisions set client_poc_id=p_client_poc_id where id=(select id from public.pmt_client_decisions where stage_id=p_stage_id and client_revision=v_revision order by recorded_at desc limit 1);
 if v_rework.id is not null and v_rework.source_stage_id<>v_rework.target_stage_id then
  select stage_order into v_target_order from public.pmt_stages where id=v_rework.target_stage_id;select stage_order into v_source_order from public.pmt_stages where id=v_rework.source_stage_id;
  update public.pmt_stages set status='COMPLETED',rework_pending=false where deliverable_id=v_did and stage_order>v_target_order and stage_order<v_source_order;
  update public.pmt_stages set status='CLIENT_DECISION',rework_pending=false where id=v_rework.source_stage_id;update public.pmt_deliverables set status='CLIENT_REVIEW' where id=v_did;
  perform public.pmt_log_activity('STAGE',v_rework.source_stage_id,'STAGE_READY_FOR_CLIENT_DECISION',jsonb_build_object('deliverable_id',v_did,'client_revision',v_revision,'resumed_after_targeted_rework',v_rework.id));
  for v_admin in select id from public.pmt_users where role='ADMIN' and status='ACTIVE' and id<>public.pmt_current_pmt_id() loop perform public.pmt_create_notification(v_admin.id,'CLIENT_DECISION_READY','Targeted rework was approved; the original Stage is ready for a Client Decision.','STAGE',v_rework.source_stage_id,'/stages/'||v_rework.source_stage_id::text);end loop;
 end if;
end;$$;
alter table public.pmt_client_pocs enable row level security;alter table public.pmt_campaign_pocs enable row level security;alter table public.pmt_campaign_documents enable row level security;alter table public.pmt_campaign_document_files enable row level security;
create policy pmt_client_pocs_select on public.pmt_client_pocs for select to authenticated using(public.pmt_is_admin() or(public.pmt_is_active() and status='ACTIVE' and(((public.pmt_current_user()).role='MANAGER' and exists(select 1 from public.pmt_campaign_pocs cp where cp.client_poc_id=pmt_client_pocs.id))or((public.pmt_current_user()).role='MEMBER' and exists(select 1 from public.pmt_campaign_pocs cp join public.pmt_deliverables d on d.campaign_id=cp.campaign_id join public.pmt_stages s on s.deliverable_id=d.id join public.pmt_tasks t on t.stage_id=s.id where cp.client_poc_id=pmt_client_pocs.id and t.assignee_id=public.pmt_current_pmt_id())))));
create policy pmt_campaign_pocs_select on public.pmt_campaign_pocs for select to authenticated using(public.pmt_is_admin() or(public.pmt_is_active() and((public.pmt_current_user()).role='MANAGER' or exists(select 1 from public.pmt_deliverables d join public.pmt_stages s on s.deliverable_id=d.id join public.pmt_tasks t on t.stage_id=s.id where d.campaign_id=pmt_campaign_pocs.campaign_id and t.assignee_id=public.pmt_current_pmt_id()))));
create policy pmt_campaign_documents_select on public.pmt_campaign_documents for select to authenticated using(public.pmt_is_admin() or(public.pmt_is_active() and((public.pmt_current_user()).role='MANAGER' or exists(select 1 from public.pmt_deliverables d join public.pmt_stages s on s.deliverable_id=d.id join public.pmt_tasks t on t.stage_id=s.id where d.campaign_id=pmt_campaign_documents.campaign_id and t.assignee_id=public.pmt_current_pmt_id()))));
create policy pmt_campaign_document_files_select on public.pmt_campaign_document_files for select to authenticated using(exists(select 1 from public.pmt_campaign_documents d where d.id=pmt_campaign_document_files.document_id));
revoke all on table public.pmt_client_pocs,public.pmt_campaign_pocs,public.pmt_campaign_documents,public.pmt_campaign_document_files from anon,authenticated;grant select on table public.pmt_client_pocs,public.pmt_campaign_pocs,public.pmt_campaign_documents,public.pmt_campaign_document_files to authenticated;
revoke execute on function public.pmt_record_client_approval(uuid,text,text,text) from authenticated;revoke execute on function public.pmt_record_client_changes(uuid,text,text,text,text) from authenticated;
do $$declare r record;begin for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('pmt_create_client_poc','pmt_update_client_poc','pmt_deactivate_client_poc','pmt_add_campaign_poc','pmt_remove_campaign_poc','pmt_create_campaign_bundle','pmt_is_rework_target_eligible','pmt_record_client_approval_with_poc','pmt_record_targeted_client_changes','pmt_create_campaign_document','pmt_update_campaign_document','pmt_delete_campaign_document','pmt_add_campaign_document_file','pmt_remove_campaign_document_file')loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);end loop;end;$$;
grant execute on function public.pmt_create_client_poc(uuid,text,text,text,text,text,boolean,text) to authenticated;grant execute on function public.pmt_update_client_poc(uuid,text,text,text,text,text,boolean,text,text) to authenticated;grant execute on function public.pmt_deactivate_client_poc(uuid) to authenticated;grant execute on function public.pmt_add_campaign_poc(uuid,uuid,boolean) to authenticated;grant execute on function public.pmt_remove_campaign_poc(uuid,uuid) to authenticated;grant execute on function public.pmt_create_campaign_bundle(uuid,text,text,date,uuid[],uuid,jsonb) to authenticated;grant execute on function public.pmt_record_client_approval_with_poc(uuid,uuid,text,text) to authenticated;grant execute on function public.pmt_record_targeted_client_changes(uuid,uuid,uuid,text,text,text) to authenticated;grant execute on function public.pmt_create_campaign_document(uuid,text,text,text,jsonb) to authenticated;grant execute on function public.pmt_update_campaign_document(uuid,text,text,jsonb) to authenticated;grant execute on function public.pmt_delete_campaign_document(uuid) to authenticated;grant execute on function public.pmt_add_campaign_document_file(uuid,text,text) to authenticated;grant execute on function public.pmt_remove_campaign_document_file(uuid) to authenticated;
commit;
