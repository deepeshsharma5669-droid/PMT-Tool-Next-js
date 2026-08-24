-- Phase 2 — Auth foundation + durable workflow schema
--
-- Additive only. Does NOT touch pmt_reminders (documented as an existing,
-- not-yet-wired-up legacy table — left untouched per instruction).
-- Does NOT alter any existing row values. Does NOT enable/change RLS
-- policies (Phase 5) — RLS on the 6 original tables stays as-is (enabled,
-- fully permissive) until the auth mapping is populated and policies can
-- be validated against real sessions.
--
-- Every status/role vocabulary below was read directly out of
-- public/pmt-legacy.html (grep for the literal string assignments), not
-- invented. See chat history for the exact line references.

begin;

-- =========================================================================
-- 1. AUTH MAPPING — pmt_users.auth_user_id -> auth.users.id
-- =========================================================================
-- Nullable: existing 6 pmt_users rows have no auth account yet (auth.users
-- has 0 rows on this project today). This column only links an internal
-- user's durable identity (pmt_users.id, unchanged) to whatever Supabase
-- Auth account they're later given. No accounts are created by this
-- migration — see "AUTH MAPPING STRATEGY" in the chat response.
alter table pmt_users
  add column if not exists auth_user_id uuid references auth.users(id) on delete set null;

-- One auth account maps to at most one pmt_users row.
create unique index if not exists pmt_users_auth_user_id_key
  on pmt_users (auth_user_id) where auth_user_id is not null;

create index if not exists pmt_users_dept_idx on pmt_users (dept);

-- =========================================================================
-- 2. EXISTING TABLES — missing durable workflow fields
-- =========================================================================

-- pmt_deliverables: type / status / client_revision were being computed
-- client-side with hardcoded fallbacks (loadAllData: `type: x.type || 'Static
-- Poster'`, `clientRevision: 0`) because the columns didn't exist. Adding
-- them with the same defaults means the existing row keeps behaving
-- identically once read for real instead of being defaulted in JS.
alter table pmt_deliverables
  add column if not exists type text default 'Static Poster',
  add column if not exists status text default 'IN_PROGRESS',
  add column if not exists client_revision integer not null default 0;

alter table pmt_deliverables
  add constraint pmt_deliverables_type_check
    check (type in ('Static Poster','Instagram Carousel','Instagram Reel','Presentation')),
  add constraint pmt_deliverables_status_check
    check (status in ('IN_PROGRESS','CLIENT_REVIEW','CHANGES_REQUESTED','COMPLETED')),
  add constraint pmt_deliverables_client_revision_check
    check (client_revision >= 0);

-- pmt_stages: reworkPending was JS-local (always initialized false on load).
alter table pmt_stages
  add column if not exists rework_pending boolean not null default false;

alter table pmt_stages
  add constraint pmt_stages_status_check
    check (status in ('PENDING','ACTIVE','CLIENT_DECISION','COMPLETED'));

-- pmt_tasks: clientRevision/isClientChange were JS-local; the four
-- timestamps were tracked in JS (createdAt/startedAt/submittedAt/approvedAt)
-- but never sent back to Supabase.
alter table pmt_tasks
  add column if not exists client_revision integer,
  add column if not exists is_client_change boolean not null default false,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists started_at timestamptz,
  add column if not exists submitted_at timestamptz,
  add column if not exists approved_at timestamptz;

alter table pmt_tasks
  add constraint pmt_tasks_status_check
    check (status in ('TODO','IN_PROGRESS','IN_REVIEW','CHANGES_REQUIRED','APPROVED')),
  add constraint pmt_tasks_client_revision_check
    check (client_revision is null or client_revision >= 0),
  -- Bidirectional pairing per the finalized workflow rule: a Normal Task is
  -- always (is_client_change=false, client_revision=null); a Client Change
  -- Task is always (is_client_change=true, client_revision=<revision it
  -- belongs to>). Neither state may exist without the other — the gate math
  -- in recalculateStageGate depends on this pairing holding exactly.
  add constraint pmt_tasks_client_change_revision_check
    check (
      (is_client_change = true and client_revision is not null)
      or (is_client_change = false and client_revision is null)
    );

-- Existing status vocabularies on pmt_campaigns / pmt_clients (confirmed via
-- the Edit Campaign / Edit Client modals' <select> options in the legacy
-- file), not previously constrained at the DB level.
alter table pmt_campaigns
  add constraint pmt_campaigns_status_check
    check (status in ('ACTIVE','ARCHIVED','COMPLETED'));

alter table pmt_clients
  add constraint pmt_clients_status_check
    check (status in ('ACTIVE','INACTIVE'));

-- =========================================================================
-- 3. NEW TABLES — durable persistence for what's currently JS-local only
-- =========================================================================

-- One row per Member "submit for review" event.
create table if not exists pmt_submissions (
  id text primary key,
  task_id text not null references pmt_tasks(id) on delete cascade,
  submitted_by text references pmt_users(id),
  note text,
  manager_feedback text,
  decision_type text check (decision_type in ('APPROVED','CHANGES_REQUESTED','REJECTED_ALL')),
  submitted_at timestamptz not null default now()
);

-- One row per variant/option within a submission.
create table if not exists pmt_submission_options (
  id text primary key,
  submission_id text not null references pmt_submissions(id) on delete cascade,
  name text not null,
  link text not null,
  note text,
  decision text not null default 'PENDING' check (decision in ('PENDING','SELECTED','REJECTED'))
);

-- Gate-2 decision log (Client Approval / Client Changes), recorded by
-- Admin/Manager on the client's behalf — the client never logs in.
create table if not exists pmt_client_decisions (
  id text primary key,
  deliverable_id text not null references pmt_deliverables(id) on delete cascade,
  decision text not null check (decision in ('APPROVED','CHANGES_REQUESTED')),
  client_revision integer not null check (client_revision >= 0),
  channel text check (channel in ('Email','Phone','WhatsApp','Meeting')),
  contact_person text,
  feedback text,
  notes text,
  recorded_by text references pmt_users(id),
  recorded_at timestamptz not null default now()
);

-- Client feedback text per revision (feedbackHistory in legacy JS),
-- normalized instead of a JSON blob per instruction.
create table if not exists pmt_deliverable_feedback (
  id text primary key,
  deliverable_id text not null references pmt_deliverables(id) on delete cascade,
  stage_id text references pmt_stages(id) on delete set null,
  client_revision integer not null check (client_revision >= 0),
  feedback_text text not null,
  author_id text references pmt_users(id),
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- Global audit log. entity_id is intentionally unconstrained (polymorphic
-- across client/campaign/deliverable/stage/task — no single FK target).
create table if not exists pmt_activity (
  id text primary key,
  entity_type text not null check (entity_type in ('CLIENT','CAMPAIGN','DELIVERABLE','STAGE','TASK')),
  entity_id text not null,
  action text not null,
  actor_id text references pmt_users(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Per-user notification inbox. `type` is intentionally NOT check-constrained
-- — it's an evolving set of event names (SUBMISSION_RECEIVED, TASK_APPROVED,
-- CLIENT_CHANGES, ...), not one of the finalized workflow's finite statuses.
create table if not exists pmt_notifications (
  id text primary key,
  user_id text not null references pmt_users(id) on delete cascade,
  type text not null,
  message text not null,
  action_code text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

-- =========================================================================
-- 4. INDEXES — foreign keys + the columns Server Actions will filter on
-- =========================================================================

create index if not exists pmt_campaigns_client_id_idx on pmt_campaigns (client_id);
create index if not exists pmt_campaigns_status_idx on pmt_campaigns (status);

create index if not exists pmt_deliverables_campaign_id_idx on pmt_deliverables (campaign_id);
create index if not exists pmt_deliverables_status_idx on pmt_deliverables (status);
create index if not exists pmt_deliverables_client_revision_idx on pmt_deliverables (client_revision);

create index if not exists pmt_stages_deliverable_id_idx on pmt_stages (deliverable_id);
create index if not exists pmt_stages_status_idx on pmt_stages (status);
create index if not exists pmt_stages_dept_idx on pmt_stages (dept);

create index if not exists pmt_tasks_stage_id_idx on pmt_tasks (stage_id);
create index if not exists pmt_tasks_assignee_id_idx on pmt_tasks (assignee_id);
create index if not exists pmt_tasks_status_idx on pmt_tasks (status);
create index if not exists pmt_tasks_client_revision_idx on pmt_tasks (client_revision) where client_revision is not null;

create index if not exists pmt_clients_status_idx on pmt_clients (status);

create index if not exists pmt_submissions_task_id_idx on pmt_submissions (task_id);
create index if not exists pmt_submissions_submitted_by_idx on pmt_submissions (submitted_by);

create index if not exists pmt_submission_options_submission_id_idx on pmt_submission_options (submission_id);

create index if not exists pmt_client_decisions_deliverable_id_idx on pmt_client_decisions (deliverable_id);
create index if not exists pmt_client_decisions_revision_idx on pmt_client_decisions (deliverable_id, client_revision);

create index if not exists pmt_deliverable_feedback_deliverable_idx on pmt_deliverable_feedback (deliverable_id, client_revision);

create index if not exists pmt_activity_entity_idx on pmt_activity (entity_type, entity_id);
create index if not exists pmt_activity_actor_id_idx on pmt_activity (actor_id);
create index if not exists pmt_activity_created_at_idx on pmt_activity (created_at desc);

create index if not exists pmt_notifications_user_id_idx on pmt_notifications (user_id, read);

commit;
