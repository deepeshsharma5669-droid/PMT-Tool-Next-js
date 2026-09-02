-- Canonical PMT client lifecycle RPCs and client visibility refinement.
-- Requires: 20260825000200_canonical_workflow_rpc_and_rls.sql

begin;

create function public.pmt_create_client(p_name text,p_contact text,p_email text,p_phone text,p_whatsapp text,p_status text default 'ACTIVE')
returns public.pmt_clients language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client public.pmt_clients%rowtype;
begin
  if not public.pmt_is_admin() then raise exception 'Only an Admin may create clients.'; end if;
  if p_name is null or length(btrim(p_name)) = 0 then raise exception 'Client name is required.'; end if;
  if p_status not in ('ACTIVE','INACTIVE') then raise exception 'Invalid client status.'; end if;
  insert into public.pmt_clients(name,contact,email,phone,whatsapp,status)
  values(btrim(p_name),nullif(btrim(p_contact),''),nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_whatsapp),''),p_status)
  returning * into v_client;
  perform public.pmt_log_activity('CLIENT',v_client.id,'CLIENT_CREATED',jsonb_build_object('name',v_client.name,'status',v_client.status));
  return v_client;
end; $$;

create function public.pmt_update_client(p_client_id uuid,p_name text,p_contact text,p_email text,p_phone text,p_whatsapp text,p_status text)
returns public.pmt_clients language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old public.pmt_clients%rowtype; v_client public.pmt_clients%rowtype;
begin
  if not public.pmt_is_admin() then raise exception 'Only an Admin may update clients.'; end if;
  if p_name is null or length(btrim(p_name)) = 0 then raise exception 'Client name is required.'; end if;
  if p_status not in ('ACTIVE','INACTIVE') then raise exception 'Invalid client status.'; end if;
  select * into v_old from public.pmt_clients where id=p_client_id for update;
  if not found then raise exception 'Client not found.'; end if;
  update public.pmt_clients set name=btrim(p_name),contact=nullif(btrim(p_contact),''),email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),whatsapp=nullif(btrim(p_whatsapp),''),status=p_status
  where id=p_client_id returning * into v_client;
  perform public.pmt_log_activity('CLIENT',p_client_id,'CLIENT_UPDATED',jsonb_build_object('old_name',v_old.name,'new_name',v_client.name,'old_status',v_old.status,'new_status',v_client.status));
  return v_client;
end; $$;

create function public.pmt_deactivate_client(p_client_id uuid)
returns public.pmt_clients language plpgsql security definer set search_path = public, pg_temp as $$
declare v_client public.pmt_clients%rowtype;
begin
  if not public.pmt_is_admin() then raise exception 'Only an Admin may deactivate clients.'; end if;
  update public.pmt_clients set status='INACTIVE' where id=p_client_id returning * into v_client;
  if not found then raise exception 'Client not found.'; end if;
  perform public.pmt_log_activity('CLIENT',p_client_id,'CLIENT_DEACTIVATED',jsonb_build_object('name',v_client.name));
  return v_client;
end; $$;

drop policy pmt_clients_select on public.pmt_clients;
create policy pmt_clients_select on public.pmt_clients for select to authenticated using (
  public.pmt_is_admin()
  or (public.pmt_is_active() and status='ACTIVE' and (public.pmt_current_user()).role='MANAGER')
  or (public.pmt_is_active() and exists (
    select 1 from public.pmt_campaigns c join public.pmt_deliverables d on d.campaign_id=c.id join public.pmt_stages s on s.deliverable_id=d.id join public.pmt_tasks t on t.stage_id=s.id
    where c.client_id=pmt_clients.id and t.assignee_id=public.pmt_current_pmt_id()
  ))
);

revoke all on function public.pmt_create_client(text,text,text,text,text,text) from public,anon;
revoke all on function public.pmt_update_client(uuid,text,text,text,text,text,text) from public,anon;
revoke all on function public.pmt_deactivate_client(uuid) from public,anon;
grant execute on function public.pmt_create_client(text,text,text,text,text,text) to authenticated;
grant execute on function public.pmt_update_client(uuid,text,text,text,text,text,text) to authenticated;
grant execute on function public.pmt_deactivate_client(uuid) to authenticated;

commit;