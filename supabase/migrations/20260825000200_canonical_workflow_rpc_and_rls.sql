-- Canonical PMT workflow, audit, notification, grant, and RLS layer.
-- Requires: 20260825000100_canonical_pmt_baseline.sql
-- UUID-native. No seed data or Auth-user creation.

begin;

-- ---------------------------------------------------------------------------
-- Entity vocabulary extension required for durable reminder events.
-- ---------------------------------------------------------------------------

alter table public.pmt_activity
  drop constraint pmt_activity_entity_type_check,
  add constraint pmt_activity_entity_type_check
    check (entity_type in (
      'CLIENT', 'CAMPAIGN', 'DELIVERABLE', 'STAGE', 'TASK',
      'SUBMISSION', 'CLIENT_DECISION', 'REWORK', 'REMINDER', 'USER'
    ));

alter table public.pmt_notifications
  drop constraint pmt_notifications_entity_type_check,
  add constraint pmt_notifications_entity_type_check
    check (
      entity_type is null or entity_type in (
        'CLIENT', 'CAMPAIGN', 'DELIVERABLE', 'STAGE', 'TASK',
        'SUBMISSION', 'CLIENT_DECISION', 'REWORK', 'REMINDER', 'USER'
      )
    );

-- ---------------------------------------------------------------------------
-- Auth/authorization helpers. All identity is derived from auth.uid().
-- ---------------------------------------------------------------------------

create function public.pmt_current_user()
returns public.pmt_users
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select u
  from public.pmt_users u
  where u.auth_user_id = auth.uid()
  limit 1
$$;

create function public.pmt_current_pmt_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (public.pmt_current_user()).id
$$;

create function public.pmt_is_active()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((public.pmt_current_user()).status = 'ACTIVE', false)
$$;

create function public.pmt_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.pmt_is_active()
     and (public.pmt_current_user()).role = 'ADMIN'
$$;

create function public.pmt_is_manager_of(p_dept text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.pmt_is_active()
     and (public.pmt_current_user()).role = 'MANAGER'
     and (public.pmt_current_user()).dept = p_dept
$$;

create function public.pmt_is_task_manager(p_stage_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.pmt_stages s
    where s.id = p_stage_id
      and public.pmt_is_manager_of(s.dept)
  )
$$;

create function public.pmt_can_manage_stage(p_stage_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.pmt_is_admin()
      or exists (
        select 1
        from public.pmt_stages s
        where s.id = p_stage_id
          and public.pmt_is_manager_of(s.dept)
      )
$$;

create function public.pmt_can_review_task(p_task_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_task public.pmt_tasks%rowtype;
  v_stage public.pmt_stages%rowtype;
  v_actor uuid := public.pmt_current_pmt_id();
begin
  select * into v_task from public.pmt_tasks where id = p_task_id;
  if not found or v_task.status <> 'IN_REVIEW' then
    return false;
  end if;

  select * into v_stage from public.pmt_stages where id = v_task.stage_id;
  if not public.pmt_is_manager_of(v_stage.dept) then
    return false;
  end if;

  if v_task.assignee_id <> v_actor then
    return true;
  end if;

  return not exists (
    select 1
    from public.pmt_users u
    where u.role = 'MANAGER'
      and u.status = 'ACTIVE'
      and u.dept = v_stage.dept
      and u.id <> v_actor
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Internal durable event helpers. Not granted directly to API roles.
-- ---------------------------------------------------------------------------

create function public.pmt_log_activity(
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_metadata jsonb default '{}'::jsonb,
  p_actor_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := gen_random_uuid();
  v_actor uuid := coalesce(p_actor_id, public.pmt_current_pmt_id());
begin
  insert into public.pmt_activity (
    id, entity_type, entity_id, action, actor_id, metadata
  )
  values (
    v_id, p_entity_type, p_entity_id, p_action, v_actor,
    coalesce(p_metadata, '{}'::jsonb)
  );
  return v_id;
end;
$$;

create function public.pmt_create_notification(
  p_user_id uuid,
  p_type text,
  p_message text,
  p_entity_type text default null,
  p_entity_id uuid default null,
  p_action_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if p_user_id is null then
    return null;
  end if;

  insert into public.pmt_notifications (
    id, user_id, type, message, entity_type, entity_id, action_code
  )
  values (
    v_id, p_user_id, p_type, p_message,
    p_entity_type, p_entity_id, p_action_code
  );
  return v_id;
end;
$$;

create function public.pmt_notify_department_managers(
  p_dept text,
  p_type text,
  p_message text,
  p_entity_type text,
  p_entity_id uuid,
  p_action_code text default null,
  p_exclude_user_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user record;
begin
  for v_user in
    select id
    from public.pmt_users
    where role = 'MANAGER'
      and dept = p_dept
      and status = 'ACTIVE'
      and (p_exclude_user_id is null or id <> p_exclude_user_id)
  loop
    perform public.pmt_create_notification(
      v_user.id, p_type, p_message,
      p_entity_type, p_entity_id, p_action_code
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- User protection/audit triggers preserve history even for current direct
-- user-admin Server Actions. Non-Admins cannot alter protected identity state.
-- ---------------------------------------------------------------------------

create function public.pmt_protect_user_fields()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or public.pmt_is_admin() then
    return new;
  end if;

  if old.id is distinct from new.id
     or old.created_at is distinct from new.created_at then
    raise exception 'Profile identity and creation timestamp are immutable.';
  end if;

  if new.email is distinct from old.email
     and lower(new.email) is distinct from lower(auth.jwt()->>'email') then
    raise exception 'Profile email must match the current Auth user.';
  end if;

  if old.role is distinct from new.role
     or old.dept is distinct from new.dept
     or old.status is distinct from new.status
     or old.approved_at is distinct from new.approved_at
     or old.approved_by is distinct from new.approved_by then
    raise exception 'Only an Admin may change role, department, status, or approval fields.';
  end if;

  if new.auth_user_id is distinct from auth.uid() then
    raise exception 'A user profile may only be linked to the current Auth user.';
  end if;

  return new;
end;
$$;

create trigger pmt_users_protect_fields
before update on public.pmt_users
for each row execute function public.pmt_protect_user_fields();

create function public.pmt_audit_user_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.pmt_current_pmt_id();
begin
  if tg_op = 'INSERT' then
    perform public.pmt_log_activity(
      'USER', new.id, 'USER_CREATED',
      jsonb_build_object('status', new.status, 'role', new.role, 'dept', new.dept),
      coalesce(v_actor, new.id)
    );
    return new;
  end if;

  if old.auth_user_id is distinct from new.auth_user_id then
    perform public.pmt_log_activity(
      'USER', new.id, 'USER_PROVISIONED',
      jsonb_build_object('auth_user_id', new.auth_user_id), v_actor
    );
  elsif old.name is distinct from new.name
        or old.email is distinct from new.email
        or old.avatar is distinct from new.avatar
        or old.phone is distinct from new.phone then
    perform public.pmt_log_activity(
      'USER', new.id, 'USER_PROFILE_UPDATED',
      jsonb_build_object(
        'old_name', old.name, 'new_name', new.name,
        'old_email', old.email, 'new_email', new.email
      ),
      v_actor
    );
  end if;

  if old.role is distinct from new.role or old.dept is distinct from new.dept then
    perform public.pmt_log_activity(
      'USER', new.id, 'USER_ACCESS_CHANGED',
      jsonb_build_object(
        'old_role', old.role, 'new_role', new.role,
        'old_dept', old.dept, 'new_dept', new.dept
      ),
      v_actor
    );
  end if;

  if old.status is distinct from new.status then
    if new.status = 'ACTIVE' then
      perform public.pmt_log_activity(
        'USER', new.id, 'USER_ACTIVATED',
        jsonb_build_object('old_status', old.status), v_actor
      );
      perform public.pmt_create_notification(
        new.id, 'USER_ACTIVATED', 'Your PMT account is active.',
        'USER', new.id, '/dashboard'
      );
    elsif new.status = 'INACTIVE' then
      perform public.pmt_log_activity(
        'USER', new.id, 'USER_DEACTIVATED',
        jsonb_build_object('old_status', old.status), v_actor
      );
    end if;
  end if;

  return new;
end;
$$;

create trigger pmt_users_audit_change
after insert or update on public.pmt_users
for each row execute function public.pmt_audit_user_change();

-- ---------------------------------------------------------------------------
-- User provisioning RPCs.
-- ---------------------------------------------------------------------------

create function public.pmt_provision_user_profile(
  p_auth_user_id uuid,
  p_name text,
  p_email text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required.';
  end if;
  if auth.uid() <> p_auth_user_id and not public.pmt_is_admin() then
    raise exception 'You may only provision your own profile.';
  end if;
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception 'Name is required.';
  end if;
  if p_email is null or length(btrim(p_email)) = 0 then
    raise exception 'Email is required.';
  end if;

  select id into v_id
  from public.pmt_users
  where auth_user_id = p_auth_user_id
     or (auth_user_id is null and lower(email) = lower(p_email))
  order by (auth_user_id is not null) desc
  limit 1
  for update;

  if v_id is null then
    v_id := p_auth_user_id;
    insert into public.pmt_users (
      id, auth_user_id, name, email, status
    )
    values (
      v_id, p_auth_user_id, btrim(p_name), lower(btrim(p_email)), 'PENDING'
    );
  else
    update public.pmt_users
    set auth_user_id = p_auth_user_id,
        name = btrim(p_name),
        email = lower(btrim(p_email))
    where id = v_id;
  end if;

  return v_id;
end;
$$;

create function public.pmt_assign_user_role_and_dept(
  p_user_id uuid,
  p_role text,
  p_dept text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may assign role and department.';
  end if;
  if p_role not in ('ADMIN', 'MANAGER', 'MEMBER') then
    raise exception 'Invalid role.';
  end if;
  if p_dept is null or length(btrim(p_dept)) = 0 then
    raise exception 'Department is required.';
  end if;

  update public.pmt_users
  set role = p_role, dept = btrim(p_dept)
  where id = p_user_id;
  if not found then raise exception 'User not found.'; end if;
end;
$$;

create function public.pmt_activate_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user public.pmt_users%rowtype;
  v_actor uuid := public.pmt_current_pmt_id();
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may activate users.';
  end if;

  select * into v_user from public.pmt_users where id = p_user_id for update;
  if not found then raise exception 'User not found.'; end if;
  if v_user.role is null or v_user.dept is null then
    raise exception 'Assign a role and department before activation.';
  end if;

  update public.pmt_users
  set status = 'ACTIVE',
      approved_at = coalesce(approved_at, now()),
      approved_by = coalesce(approved_by, v_actor)
  where id = p_user_id;
end;
$$;

create function public.pmt_deactivate_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.pmt_current_pmt_id();
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may deactivate users.';
  end if;
  if p_user_id = v_actor then
    raise exception 'You cannot deactivate your own account.';
  end if;

  update public.pmt_users set status = 'INACTIVE' where id = p_user_id;
  if not found then raise exception 'User not found.'; end if;
end;
$$;

create function public.pmt_approve_pending_user(
  p_user_id uuid,
  p_role text,
  p_dept text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may approve users.';
  end if;
  if p_role not in ('ADMIN', 'MANAGER', 'MEMBER') then
    raise exception 'Invalid role.';
  end if;
  if p_dept is null or length(btrim(p_dept)) = 0 then
    raise exception 'Department is required.';
  end if;

  update public.pmt_users
  set role = p_role,
      dept = btrim(p_dept),
      status = 'ACTIVE',
      approved_at = now(),
      approved_by = public.pmt_current_pmt_id()
  where id = p_user_id and status = 'PENDING';
  if not found then raise exception 'Pending user not found.'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Workflow template helper.
-- ---------------------------------------------------------------------------

create function public.pmt_stage_template(p_type text)
returns jsonb
language sql
immutable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
    when 'Static Poster' then
      '[{"name":"Content Strategy","dept":"Content"},{"name":"Visual Design","dept":"Design"}]'::jsonb
    when 'Instagram Carousel' then
      '[{"name":"Copywriting","dept":"Content"},{"name":"Layout Design","dept":"Design"}]'::jsonb
    when 'Instagram Reel' then
      '[{"name":"Scripting","dept":"Content"},{"name":"Storyboarding","dept":"Design"},{"name":"Animation","dept":"Animation"}]'::jsonb
    when 'Presentation' then
      '[{"name":"Content Drafting","dept":"Content"},{"name":"Slide Design","dept":"Design"}]'::jsonb
    else null
  end
$$;

create function public.pmt_validate_task_assignee(
  p_stage_id uuid,
  p_assignee_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_dept text;
begin
  select dept into v_dept from public.pmt_stages where id = p_stage_id;
  if v_dept is null then raise exception 'Stage not found.'; end if;

  if not exists (
    select 1 from public.pmt_users
    where id = p_assignee_id
      and status = 'ACTIVE'
      and role in ('MEMBER', 'MANAGER')
      and dept = v_dept
  ) then
    raise exception 'Assignee must be an active Member or Manager in the stage department.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Campaign and deliverable RPCs.
-- ---------------------------------------------------------------------------

create function public.pmt_create_campaign(
  p_client_id uuid,
  p_name text,
  p_deadline date,
  p_deliverables jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.pmt_current_pmt_id();
  v_campaign_id uuid := gen_random_uuid();
  v_deliverable jsonb;
  v_deliverable_id uuid;
  v_stage jsonb;
  v_stage_id uuid;
  v_order integer;
  v_type text;
  v_name text;
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may create a campaign.';
  end if;
  if not exists (select 1 from public.pmt_clients where id = p_client_id and status = 'ACTIVE') then
    raise exception 'Active client not found.';
  end if;
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception 'Campaign name is required.';
  end if;
  if p_deliverables is null or jsonb_typeof(p_deliverables) <> 'array' or jsonb_array_length(p_deliverables) = 0 then
    raise exception 'A campaign needs at least one deliverable.';
  end if;

  insert into public.pmt_campaigns (
    id, client_id, name, priority, deadline, status, created_by
  )
  values (
    v_campaign_id, p_client_id, btrim(p_name), 'Medium',
    p_deadline, 'ACTIVE', v_actor
  );

  perform public.pmt_log_activity(
    'CAMPAIGN', v_campaign_id, 'CAMPAIGN_CREATED',
    jsonb_build_object('name', btrim(p_name), 'client_id', p_client_id)
  );

  for v_deliverable in select value from jsonb_array_elements(p_deliverables)
  loop
    v_type := v_deliverable->>'type';
    v_name := coalesce(nullif(btrim(v_deliverable->>'name'), ''), v_type);
    if public.pmt_stage_template(v_type) is null then
      raise exception 'Invalid deliverable type: %.', v_type;
    end if;

    v_deliverable_id := gen_random_uuid();
    insert into public.pmt_deliverables (
      id, campaign_id, name, type, status, client_revision
    )
    values (
      v_deliverable_id, v_campaign_id, v_name, v_type, 'IN_PROGRESS', 0
    );

    perform public.pmt_log_activity(
      'DELIVERABLE', v_deliverable_id, 'DELIVERABLE_CREATED',
      jsonb_build_object('campaign_id', v_campaign_id, 'type', v_type)
    );

    v_order := 0;
    for v_stage in select value from jsonb_array_elements(public.pmt_stage_template(v_type))
    loop
      v_order := v_order + 1;
      v_stage_id := gen_random_uuid();
      insert into public.pmt_stages (
        id, deliverable_id, name, dept, stage_order, status, rework_pending
      )
      values (
        v_stage_id, v_deliverable_id, v_stage->>'name', v_stage->>'dept',
        v_order, case when v_order = 1 then 'ACTIVE' else 'PENDING' end, false
      );
      if v_order = 1 then
        perform public.pmt_log_activity(
          'STAGE', v_stage_id, 'STAGE_ACTIVATED',
          jsonb_build_object('deliverable_id', v_deliverable_id, 'dept', v_stage->>'dept')
        );
      end if;
    end loop;
  end loop;

  return v_campaign_id;
end;
$$;

create function public.pmt_update_campaign(
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
    select count(*) > 0 and bool_and(status = 'COMPLETED')
    into v_all_completed
    from public.pmt_deliverables
    where campaign_id = p_campaign_id;
    if not coalesce(v_all_completed, false) then
      raise exception 'Campaign cannot complete until all deliverables are completed.';
    end if;
  end if;

  update public.pmt_campaigns
  set name = btrim(p_name), priority = p_priority,
      deadline = p_deadline, status = p_status
  where id = p_campaign_id;

  perform public.pmt_log_activity(
    'CAMPAIGN', p_campaign_id, 'CAMPAIGN_UPDATED',
    jsonb_build_object(
      'old_name', v_old.name, 'new_name', btrim(p_name),
      'old_priority', v_old.priority, 'new_priority', p_priority,
      'old_deadline', v_old.deadline, 'new_deadline', p_deadline,
      'old_status', v_old.status, 'new_status', p_status
    )
  );
end;
$$;

create function public.pmt_archive_campaign(p_campaign_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may archive a campaign.';
  end if;
  update public.pmt_campaigns set status = 'ARCHIVED' where id = p_campaign_id;
  if not found then raise exception 'Campaign not found.'; end if;
  perform public.pmt_log_activity(
    'CAMPAIGN', p_campaign_id, 'CAMPAIGN_ARCHIVED'
  );
end;
$$;

create function public.pmt_add_deliverable(
  p_campaign_id uuid,
  p_name text,
  p_type text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_campaign public.pmt_campaigns%rowtype;
  v_deliverable_id uuid := gen_random_uuid();
  v_stage jsonb;
  v_stage_id uuid;
  v_order integer := 0;
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may add a deliverable.';
  end if;
  if public.pmt_stage_template(p_type) is null then
    raise exception 'Invalid deliverable type.';
  end if;
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception 'Deliverable name is required.';
  end if;

  select * into v_campaign from public.pmt_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Campaign not found.'; end if;
  if v_campaign.status in ('ARCHIVED', 'COMPLETED') then
    raise exception 'Cannot add a deliverable to an archived or completed campaign.';
  end if;

  insert into public.pmt_deliverables (
    id, campaign_id, name, type, status, client_revision
  )
  values (
    v_deliverable_id, p_campaign_id, btrim(p_name), p_type, 'IN_PROGRESS', 0
  );

  for v_stage in select value from jsonb_array_elements(public.pmt_stage_template(p_type))
  loop
    v_order := v_order + 1;
    v_stage_id := gen_random_uuid();
    insert into public.pmt_stages (
      id, deliverable_id, name, dept, stage_order, status, rework_pending
    )
    values (
      v_stage_id, v_deliverable_id, v_stage->>'name', v_stage->>'dept',
      v_order, case when v_order = 1 then 'ACTIVE' else 'PENDING' end, false
    );
    if v_order = 1 then
      perform public.pmt_log_activity(
        'STAGE', v_stage_id, 'STAGE_ACTIVATED',
        jsonb_build_object('deliverable_id', v_deliverable_id, 'dept', v_stage->>'dept')
      );
    end if;
  end loop;

  perform public.pmt_log_activity(
    'DELIVERABLE', v_deliverable_id, 'DELIVERABLE_CREATED',
    jsonb_build_object('campaign_id', p_campaign_id, 'type', p_type)
  );

  return v_deliverable_id;
end;
$$;

create function public.pmt_change_deliverable_type(
  p_deliverable_id uuid,
  p_new_type text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deliverable public.pmt_deliverables%rowtype;
  v_has_history boolean;
  v_stage jsonb;
  v_stage_id uuid;
  v_order integer := 0;
begin
  if not public.pmt_is_admin() then
    raise exception 'Only an Admin may change deliverable type.';
  end if;
  if public.pmt_stage_template(p_new_type) is null then
    raise exception 'Invalid deliverable type.';
  end if;

  select * into v_deliverable
  from public.pmt_deliverables
  where id = p_deliverable_id
  for update;
  if not found then raise exception 'Deliverable not found.'; end if;

  select
    v_deliverable.client_revision > 0
    or exists (
      select 1 from public.pmt_deliverable_feedback
      where deliverable_id = p_deliverable_id
    )
    or exists (
      select 1 from public.pmt_client_decisions
      where deliverable_id = p_deliverable_id
    )
    or exists (
      select 1 from public.pmt_reworks
      where deliverable_id = p_deliverable_id
    )
    or exists (
      select 1
      from public.pmt_tasks t
      join public.pmt_stages s on s.id = t.stage_id
      where s.deliverable_id = p_deliverable_id
        and (
          t.status <> 'TODO'
          or exists (
            select 1 from public.pmt_submissions sub where sub.task_id = t.id
          )
        )
    )
  into v_has_history;

  if v_has_history then
    raise exception 'Deliverable type cannot change after production has started.';
  end if;
  if p_new_type = v_deliverable.type then return; end if;

  delete from public.pmt_stages where deliverable_id = p_deliverable_id;

  update public.pmt_deliverables
  set type = p_new_type, client_revision = 0, status = 'IN_PROGRESS'
  where id = p_deliverable_id;

  for v_stage in select value from jsonb_array_elements(public.pmt_stage_template(p_new_type))
  loop
    v_order := v_order + 1;
    v_stage_id := gen_random_uuid();
    insert into public.pmt_stages (
      id, deliverable_id, name, dept, stage_order, status, rework_pending
    )
    values (
      v_stage_id, p_deliverable_id, v_stage->>'name', v_stage->>'dept',
      v_order, case when v_order = 1 then 'ACTIVE' else 'PENDING' end, false
    );
    if v_order = 1 then
      perform public.pmt_log_activity(
        'STAGE', v_stage_id, 'STAGE_ACTIVATED',
        jsonb_build_object('deliverable_id', p_deliverable_id, 'dept', v_stage->>'dept')
      );
    end if;
  end loop;

  perform public.pmt_log_activity(
    'DELIVERABLE', p_deliverable_id, 'DELIVERABLE_TYPE_CHANGED',
    jsonb_build_object('old_type', v_deliverable.type, 'new_type', p_new_type)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Stage gate. Current-revision Change Tasks take precedence when present;
-- otherwise only normal production tasks count. Empty gates never open.
-- ---------------------------------------------------------------------------

create function public.pmt_apply_stage_gate(p_stage_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage public.pmt_stages%rowtype;
  v_deliverable public.pmt_deliverables%rowtype;
  v_rework_mode boolean;
  v_gate_count integer;
  v_unapproved integer;
  v_rework record;
  v_admin record;
  v_actor uuid := public.pmt_current_pmt_id();
begin
  select * into v_stage
  from public.pmt_stages
  where id = p_stage_id
  for update;
  if not found or v_stage.status = 'COMPLETED' then return; end if;

  select * into v_deliverable
  from public.pmt_deliverables
  where id = v_stage.deliverable_id
  for update;

  select exists (
    select 1 from public.pmt_tasks
    where stage_id = p_stage_id
      and is_client_change
      and client_revision = v_deliverable.client_revision
  )
  into v_rework_mode;

  if v_rework_mode then
    select count(*), count(*) filter (where status <> 'APPROVED')
    into v_gate_count, v_unapproved
    from public.pmt_tasks
    where stage_id = p_stage_id
      and is_client_change
      and client_revision = v_deliverable.client_revision;
  else
    select count(*), count(*) filter (where status <> 'APPROVED')
    into v_gate_count, v_unapproved
    from public.pmt_tasks
    where stage_id = p_stage_id
      and not is_client_change
      and client_revision is null;
  end if;

  if v_gate_count = 0 or v_unapproved > 0 then return; end if;

  if v_rework_mode then
    for v_rework in
      update public.pmt_reworks
      set status = 'COMPLETED',
          completed_by = v_actor,
          completed_at = now()
      where deliverable_id = v_deliverable.id
        and target_stage_id = p_stage_id
        and client_revision = v_deliverable.client_revision
        and status in ('OPEN', 'IN_PROGRESS')
      returning id
    loop
      perform public.pmt_log_activity(
        'REWORK', v_rework.id, 'REWORK_COMPLETED',
        jsonb_build_object(
          'stage_id', p_stage_id,
          'client_revision', v_deliverable.client_revision
        )
      );
      perform public.pmt_create_notification(
        v_actor, 'REWORK_COMPLETED',
        'Rework is complete and ready for a Client Decision.',
        'REWORK', v_rework.id, '/stages/' || p_stage_id::text
      );
    end loop;
  end if;

  update public.pmt_stages
  set status = 'CLIENT_DECISION', rework_pending = false
  where id = p_stage_id;

  update public.pmt_deliverables
  set status = 'CLIENT_REVIEW'
  where id = v_deliverable.id;

  perform public.pmt_log_activity(
    'STAGE', p_stage_id, 'STAGE_READY_FOR_CLIENT_DECISION',
    jsonb_build_object(
      'deliverable_id', v_deliverable.id,
      'client_revision', v_deliverable.client_revision,
      'gate_mode', case when v_rework_mode then 'CLIENT_REWORK' else 'NORMAL_PRODUCTION' end
    )
  );

  perform public.pmt_notify_department_managers(
    v_stage.dept, 'CLIENT_DECISION_READY',
    'A stage is ready for a Client Decision: ' || v_stage.name,
    'STAGE', p_stage_id, '/stages/' || p_stage_id::text,
    v_actor
  );
  for v_admin in
    select id from public.pmt_users
    where role = 'ADMIN' and status = 'ACTIVE' and id <> v_actor
  loop
    perform public.pmt_create_notification(
      v_admin.id, 'CLIENT_DECISION_READY',
      'A stage is ready for a Client Decision: ' || v_stage.name,
      'STAGE', p_stage_id, '/stages/' || p_stage_id::text
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Task management.
-- ---------------------------------------------------------------------------

create function public.pmt_create_task(
  p_stage_id uuid,
  p_title text,
  p_description text,
  p_assignee_id uuid,
  p_deadline date
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage public.pmt_stages%rowtype;
  v_task_id uuid := gen_random_uuid();
  v_order integer;
begin
  if not public.pmt_is_task_manager(p_stage_id) then
    raise exception 'Only the owning department Manager may create tasks.';
  end if;
  select * into v_stage from public.pmt_stages where id = p_stage_id for update;
  if not found then raise exception 'Stage not found.'; end if;
  if v_stage.status <> 'ACTIVE' or v_stage.rework_pending then
    raise exception 'Normal tasks can only be created in active non-rework production.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'Task title is required.';
  end if;
  if p_deadline is null then raise exception 'Task deadline is required.'; end if;
  perform public.pmt_validate_task_assignee(p_stage_id, p_assignee_id);

  select coalesce(max(task_order), 0) + 1 into v_order
  from public.pmt_tasks
  where stage_id = p_stage_id and status <> 'APPROVED';

  insert into public.pmt_tasks (
    id, stage_id, title, description, assignee_id, deadline,
    status, iteration, task_order, client_revision, is_client_change
  )
  values (
    v_task_id, p_stage_id, btrim(p_title), coalesce(p_description, ''),
    p_assignee_id, p_deadline, 'TODO', 1, v_order, null, false
  );

  perform public.pmt_log_activity(
    'TASK', v_task_id, 'TASK_CREATED',
    jsonb_build_object(
      'stage_id', p_stage_id, 'assignee_id', p_assignee_id,
      'deadline', p_deadline, 'task_order', v_order
    )
  );
  perform public.pmt_create_notification(
    p_assignee_id, 'TASK_ASSIGNED',
    'You were assigned a task: ' || btrim(p_title),
    'TASK', v_task_id, '/tasks/' || v_task_id::text
  );

  return v_task_id;
end;
$$;

create function public.pmt_assign_task(
  p_task_id uuid,
  p_assignee_id uuid
)
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
  if not public.pmt_is_task_manager(v_task.stage_id) then
    raise exception 'Only the owning department Manager may assign this task.';
  end if;
  if v_task.status in ('IN_REVIEW', 'APPROVED') then
    raise exception 'A task awaiting review or already approved cannot be reassigned.';
  end if;
  perform public.pmt_validate_task_assignee(v_task.stage_id, p_assignee_id);
  if v_task.assignee_id = p_assignee_id then return; end if;

  update public.pmt_tasks set assignee_id = p_assignee_id where id = p_task_id;

  perform public.pmt_log_activity(
    'TASK', p_task_id,
    case when v_task.assignee_id is null then 'TASK_ASSIGNED' else 'TASK_REASSIGNED' end,
    jsonb_build_object(
      'old_assignee_id', v_task.assignee_id,
      'new_assignee_id', p_assignee_id
    )
  );
  perform public.pmt_create_notification(
    p_assignee_id,
    case when v_task.assignee_id is null then 'TASK_ASSIGNED' else 'TASK_REASSIGNED' end,
    'You were assigned a task: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text
  );
  if v_task.assignee_id is not null then
    perform public.pmt_create_notification(
      v_task.assignee_id, 'TASK_REASSIGNED',
      'This task was reassigned: ' || v_task.title,
      'TASK', p_task_id, '/tasks/' || p_task_id::text
    );
  end if;
end;
$$;

create function public.pmt_update_task(
  p_task_id uuid,
  p_title text,
  p_description text
)
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
  if not public.pmt_is_task_manager(v_task.stage_id) then
    raise exception 'Only the owning department Manager may edit this task.';
  end if;
  if v_task.status in ('IN_REVIEW', 'APPROVED') then
    raise exception 'A task awaiting review or already approved cannot be edited.';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'Task title is required.';
  end if;

  update public.pmt_tasks
  set title = btrim(p_title), description = coalesce(p_description, '')
  where id = p_task_id;

  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_UPDATED',
    jsonb_build_object(
      'old_title', v_task.title, 'new_title', btrim(p_title)
    )
  );
end;
$$;

create function public.pmt_change_deadline(
  p_task_id uuid,
  p_deadline date
)
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
  if not public.pmt_is_task_manager(v_task.stage_id) then
    raise exception 'Only the owning department Manager may change this deadline.';
  end if;
  if v_task.status in ('IN_REVIEW', 'APPROVED') then
    raise exception 'A task awaiting review or already approved is locked.';
  end if;
  if p_deadline is null then raise exception 'Deadline is required.'; end if;
  if v_task.deadline = p_deadline then return; end if;

  update public.pmt_tasks set deadline = p_deadline where id = p_task_id;

  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_DEADLINE_CHANGED',
    jsonb_build_object('old_deadline', v_task.deadline, 'new_deadline', p_deadline)
  );
  perform public.pmt_create_notification(
    v_task.assignee_id, 'TASK_DEADLINE_CHANGED',
    'The deadline changed for: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text
  );
end;
$$;

create function public.pmt_reorder_tasks(
  p_stage_id uuid,
  p_dragged_task_id uuid,
  p_target_task_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids uuid[];
  v_drag_index integer;
  v_target_index integer;
  v_dragged uuid;
  v_i integer;
begin
  if not public.pmt_is_task_manager(p_stage_id) then
    raise exception 'Only the owning department Manager may reorder tasks.';
  end if;

  select array_agg(id order by task_order, created_at, id)
  into v_ids
  from public.pmt_tasks
  where stage_id = p_stage_id
    and status not in ('APPROVED', 'IN_REVIEW');

  v_drag_index := array_position(v_ids, p_dragged_task_id);
  v_target_index := array_position(v_ids, p_target_task_id);
  if v_drag_index is null or v_target_index is null then
    raise exception 'Only unlocked tasks in this stage may be reordered.';
  end if;
  if v_drag_index = v_target_index then return; end if;

  v_dragged := v_ids[v_drag_index];
  v_ids := v_ids[1:v_drag_index - 1] || v_ids[v_drag_index + 1:array_length(v_ids, 1)];

  -- Match Array.splice(): target index is resolved before removing the
  -- dragged row and is intentionally not decremented for downward moves.
  v_ids := v_ids[1:v_target_index - 1] || v_dragged || v_ids[v_target_index:array_length(v_ids, 1)];

  for v_i in 1..coalesce(array_length(v_ids, 1), 0)
  loop
    update public.pmt_tasks set task_order = v_i where id = v_ids[v_i];
  end loop;

  perform public.pmt_log_activity(
    'STAGE', p_stage_id, 'TASK_REORDERED',
    jsonb_build_object(
      'dragged_task_id', p_dragged_task_id,
      'target_task_id', p_target_task_id,
      'ordered_task_ids', to_jsonb(v_ids)
    )
  );
end;
$$;

create function public.pmt_start_task(p_task_id uuid)
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
     or v_task.assignee_id <> public.pmt_current_pmt_id() then
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

create function public.pmt_submit_task_for_review(
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
     or v_task.assignee_id <> public.pmt_current_pmt_id() then
    raise exception 'You may only submit work assigned to you.';
  end if;
  if v_task.status <> 'IN_PROGRESS' then
    raise exception 'Task must be in progress before submission.';
  end if;
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
  perform public.pmt_notify_department_managers(
    v_stage.dept, 'SUBMISSION_RECEIVED',
    'A submission is ready for review: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text,
    public.pmt_current_pmt_id()
  );

  return v_submission_id;
end;
$$;

create function public.pmt_approve_submission_option(
  p_task_id uuid,
  p_selected_option_ids uuid[],
  p_manager_feedback text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task public.pmt_tasks%rowtype;
  v_submission public.pmt_submissions%rowtype;
  v_requested integer;
  v_matching integer;
  v_actor uuid := public.pmt_current_pmt_id();
begin
  select * into v_task from public.pmt_tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found.'; end if;
  if not public.pmt_can_review_task(p_task_id) then
    raise exception 'You are not authorized to review this task.';
  end if;

  select * into v_submission
  from public.pmt_submissions
  where task_id = p_task_id and decision_type is null
  order by submitted_at desc
  limit 1
  for update;
  if not found then raise exception 'Pending submission not found.'; end if;

  v_requested := coalesce(array_length(p_selected_option_ids, 1), 0);
  select count(*) into v_matching
  from public.pmt_submission_options
  where submission_id = v_submission.id
    and id = any(coalesce(p_selected_option_ids, '{}'::uuid[]));
  if v_requested = 0 or v_matching <> v_requested then
    raise exception 'Select at least one valid option from the current submission.';
  end if;

  update public.pmt_submission_options
  set decision = case
    when id = any(p_selected_option_ids) then 'SELECTED'
    else 'REJECTED'
  end
  where submission_id = v_submission.id;

  update public.pmt_submissions
  set decision_type = 'APPROVED',
      manager_feedback = nullif(btrim(p_manager_feedback), ''),
      reviewed_at = now(),
      reviewed_by = v_actor
  where id = v_submission.id;

  update public.pmt_tasks
  set status = 'APPROVED',
      approved_at = now(),
      feedback = nullif(btrim(p_manager_feedback), ''),
      manager_feedback = nullif(btrim(p_manager_feedback), '')
  where id = p_task_id;

  perform public.pmt_log_activity(
    'SUBMISSION', v_submission.id, 'SUBMISSION_APPROVED',
    jsonb_build_object('task_id', p_task_id, 'selected_option_ids', to_jsonb(p_selected_option_ids))
  );
  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_APPROVED',
    jsonb_build_object('submission_id', v_submission.id)
  );
  perform public.pmt_create_notification(
    v_task.assignee_id, 'TASK_APPROVED',
    'Your submission was approved: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text
  );

  perform public.pmt_apply_stage_gate(v_task.stage_id);
end;
$$;

create function public.pmt_request_submission_changes(
  p_task_id uuid,
  p_manager_feedback text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task public.pmt_tasks%rowtype;
  v_submission public.pmt_submissions%rowtype;
  v_actor uuid := public.pmt_current_pmt_id();
begin
  select * into v_task from public.pmt_tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found.'; end if;
  if not public.pmt_can_review_task(p_task_id) then
    raise exception 'You are not authorized to review this task.';
  end if;
  if p_manager_feedback is null or length(btrim(p_manager_feedback)) = 0 then
    raise exception 'Feedback is required.';
  end if;

  select * into v_submission
  from public.pmt_submissions
  where task_id = p_task_id and decision_type is null
  order by submitted_at desc
  limit 1
  for update;
  if not found then raise exception 'Pending submission not found.'; end if;

  update public.pmt_submission_options
  set decision = 'REJECTED'
  where submission_id = v_submission.id;

  update public.pmt_submissions
  set decision_type = 'CHANGES_REQUESTED',
      manager_feedback = btrim(p_manager_feedback),
      reviewed_at = now(),
      reviewed_by = v_actor
  where id = v_submission.id;

  update public.pmt_tasks
  set status = 'CHANGES_REQUIRED',
      feedback = btrim(p_manager_feedback),
      manager_feedback = btrim(p_manager_feedback),
      iteration = iteration + 1
  where id = p_task_id;

  perform public.pmt_log_activity(
    'SUBMISSION', v_submission.id, 'SUBMISSION_CHANGES_REQUESTED',
    jsonb_build_object('task_id', p_task_id)
  );
  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_CHANGES_REQUESTED',
    jsonb_build_object('submission_id', v_submission.id)
  );
  perform public.pmt_create_notification(
    v_task.assignee_id, 'CHANGES_REQUESTED',
    'Changes were requested for: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text
  );
end;
$$;

create function public.pmt_reject_all_submission_options(
  p_task_id uuid,
  p_manager_feedback text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task public.pmt_tasks%rowtype;
  v_submission public.pmt_submissions%rowtype;
  v_actor uuid := public.pmt_current_pmt_id();
begin
  select * into v_task from public.pmt_tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found.'; end if;
  if not public.pmt_can_review_task(p_task_id) then
    raise exception 'You are not authorized to review this task.';
  end if;
  if p_manager_feedback is null or length(btrim(p_manager_feedback)) = 0 then
    raise exception 'Feedback is required.';
  end if;

  select * into v_submission
  from public.pmt_submissions
  where task_id = p_task_id and decision_type is null
  order by submitted_at desc
  limit 1
  for update;
  if not found then raise exception 'Pending submission not found.'; end if;

  update public.pmt_submission_options
  set decision = 'REJECTED'
  where submission_id = v_submission.id;

  update public.pmt_submissions
  set decision_type = 'REJECTED_ALL',
      manager_feedback = btrim(p_manager_feedback),
      reviewed_at = now(),
      reviewed_by = v_actor
  where id = v_submission.id;

  update public.pmt_tasks
  set status = 'CHANGES_REQUIRED',
      feedback = btrim(p_manager_feedback),
      manager_feedback = btrim(p_manager_feedback),
      iteration = iteration + 1
  where id = p_task_id;

  perform public.pmt_log_activity(
    'SUBMISSION', v_submission.id, 'SUBMISSION_REJECTED',
    jsonb_build_object('task_id', p_task_id)
  );
  perform public.pmt_log_activity(
    'TASK', p_task_id, 'TASK_REJECTED',
    jsonb_build_object('submission_id', v_submission.id)
  );
  perform public.pmt_create_notification(
    v_task.assignee_id, 'CHANGES_REQUESTED',
    'All submitted options were rejected for: ' || v_task.title,
    'TASK', p_task_id, '/tasks/' || p_task_id::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Client decisions and durable rework.
-- ---------------------------------------------------------------------------

create function public.pmt_record_client_approval(
  p_stage_id uuid,
  p_channel text,
  p_contact_person text,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage public.pmt_stages%rowtype;
  v_deliverable public.pmt_deliverables%rowtype;
  v_next_stage public.pmt_stages%rowtype;
  v_decision_id uuid := gen_random_uuid();
  v_all_completed boolean;
  v_admin record;
begin
  select * into v_stage
  from public.pmt_stages
  where id = p_stage_id
  for update;
  if not found then raise exception 'Stage not found.'; end if;
  if not public.pmt_can_manage_stage(p_stage_id) then
    raise exception 'Only an Admin or the owning Manager may record a client decision.';
  end if;
  if v_stage.status <> 'CLIENT_DECISION' then
    raise exception 'Stage is not ready for a client decision.';
  end if;
  if p_channel not in ('Email', 'Phone', 'WhatsApp', 'Meeting') then
    raise exception 'Invalid communication channel.';
  end if;
  if p_contact_person is null or length(btrim(p_contact_person)) = 0 then
    raise exception 'Contact person is required.';
  end if;

  select * into v_deliverable
  from public.pmt_deliverables
  where id = v_stage.deliverable_id
  for update;

  insert into public.pmt_client_decisions (
    id, deliverable_id, stage_id, decision, client_revision,
    channel, contact_person, notes, recorded_by, recorded_at
  )
  values (
    v_decision_id, v_deliverable.id, p_stage_id, 'APPROVED',
    v_deliverable.client_revision, p_channel, btrim(p_contact_person),
    nullif(btrim(p_notes), ''), public.pmt_current_pmt_id(), now()
  );

  perform public.pmt_log_activity(
    'CLIENT_DECISION', v_decision_id, 'CLIENT_DECISION_APPROVED',
    jsonb_build_object(
      'deliverable_id', v_deliverable.id,
      'stage_id', p_stage_id,
      'client_revision', v_deliverable.client_revision,
      'channel', p_channel
    )
  );

  update public.pmt_deliverable_feedback
  set resolved = true
  where deliverable_id = v_deliverable.id
    and client_revision = v_deliverable.client_revision
    and not resolved;

  update public.pmt_stages
  set status = 'COMPLETED', rework_pending = false
  where id = p_stage_id;

  perform public.pmt_log_activity(
    'STAGE', p_stage_id, 'STAGE_COMPLETED',
    jsonb_build_object(
      'deliverable_id', v_deliverable.id,
      'client_revision', v_deliverable.client_revision
    )
  );

  select * into v_next_stage
  from public.pmt_stages
  where deliverable_id = v_deliverable.id
    and stage_order > v_stage.stage_order
  order by stage_order
  limit 1
  for update;

  if found then
    update public.pmt_stages set status = 'ACTIVE' where id = v_next_stage.id;
    update public.pmt_deliverables set status = 'IN_PROGRESS' where id = v_deliverable.id;

    perform public.pmt_log_activity(
      'STAGE', v_next_stage.id, 'STAGE_ACTIVATED',
      jsonb_build_object(
        'deliverable_id', v_deliverable.id,
        'previous_stage_id', p_stage_id,
        'dept', v_next_stage.dept
      )
    );
    perform public.pmt_notify_department_managers(
      v_next_stage.dept, 'CLIENT_APPROVED',
      'Client approval activated stage: ' || v_next_stage.name,
      'STAGE', v_next_stage.id, '/stages/' || v_next_stage.id::text
    );
  else
    update public.pmt_deliverables
    set status = 'COMPLETED'
    where id = v_deliverable.id;

    perform public.pmt_log_activity(
      'DELIVERABLE', v_deliverable.id, 'DELIVERABLE_COMPLETED',
      jsonb_build_object('final_stage_id', p_stage_id)
    );

    select count(*) > 0 and bool_and(status = 'COMPLETED')
    into v_all_completed
    from public.pmt_deliverables
    where campaign_id = v_deliverable.campaign_id;

    if coalesce(v_all_completed, false) then
      update public.pmt_campaigns
      set status = 'COMPLETED'
      where id = v_deliverable.campaign_id;

      perform public.pmt_log_activity(
        'CAMPAIGN', v_deliverable.campaign_id, 'CAMPAIGN_COMPLETED',
        jsonb_build_object('final_deliverable_id', v_deliverable.id)
      );
    end if;
  end if;

  for v_admin in
    select id from public.pmt_users
    where role = 'ADMIN' and status = 'ACTIVE'
  loop
    perform public.pmt_create_notification(
      v_admin.id, 'CLIENT_APPROVED',
      'Client approved stage: ' || v_stage.name,
      'CLIENT_DECISION', v_decision_id,
      '/deliverables/' || v_deliverable.id::text
    );
  end loop;
end;
$$;

create function public.pmt_record_client_changes(
  p_stage_id uuid,
  p_channel text,
  p_contact_person text,
  p_feedback text,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage public.pmt_stages%rowtype;
  v_deliverable public.pmt_deliverables%rowtype;
  v_new_revision integer;
  v_decision_id uuid := gen_random_uuid();
  v_feedback_id uuid := gen_random_uuid();
  v_rework_id uuid := gen_random_uuid();
  v_admin record;
begin
  select * into v_stage
  from public.pmt_stages
  where id = p_stage_id
  for update;
  if not found then raise exception 'Stage not found.'; end if;
  if not public.pmt_can_manage_stage(p_stage_id) then
    raise exception 'Only an Admin or the owning Manager may record a client decision.';
  end if;
  if v_stage.status <> 'CLIENT_DECISION' then
    raise exception 'Stage is not ready for a client decision.';
  end if;
  if p_channel not in ('Email', 'Phone', 'WhatsApp', 'Meeting') then
    raise exception 'Invalid communication channel.';
  end if;
  if p_contact_person is null or length(btrim(p_contact_person)) = 0 then
    raise exception 'Contact person is required.';
  end if;
  if p_feedback is null or length(btrim(p_feedback)) = 0 then
    raise exception 'Client feedback is required.';
  end if;

  select * into v_deliverable
  from public.pmt_deliverables
  where id = v_stage.deliverable_id
  for update;

  v_new_revision := v_deliverable.client_revision + 1;

  insert into public.pmt_client_decisions (
    id, deliverable_id, stage_id, decision, client_revision,
    channel, contact_person, feedback, notes, recorded_by, recorded_at
  )
  values (
    v_decision_id, v_deliverable.id, p_stage_id, 'CHANGES_REQUESTED',
    v_new_revision, p_channel, btrim(p_contact_person), btrim(p_feedback),
    nullif(btrim(p_notes), ''), public.pmt_current_pmt_id(), now()
  );

  insert into public.pmt_deliverable_feedback (
    id, deliverable_id, stage_id, client_revision,
    feedback_text, author_id, resolved
  )
  values (
    v_feedback_id, v_deliverable.id, p_stage_id, v_new_revision,
    btrim(p_feedback), public.pmt_current_pmt_id(), false
  );

  insert into public.pmt_reworks (
    id, deliverable_id, source_stage_id, target_stage_id,
    client_revision, feedback, department, assigned_by,
    assigned_at, status, metadata
  )
  values (
    v_rework_id, v_deliverable.id, p_stage_id, p_stage_id,
    v_new_revision, btrim(p_feedback), v_stage.dept,
    public.pmt_current_pmt_id(), now(), 'OPEN',
    jsonb_build_object(
      'client_decision_id', v_decision_id,
      'deliverable_feedback_id', v_feedback_id,
      'channel', p_channel
    )
  );

  update public.pmt_deliverables
  set client_revision = v_new_revision, status = 'CHANGES_REQUESTED'
  where id = v_deliverable.id;

  update public.pmt_stages
  set status = 'ACTIVE', rework_pending = true
  where id = p_stage_id;

  perform public.pmt_log_activity(
    'CLIENT_DECISION', v_decision_id, 'CLIENT_DECISION_CHANGES_REQUESTED',
    jsonb_build_object(
      'deliverable_id', v_deliverable.id,
      'stage_id', p_stage_id,
      'client_revision', v_new_revision,
      'feedback_id', v_feedback_id
    )
  );
  perform public.pmt_log_activity(
    'REWORK', v_rework_id, 'REWORK_CREATED',
    jsonb_build_object(
      'deliverable_id', v_deliverable.id,
      'source_stage_id', p_stage_id,
      'target_stage_id', p_stage_id,
      'client_revision', v_new_revision,
      'department', v_stage.dept
    )
  );

  perform public.pmt_notify_department_managers(
    v_stage.dept, 'CLIENT_CHANGES',
    'Client requested changes for Revision ' || v_new_revision::text || '.',
    'REWORK', v_rework_id, '/stages/' || p_stage_id::text,
    public.pmt_current_pmt_id()
  );
  for v_admin in
    select id from public.pmt_users
    where role = 'ADMIN'
      and status = 'ACTIVE'
      and id <> public.pmt_current_pmt_id()
  loop
    perform public.pmt_create_notification(
      v_admin.id, 'CLIENT_CHANGES',
      'Client requested changes for Revision ' || v_new_revision::text || '.',
      'REWORK', v_rework_id, '/stages/' || p_stage_id::text
    );
  end loop;
end;
$$;

create function public.pmt_create_change_tasks(
  p_stage_id uuid,
  p_tasks jsonb
)
returns uuid[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage public.pmt_stages%rowtype;
  v_deliverable public.pmt_deliverables%rowtype;
  v_rework public.pmt_reworks%rowtype;
  v_task jsonb;
  v_task_id uuid;
  v_task_ids uuid[] := '{}'::uuid[];
  v_next_order integer;
  v_assignee_id uuid;
  v_deadline date;
begin
  if not public.pmt_is_task_manager(p_stage_id) then
    raise exception 'Only the owning department Manager may create Change Tasks.';
  end if;
  if p_tasks is null or jsonb_typeof(p_tasks) <> 'array' or jsonb_array_length(p_tasks) = 0 then
    raise exception 'At least one Change Task is required.';
  end if;

  select * into v_stage
  from public.pmt_stages
  where id = p_stage_id
  for update;
  if not found then raise exception 'Stage not found.'; end if;

  select * into v_deliverable
  from public.pmt_deliverables
  where id = v_stage.deliverable_id
  for update;

  if not v_stage.rework_pending
     or v_stage.status <> 'ACTIVE'
     or v_deliverable.status <> 'CHANGES_REQUESTED'
     or v_deliverable.client_revision <= 0 then
    raise exception 'Change Tasks require an active client-rework cycle.';
  end if;

  select * into v_rework
  from public.pmt_reworks
  where deliverable_id = v_deliverable.id
    and target_stage_id = p_stage_id
    and client_revision = v_deliverable.client_revision
    and status in ('OPEN', 'IN_PROGRESS')
  order by assigned_at desc
  limit 1
  for update;
  if not found then raise exception 'Active rework record not found.'; end if;

  select coalesce(max(task_order), 0)
  into v_next_order
  from public.pmt_tasks
  where stage_id = p_stage_id;

  if v_rework.status = 'OPEN' then
    update public.pmt_reworks
    set status = 'IN_PROGRESS'
    where id = v_rework.id;

    perform public.pmt_log_activity(
      'REWORK', v_rework.id, 'REWORK_STARTED',
      jsonb_build_object(
        'stage_id', p_stage_id,
        'client_revision', v_deliverable.client_revision
      )
    );
  end if;

  for v_task in select value from jsonb_array_elements(p_tasks)
  loop
    if v_task->>'title' is null or length(btrim(v_task->>'title')) = 0 then
      raise exception 'Every Change Task requires a title.';
    end if;
    begin
      v_assignee_id := (v_task->>'assignee_id')::uuid;
      v_deadline := (v_task->>'deadline')::date;
    exception when invalid_text_representation then
      raise exception 'Every Change Task requires a valid assignee and deadline.';
    end;
    if v_assignee_id is null or v_deadline is null then
      raise exception 'Every Change Task requires an assignee and deadline.';
    end if;
    perform public.pmt_validate_task_assignee(p_stage_id, v_assignee_id);

    v_next_order := v_next_order + 1;
    v_task_id := gen_random_uuid();

    insert into public.pmt_tasks (
      id, stage_id, title, description, assignee_id, deadline,
      status, iteration, task_order, client_revision, is_client_change
    )
    values (
      v_task_id, p_stage_id, btrim(v_task->>'title'),
      coalesce(v_task->>'description', ''), v_assignee_id, v_deadline,
      'CHANGES_REQUIRED', 1, v_next_order,
      v_deliverable.client_revision, true
    );

    v_task_ids := array_append(v_task_ids, v_task_id);

    perform public.pmt_log_activity(
      'TASK', v_task_id, 'TASK_CREATED',
      jsonb_build_object(
        'stage_id', p_stage_id,
        'assignee_id', v_assignee_id,
        'client_revision', v_deliverable.client_revision,
        'is_client_change', true,
        'rework_id', v_rework.id
      )
    );
    perform public.pmt_create_notification(
      v_assignee_id, 'CHANGE_TASK_ASSIGNED',
      'You were assigned a Client Change task: ' || btrim(v_task->>'title'),
      'TASK', v_task_id, '/tasks/' || v_task_id::text
    );
  end loop;

  return v_task_ids;
end;
$$;

create function public.pmt_cancel_rework(p_rework_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rework public.pmt_reworks%rowtype;
  v_stage public.pmt_stages%rowtype;
begin
  select * into v_rework
  from public.pmt_reworks
  where id = p_rework_id
  for update;
  if not found then raise exception 'Rework not found.'; end if;

  select * into v_stage
  from public.pmt_stages
  where id = v_rework.target_stage_id
  for update;

  if not (public.pmt_is_admin() or public.pmt_is_manager_of(v_rework.department)) then
    raise exception 'Not authorized to cancel this rework.';
  end if;
  if v_rework.status not in ('OPEN', 'IN_PROGRESS') then
    raise exception 'Only an open or in-progress rework can be cancelled.';
  end if;
  if exists (
    select 1 from public.pmt_tasks
    where stage_id = v_rework.target_stage_id
      and is_client_change
      and client_revision = v_rework.client_revision
      and status in ('IN_PROGRESS', 'IN_REVIEW', 'APPROVED')
  ) then
    raise exception 'Rework cannot be cancelled after Change Task work has started.';
  end if;

  update public.pmt_reworks
  set status = 'CANCELLED'
  where id = p_rework_id;

  update public.pmt_stages
  set status = 'CLIENT_DECISION', rework_pending = false
  where id = v_rework.target_stage_id;

  update public.pmt_deliverables
  set status = 'CLIENT_REVIEW'
  where id = v_rework.deliverable_id;

  perform public.pmt_log_activity(
    'REWORK', p_rework_id, 'REWORK_CANCELLED',
    jsonb_build_object(
      'stage_id', v_rework.target_stage_id,
      'client_revision', v_rework.client_revision
    )
  );

  perform public.pmt_notify_department_managers(
    v_rework.department, 'REWORK_CANCELLED',
    'The rework cycle was cancelled.',
    'REWORK', p_rework_id,
    '/stages/' || v_rework.target_stage_id::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Reminders.
-- ---------------------------------------------------------------------------

create function public.pmt_create_reminder(
  p_message text,
  p_sent_to_dept text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := gen_random_uuid();
  v_user record;
begin
  if not public.pmt_is_active() then
    raise exception 'Active PMT access is required.';
  end if;
  if not (
    public.pmt_is_admin()
    or public.pmt_is_manager_of(p_sent_to_dept)
  ) then
    raise exception 'Only an Admin or that department Manager may send a reminder.';
  end if;
  if p_message is null or length(btrim(p_message)) = 0 then
    raise exception 'Reminder message is required.';
  end if;

  insert into public.pmt_reminders (
    id, message, sent_to_dept, sent_by, status
  )
  values (
    v_id, btrim(p_message), btrim(p_sent_to_dept),
    public.pmt_current_pmt_id(), 'PENDING'
  );

  perform public.pmt_log_activity(
    'REMINDER', v_id, 'REMINDER_CREATED',
    jsonb_build_object('sent_to_dept', btrim(p_sent_to_dept))
  );

  for v_user in
    select id
    from public.pmt_users
    where status = 'ACTIVE'
      and (
        dept = btrim(p_sent_to_dept)
        or (btrim(p_sent_to_dept) = 'ALL' and role = 'ADMIN')
      )
      and id <> public.pmt_current_pmt_id()
  loop
    perform public.pmt_create_notification(
      v_user.id, 'REMINDER_RECEIVED', btrim(p_message),
      'REMINDER', v_id, '/notifications'
    );
  end loop;

  return v_id;
end;
$$;

create function public.pmt_respond_reminder(
  p_reminder_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reminder public.pmt_reminders%rowtype;
begin
  if p_status not in ('ACKNOWLEDGED', 'RESOLVED') then
    raise exception 'Invalid reminder response status.';
  end if;

  select * into v_reminder
  from public.pmt_reminders
  where id = p_reminder_id
  for update;
  if not found then raise exception 'Reminder not found.'; end if;

  if not (
    public.pmt_is_admin()
    or public.pmt_is_manager_of(v_reminder.sent_to_dept)
    or (
      public.pmt_is_active()
      and (public.pmt_current_user()).dept = v_reminder.sent_to_dept
    )
  ) then
    raise exception 'Not authorized to respond to this reminder.';
  end if;

  update public.pmt_reminders
  set status = p_status,
      responded_by = public.pmt_current_pmt_id(),
      responded_at = now()
  where id = p_reminder_id;

  perform public.pmt_log_activity(
    'REMINDER', p_reminder_id,
    case when p_status = 'RESOLVED' then 'REMINDER_RESOLVED' else 'REMINDER_ACKNOWLEDGED' end,
    jsonb_build_object('sent_to_dept', v_reminder.sent_to_dept)
  );

  perform public.pmt_create_notification(
    v_reminder.sent_by, 'REMINDER_RESPONSE',
    'A reminder was ' || lower(p_status) || '.',
    'REMINDER', p_reminder_id, '/notifications'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Role-aware RLS. Business-table mutations are RPC-only. The only direct
-- authenticated writes retained for current code are guarded user-profile
-- registration/admin updates and self notification read-state updates.
-- ---------------------------------------------------------------------------

create policy pmt_users_select
on public.pmt_users for select
to authenticated
using (
  public.pmt_is_admin()
  or auth_user_id = auth.uid()
  or (public.pmt_is_active() and status = 'ACTIVE')
  or (
    auth_user_id is null
    and lower(email) = lower(auth.jwt()->>'email')
  )
);

create policy pmt_users_insert_self
on public.pmt_users for insert
to authenticated
with check (
  auth.uid() is not null
  and id = auth.uid()
  and auth_user_id = auth.uid()
  and status = 'PENDING'
  and role is null
  and dept is null
  and lower(email) = lower(auth.jwt()->>'email')
);

create policy pmt_users_update
on public.pmt_users for update
to authenticated
using (
  public.pmt_is_admin()
  or auth_user_id = auth.uid()
  or (
    auth_user_id is null
    and lower(email) = lower(auth.jwt()->>'email')
  )
)
with check (
  public.pmt_is_admin()
  or auth_user_id = auth.uid()
);

create policy pmt_clients_select
on public.pmt_clients for select
to authenticated
using (public.pmt_is_active());

create policy pmt_campaigns_select
on public.pmt_campaigns for select
to authenticated
using (public.pmt_is_active());

create policy pmt_deliverables_select
on public.pmt_deliverables for select
to authenticated
using (public.pmt_is_active());

create policy pmt_stages_select
on public.pmt_stages for select
to authenticated
using (public.pmt_is_active());

create policy pmt_tasks_select
on public.pmt_tasks for select
to authenticated
using (
  public.pmt_is_admin()
  or public.pmt_is_task_manager(stage_id)
  or (
    public.pmt_is_active()
    and assignee_id = public.pmt_current_pmt_id()
  )
);

create policy pmt_submissions_select
on public.pmt_submissions for select
to authenticated
using (
  public.pmt_is_admin()
  or exists (
    select 1
    from public.pmt_tasks t
    where t.id = task_id
      and (
        public.pmt_is_task_manager(t.stage_id)
        or (
          public.pmt_is_active()
          and t.assignee_id = public.pmt_current_pmt_id()
        )
      )
  )
);

create policy pmt_submission_options_select
on public.pmt_submission_options for select
to authenticated
using (
  public.pmt_is_admin()
  or exists (
    select 1
    from public.pmt_submissions sub
    join public.pmt_tasks t on t.id = sub.task_id
    where sub.id = submission_id
      and (
        public.pmt_is_task_manager(t.stage_id)
        or (
          public.pmt_is_active()
          and t.assignee_id = public.pmt_current_pmt_id()
        )
      )
  )
);

create policy pmt_client_decisions_select
on public.pmt_client_decisions for select
to authenticated
using (public.pmt_is_active());

create policy pmt_deliverable_feedback_select
on public.pmt_deliverable_feedback for select
to authenticated
using (
  public.pmt_is_admin()
  or exists (
    select 1
    from public.pmt_stages s
    where s.deliverable_id = pmt_deliverable_feedback.deliverable_id
      and public.pmt_is_manager_of(s.dept)
  )
  or exists (
    select 1
    from public.pmt_stages s
    join public.pmt_tasks t on t.stage_id = s.id
    where s.deliverable_id = pmt_deliverable_feedback.deliverable_id
      and t.assignee_id = public.pmt_current_pmt_id()
      and public.pmt_is_active()
  )
);

create policy pmt_reworks_select
on public.pmt_reworks for select
to authenticated
using (
  public.pmt_is_admin()
  or public.pmt_is_manager_of(department)
  or exists (
    select 1
    from public.pmt_stages s
    join public.pmt_tasks t on t.stage_id = s.id
    where s.deliverable_id = pmt_reworks.deliverable_id
      and t.assignee_id = public.pmt_current_pmt_id()
      and public.pmt_is_active()
  )
);

create policy pmt_reminders_select
on public.pmt_reminders for select
to authenticated
using (
  public.pmt_is_admin()
  or public.pmt_is_manager_of(sent_to_dept)
  or (
    public.pmt_is_active()
    and (public.pmt_current_user()).dept = sent_to_dept
  )
  or sent_by = public.pmt_current_pmt_id()
  or responded_by = public.pmt_current_pmt_id()
);

create policy pmt_activity_select
on public.pmt_activity for select
to authenticated
using (public.pmt_is_active());

create policy pmt_notifications_select
on public.pmt_notifications for select
to authenticated
using (
  public.pmt_is_admin()
  or (
    public.pmt_is_active()
    and user_id = public.pmt_current_pmt_id()
  )
);

create policy pmt_notifications_update_self
on public.pmt_notifications for update
to authenticated
using (
  public.pmt_is_active()
  and user_id = public.pmt_current_pmt_id()
)
with check (
  public.pmt_is_active()
  and user_id = public.pmt_current_pmt_id()
);

-- ---------------------------------------------------------------------------
-- Table grants. No anonymous table access and no direct business-table DML.
-- ---------------------------------------------------------------------------

revoke all on table
  public.pmt_users,
  public.pmt_clients,
  public.pmt_campaigns,
  public.pmt_deliverables,
  public.pmt_stages,
  public.pmt_tasks,
  public.pmt_submissions,
  public.pmt_submission_options,
  public.pmt_client_decisions,
  public.pmt_deliverable_feedback,
  public.pmt_reworks,
  public.pmt_reminders,
  public.pmt_activity,
  public.pmt_notifications
from anon, authenticated;

grant select on table
  public.pmt_users,
  public.pmt_clients,
  public.pmt_campaigns,
  public.pmt_deliverables,
  public.pmt_stages,
  public.pmt_tasks,
  public.pmt_submissions,
  public.pmt_submission_options,
  public.pmt_client_decisions,
  public.pmt_deliverable_feedback,
  public.pmt_reworks,
  public.pmt_reminders,
  public.pmt_activity,
  public.pmt_notifications
to authenticated;

grant insert, update on table public.pmt_users to authenticated;
grant update (read) on table public.pmt_notifications to authenticated;

-- Revoke the default PUBLIC execute privilege from every PMT function,
-- including internal helpers and baseline timestamp-trigger functions.
do $$
declare
  v_function record;
begin
  for v_function in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'pmt\_%' escape '\'
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_function.signature
    );
  end loop;
end;
$$;

-- Identity helpers referenced by RLS policies.
grant execute on function public.pmt_current_user() to authenticated;
grant execute on function public.pmt_current_pmt_id() to authenticated;
grant execute on function public.pmt_is_active() to authenticated;
grant execute on function public.pmt_is_admin() to authenticated;
grant execute on function public.pmt_is_manager_of(text) to authenticated;
grant execute on function public.pmt_is_task_manager(uuid) to authenticated;
grant execute on function public.pmt_can_manage_stage(uuid) to authenticated;
grant execute on function public.pmt_can_review_task(uuid) to authenticated;

-- User provisioning and administration.
grant execute on function public.pmt_provision_user_profile(uuid, text, text) to authenticated;
grant execute on function public.pmt_assign_user_role_and_dept(uuid, text, text) to authenticated;
grant execute on function public.pmt_activate_user(uuid) to authenticated;
grant execute on function public.pmt_deactivate_user(uuid) to authenticated;
grant execute on function public.pmt_approve_pending_user(uuid, text, text) to authenticated;

-- Campaign/deliverable workflow.
grant execute on function public.pmt_create_campaign(uuid, text, date, jsonb) to authenticated;
grant execute on function public.pmt_update_campaign(uuid, text, text, date, text) to authenticated;
grant execute on function public.pmt_archive_campaign(uuid) to authenticated;
grant execute on function public.pmt_add_deliverable(uuid, text, text) to authenticated;
grant execute on function public.pmt_change_deliverable_type(uuid, text) to authenticated;

-- Task/submission workflow.
grant execute on function public.pmt_create_task(uuid, text, text, uuid, date) to authenticated;
grant execute on function public.pmt_assign_task(uuid, uuid) to authenticated;
grant execute on function public.pmt_update_task(uuid, text, text) to authenticated;
grant execute on function public.pmt_change_deadline(uuid, date) to authenticated;
grant execute on function public.pmt_reorder_tasks(uuid, uuid, uuid) to authenticated;
grant execute on function public.pmt_start_task(uuid) to authenticated;
grant execute on function public.pmt_submit_task_for_review(uuid, text, jsonb) to authenticated;
grant execute on function public.pmt_approve_submission_option(uuid, uuid[], text) to authenticated;
grant execute on function public.pmt_request_submission_changes(uuid, text) to authenticated;
grant execute on function public.pmt_reject_all_submission_options(uuid, text) to authenticated;
grant execute on function public.pmt_create_change_tasks(uuid, jsonb) to authenticated;

-- Client decision/rework/reminder workflow.
grant execute on function public.pmt_record_client_approval(uuid, text, text, text) to authenticated;
grant execute on function public.pmt_record_client_changes(uuid, text, text, text, text) to authenticated;
grant execute on function public.pmt_cancel_rework(uuid) to authenticated;
grant execute on function public.pmt_create_reminder(text, text) to authenticated;
grant execute on function public.pmt_respond_reminder(uuid, text) to authenticated;

commit;