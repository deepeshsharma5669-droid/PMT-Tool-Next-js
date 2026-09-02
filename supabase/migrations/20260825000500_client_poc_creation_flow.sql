-- Client organizations with optional, normalized POCs.
-- Requires 20260825000400_client_pocs_campaign_documents_workflow.sql.
begin;

create function public.pmt_ensure_client_primary_poc(p_client_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_next uuid;
begin
  perform 1 from public.pmt_clients where id=p_client_id for update;
  if not found then return; end if;
  if not exists(select 1 from public.pmt_client_pocs where client_id=p_client_id and status='ACTIVE' and is_primary) then
    select id into v_next from public.pmt_client_pocs
    where client_id=p_client_id and status='ACTIVE' order by created_at,id limit 1 for update;
    if v_next is not null then
      update public.pmt_client_pocs set is_primary=true where id=v_next;
      perform public.pmt_log_activity('CLIENT',v_next,'CLIENT_POC_PRIMARY_CHANGED',jsonb_build_object('client_id',p_client_id));
    end if;
  end if;
end; $$;

create function public.pmt_assert_client_primary_poc(p_client_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_active integer; v_primary integer;
begin
  perform 1 from public.pmt_clients where id=p_client_id for update;
  if not found then return; end if;
  select count(*) filter(where status='ACTIVE'),count(*) filter(where is_primary)
    into v_active,v_primary from public.pmt_client_pocs where client_id=p_client_id;
  if (v_active>0 and v_primary<>1) or (v_active=0 and v_primary<>0) then
    raise exception 'A Client with active POCs requires exactly one active Primary POC.';
  end if;
end; $$;

create function public.pmt_check_client_primary_poc()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op<>'INSERT' then perform public.pmt_assert_client_primary_poc(old.client_id); end if;
  if tg_op<>'DELETE' then perform public.pmt_assert_client_primary_poc(new.client_id); end if;
  return null;
end; $$;

-- Existing unique index and inactive-primary CHECK remain authoritative.
create constraint trigger pmt_client_pocs_exactly_one_active_primary
after insert or update or delete on public.pmt_client_pocs
deferrable initially deferred for each row execute function public.pmt_check_client_primary_poc();

-- 004 allowed active Clients' POC sets without a primary. Reconcile only those sets,
-- deterministically and with activity; no Clients, POCs, or test data are created.
do $$
declare v_client_id uuid;
begin
  for v_client_id in select distinct client_id from public.pmt_client_pocs where status='ACTIVE' order by client_id loop
    perform public.pmt_ensure_client_primary_poc(v_client_id);
  end loop;
end; $$;

create or replace function public.pmt_create_client_poc(p_client_id uuid,p_name text,p_designation text,p_email text,p_phone text,p_whatsapp text,p_is_primary boolean,p_notes text)
returns public.pmt_client_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may create Client POCs.';end if;
 perform 1 from public.pmt_clients where id=p_client_id for update;if not found then raise exception 'Client not found.';end if;
 if p_name is null or length(btrim(p_name))=0 then raise exception 'POC name is required.';end if;
 if p_is_primary then update public.pmt_client_pocs set is_primary=false where client_id=p_client_id and is_primary;end if;
 insert into public.pmt_client_pocs(client_id,name,designation,email,phone,whatsapp,is_primary,notes)
 values(p_client_id,btrim(p_name),nullif(btrim(p_designation),''),nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_whatsapp),''),coalesce(p_is_primary,false),nullif(btrim(p_notes),'')) returning * into v;
 perform public.pmt_ensure_client_primary_poc(v.client_id);
 select * into v from public.pmt_client_pocs where id=v.id;
 perform public.pmt_log_activity('CLIENT',v.id,'CLIENT_POC_CREATED',jsonb_build_object('client_id',p_client_id,'name',v.name,'is_primary',v.is_primary));return v;
end;$$;

create or replace function public.pmt_update_client_poc(p_poc_id uuid,p_name text,p_designation text,p_email text,p_phone text,p_whatsapp text,p_is_primary boolean,p_status text,p_notes text)
returns public.pmt_client_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;v_previous_status text;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may update Client POCs.';end if;
 perform 1 from public.pmt_clients where id=(select client_id from public.pmt_client_pocs where id=p_poc_id) for update;
 select * into v from public.pmt_client_pocs where id=p_poc_id for update;if not found then raise exception 'Client POC not found.';end if;
 v_previous_status:=v.status;
 if p_name is null or length(btrim(p_name))=0 then raise exception 'POC name is required.';end if;if p_status is null or p_status not in('ACTIVE','INACTIVE') then raise exception 'Invalid POC status.';end if;
 if p_status='INACTIVE' then perform public.pmt_prepare_client_poc_inactivation(p_poc_id);
 elsif p_is_primary then update public.pmt_client_pocs set is_primary=false where client_id=v.client_id and id<>p_poc_id and is_primary;end if;
 update public.pmt_client_pocs set name=btrim(p_name),designation=nullif(btrim(p_designation),''),email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),whatsapp=nullif(btrim(p_whatsapp),''),is_primary=(p_status='ACTIVE' and (coalesce(p_is_primary,false) or v.is_primary)),status=p_status,notes=nullif(btrim(p_notes),'') where id=p_poc_id returning * into v;
 perform public.pmt_ensure_client_primary_poc(v.client_id);
 select * into v from public.pmt_client_pocs where id=v.id;
 if v_previous_status='ACTIVE' and v.status='INACTIVE' then
  perform public.pmt_log_activity('CLIENT',p_poc_id,'CLIENT_POC_DEACTIVATED',jsonb_build_object('client_id',v.client_id,'name',v.name));
 end if;
 perform public.pmt_log_activity('CLIENT',p_poc_id,'CLIENT_POC_UPDATED',jsonb_build_object('client_id',v.client_id,'name',v.name,'status',v.status));return v;
end;$$;

create or replace function public.pmt_deactivate_client_poc(p_poc_id uuid) returns public.pmt_client_pocs language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.pmt_client_pocs%rowtype;
begin
 if not public.pmt_is_admin() then raise exception 'Only an Admin may deactivate Client POCs.';end if;
 perform 1 from public.pmt_clients where id=(select client_id from public.pmt_client_pocs where id=p_poc_id) for update;
 perform public.pmt_prepare_client_poc_inactivation(p_poc_id);
 update public.pmt_client_pocs set status='INACTIVE',is_primary=false where id=p_poc_id returning * into v;
 perform public.pmt_ensure_client_primary_poc(v.client_id);
 select * into v from public.pmt_client_pocs where id=v.id;
 perform public.pmt_log_activity('CLIENT',p_poc_id,'CLIENT_POC_DEACTIVATED',jsonb_build_object('client_id',v.client_id,'name',v.name));return v;
end;$$;

create function public.pmt_create_client_bundle(
  p_name text,p_contact text,p_email text,p_phone text,p_whatsapp text,p_pocs jsonb default '[]'::jsonb
)
returns public.pmt_clients language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client public.pmt_clients%rowtype; v_poc jsonb; v_primary_count integer;
begin
  if not public.pmt_is_admin() then raise exception 'Only an Admin may create Clients.'; end if;
  p_pocs:=coalesce(p_pocs,'[]'::jsonb);
  if jsonb_typeof(p_pocs)<>'array' then raise exception 'POCs must be a list.'; end if;
  v_primary_count:=0;
  for v_poc in select value from jsonb_array_elements(p_pocs) loop
    if jsonb_typeof(v_poc)<>'object' or nullif(btrim(v_poc->>'name'),'') is null then
      raise exception 'Every supplied POC requires a name.';
    end if;
    if v_poc ? 'status' and v_poc->>'status' is distinct from 'ACTIVE' then
      raise exception 'New POCs must be ACTIVE.';
    end if;
    if v_poc ? 'is_primary' and jsonb_typeof(v_poc->'is_primary')<>'boolean' then
      raise exception 'Primary must be a boolean.';
    end if;
    if coalesce((v_poc->>'is_primary')::boolean,false) then v_primary_count:=v_primary_count+1; end if;
  end loop;
  if v_primary_count>1 then raise exception 'Select only one Primary POC.'; end if;
  v_client:=public.pmt_create_client(p_name,p_contact,p_email,p_phone,p_whatsapp,'ACTIVE');
  for v_poc in select value from jsonb_array_elements(p_pocs) loop
    perform public.pmt_create_client_poc(v_client.id,v_poc->>'name',v_poc->>'designation',
      v_poc->>'email',v_poc->>'phone',v_poc->>'whatsapp',
      coalesce((v_poc->>'is_primary')::boolean,false),v_poc->>'notes');
  end loop;
  return v_client;
end; $$;

-- Keep the legacy signature, but organization edits never change Client status.
create or replace function public.pmt_update_client(
  p_client_id uuid,p_name text,p_contact text,p_email text,p_phone text,p_whatsapp text,p_status text
)
returns public.pmt_clients language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old public.pmt_clients%rowtype; v_client public.pmt_clients%rowtype;
begin
  if not public.pmt_is_admin() then raise exception 'Only an Admin may update Clients.'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'Client name is required.'; end if;
  select * into v_old from public.pmt_clients where id=p_client_id for update;
  if not found then raise exception 'Client not found.'; end if;
  update public.pmt_clients set name=btrim(p_name),contact=nullif(btrim(p_contact),''),
    email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),whatsapp=nullif(btrim(p_whatsapp),'')
  where id=p_client_id returning * into v_client;
  perform public.pmt_log_activity('CLIENT',p_client_id,'CLIENT_UPDATED',
    jsonb_build_object('old_name',v_old.name,'new_name',v_client.name));
  return v_client;
end; $$;

-- Sole public creation path: bundle. Legacy create remains an internal implementation helper.
revoke all on function public.pmt_create_client(text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.pmt_deactivate_client(uuid) from public,anon,authenticated;
revoke all on function public.pmt_ensure_client_primary_poc(uuid),public.pmt_assert_client_primary_poc(uuid),public.pmt_check_client_primary_poc() from public,anon,authenticated;
revoke all on function public.pmt_create_client_bundle(text,text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.pmt_create_client_bundle(text,text,text,text,text,jsonb) to authenticated;
-- Existing Admin-guarded update/POC grants and SELECT policies remain unchanged.
commit;
