-- Auth-to-PMT profile bootstrap hardening.
-- Registration previously depended on an authenticated application RPC after
-- signUp(). With email confirmation, signUp() returns no session, so Auth could
-- commit a user without ever creating pmt_users.

begin;

create function public.pmt_bootstrap_auth_profile(p_auth_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_user auth.users%rowtype;
  v_email text;
  v_name text;
  v_profile_id uuid;
begin
  select * into v_auth_user from auth.users where id = p_auth_user_id;
  if not found then raise exception 'Auth user not found.'; end if;

  -- Existing mapped users (including legacy Admins without registration
  -- metadata) are already valid and need no bootstrap data repair.
  select id into v_profile_id
  from public.pmt_users
  where auth_user_id = p_auth_user_id
  limit 1 for update;
  if v_profile_id is not null then return v_profile_id; end if;

  v_email := nullif(lower(btrim(v_auth_user.email)), '');
  v_name := coalesce(
    nullif(btrim(v_auth_user.raw_user_meta_data->>'pmt_registration_name'), ''),
    nullif(btrim(v_auth_user.raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(v_auth_user.raw_user_meta_data->>'name'), ''),
    v_email
  );
  if v_email is null then
    raise exception 'An email is required to create a PMT profile.';
  end if;

  -- Serialize the Auth trigger, callback, login repair, and backfill.
  perform pg_advisory_xact_lock(hashtextextended(v_email, 0));

  -- Re-check after taking the lock in case a concurrent repair won.
  select id into v_profile_id
  from public.pmt_users
  where auth_user_id = p_auth_user_id
  limit 1 for update;
  if v_profile_id is not null then return v_profile_id; end if;

  -- Never let email matching steal a profile linked to another Auth user.
  if exists (
    select 1 from public.pmt_users
    where lower(email) = v_email
      and auth_user_id is not null
      and auth_user_id <> p_auth_user_id
  ) then
    raise exception 'This email is already linked to another PMT profile.';
  end if;

  -- Email matching may only claim a deliberately unassigned PENDING stub.
  -- Never inherit or downgrade access from a configured/previously approved
  -- profile; that identity requires controlled Admin reconciliation.
  if exists (
    select 1 from public.pmt_users
    where lower(email) = v_email
      and auth_user_id is null
      and (
        status is distinct from 'PENDING'
        or role is not null
        or dept is not null
        or approved_at is not null
        or approved_by is not null
      )
  ) then
    raise exception 'This email matches a configured PMT profile and requires Admin reconciliation.';
  end if;

  select id into v_profile_id
  from public.pmt_users
  where auth_user_id is null
    and lower(email) = v_email
    and status = 'PENDING'
    and role is null
    and dept is null
    and approved_at is null
    and approved_by is null
  limit 1 for update;

  if v_profile_id is not null then
    update public.pmt_users
    set auth_user_id = p_auth_user_id, name = v_name, email = v_email
    where id = v_profile_id;
  else
    v_profile_id := p_auth_user_id;
    insert into public.pmt_users (
      id, auth_user_id, name, email, role, dept, status
    ) values (
      v_profile_id, p_auth_user_id, v_name, v_email, null, null, 'PENDING'
    );
  end if;
  return v_profile_id;
end;
$$;

create function public.pmt_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.pmt_bootstrap_auth_profile(new.id);
  return new;
end;
$$;

drop trigger if exists pmt_auth_user_profile_bootstrap on auth.users;
create trigger pmt_auth_user_profile_bootstrap
after insert on auth.users
for each row execute function public.pmt_handle_new_auth_user();

create function public.pmt_ensure_current_user_profile()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Authentication is required.'; end if;
  return public.pmt_bootstrap_auth_profile(auth.uid());
end;
$$;

-- Retire the caller-supplied identity/email RPC. The new public entry point
-- derives all identity data from auth.users and accepts no arguments.
revoke all on function public.pmt_provision_user_profile(uuid, text, text) from public, anon, authenticated;
revoke all on function public.pmt_bootstrap_auth_profile(uuid) from public, anon, authenticated;
revoke all on function public.pmt_handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.pmt_ensure_current_user_profile() from public, anon, authenticated;
grant execute on function public.pmt_ensure_current_user_profile() to authenticated;

-- Reconcile pre-007 email Auth orphans automatically. Registrations normally
-- carry a display name; legacy rows without one use their email as a neutral
-- label. No role or department is inferred.
do $$
declare
  v_auth_user record;
begin
  for v_auth_user in
    select u.id
    from auth.users u
    where not exists (
      select 1 from public.pmt_users p where p.auth_user_id = u.id
    )
      and nullif(lower(btrim(u.email)), '') is not null
      and not exists (
        select 1 from public.pmt_users p
        where lower(p.email) = lower(btrim(u.email))
          and p.auth_user_id is not null
          and p.auth_user_id <> u.id
      )
      and not exists (
        select 1 from public.pmt_users p
        where lower(p.email) = lower(btrim(u.email))
          and p.auth_user_id is null
          and (
            p.status is distinct from 'PENDING'
            or p.role is not null
            or p.dept is not null
            or p.approved_at is not null
            or p.approved_by is not null
          )
      )
    order by u.created_at, u.id
  loop
    perform public.pmt_bootstrap_auth_profile(v_auth_user.id);
  end loop;
end;
$$;

commit;
