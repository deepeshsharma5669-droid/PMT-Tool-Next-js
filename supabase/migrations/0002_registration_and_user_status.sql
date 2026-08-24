-- Phase: open registration + pending-approval model.
--
-- Adds what self-registration needs: an email to identify/dedupe
-- registrants, and a status lifecycle (PENDING -> ACTIVE / INACTIVE) that
-- gates app access independently of role. Does not touch RLS (explicitly
-- deferred until the updated auth/user model is reviewed) and does not
-- touch any other table.

begin;

alter table pmt_users
  add column if not exists email text,
  add column if not exists status text not null default 'PENDING';

-- A freshly self-registered user has no role yet (Admin assigns it later),
-- so role can no longer be mandatory. The existing pmt_users_role_check
-- constraint (role in ('ADMIN','MANAGER','MEMBER')) already tolerates NULL
-- unchanged — CHECK only rejects FALSE, not NULL/unknown.
alter table pmt_users
  alter column role drop not null;

alter table pmt_users
  add constraint pmt_users_status_check
    check (status in ('PENDING','ACTIVE','INACTIVE'));

create unique index if not exists pmt_users_email_key
  on pmt_users (email) where email is not null;

create index if not exists pmt_users_status_idx on pmt_users (status);

commit;
