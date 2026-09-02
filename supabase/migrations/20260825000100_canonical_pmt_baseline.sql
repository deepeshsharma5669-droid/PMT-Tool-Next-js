-- Canonical PMT database baseline for a new, empty Supabase project.
--
-- Scope: normalized tables, constraints, foreign keys, indexes, timestamps,
-- and secure-by-default RLS enablement. This baseline intentionally creates
-- no Auth users, seed data, workflow RPCs, grants, or RLS policies.
--
-- The archived prototype migrations under supabase/legacy-migrations are not
-- prerequisites for this file and must not be applied to the canonical project.

begin;

create table public.pmt_users (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  role text check (role in ('ADMIN', 'MANAGER', 'MEMBER')),
  dept text,
  avatar text,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  email text,
  status text not null default 'PENDING' check (status in ('PENDING', 'ACTIVE', 'INACTIVE')),
  phone text,
  approved_at timestamptz,
  approved_by uuid references public.pmt_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pmt_users_active_assignment_check check (status <> 'ACTIVE' or (role is not null and dept is not null))
);
create unique index pmt_users_email_key on public.pmt_users (lower(email)) where email is not null;
create index pmt_users_auth_user_id_idx on public.pmt_users (auth_user_id);
create index pmt_users_role_dept_status_idx on public.pmt_users (role, dept, status);

create table public.pmt_clients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  contact text,
  email text,
  phone text,
  whatsapp text,
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index pmt_clients_status_idx on public.pmt_clients (status);
create index pmt_clients_name_idx on public.pmt_clients (name);

create table public.pmt_campaigns (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.pmt_clients(id) on delete restrict,
  name text not null check (length(btrim(name)) > 0),
  priority text not null default 'Medium' check (priority in ('Low', 'Medium', 'High')),
  deadline date,
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'ARCHIVED', 'COMPLETED')),
  created_by uuid references public.pmt_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index pmt_campaigns_client_id_idx on public.pmt_campaigns (client_id);
create index pmt_campaigns_status_idx on public.pmt_campaigns (status);
create index pmt_campaigns_deadline_idx on public.pmt_campaigns (deadline);

create table public.pmt_deliverables (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.pmt_campaigns(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  type text not null default 'Static Poster' check (type in ('Static Poster', 'Instagram Carousel', 'Instagram Reel', 'Presentation')),
  status text not null default 'IN_PROGRESS' check (status in ('IN_PROGRESS', 'CLIENT_REVIEW', 'CHANGES_REQUESTED', 'COMPLETED')),
  client_revision integer not null default 0 check (client_revision >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (campaign_id, name)
);
create index pmt_deliverables_campaign_id_idx on public.pmt_deliverables (campaign_id);
create index pmt_deliverables_status_idx on public.pmt_deliverables (status);

create table public.pmt_stages (
  id uuid primary key default gen_random_uuid(),
  deliverable_id uuid not null references public.pmt_deliverables(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  dept text not null check (length(btrim(dept)) > 0),
  stage_order integer not null check (stage_order > 0),
  status text not null default 'PENDING' check (status in ('PENDING', 'ACTIVE', 'CLIENT_DECISION', 'COMPLETED')),
  rework_pending boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (deliverable_id, stage_order),
  unique (deliverable_id, name)
);
create index pmt_stages_deliverable_id_idx on public.pmt_stages (deliverable_id);
create index pmt_stages_dept_status_idx on public.pmt_stages (dept, status);

create table public.pmt_tasks (
  id uuid primary key default gen_random_uuid(),
  stage_id uuid not null references public.pmt_stages(id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  description text not null default '',
  assignee_id uuid references public.pmt_users(id) on delete set null,
  deadline date,
  status text not null default 'TODO' check (status in ('TODO', 'IN_PROGRESS', 'IN_REVIEW', 'CHANGES_REQUIRED', 'APPROVED')),
  iteration integer not null default 1 check (iteration > 0),
  task_order integer not null check (task_order > 0),
  feedback text,
  client_revision integer,
  is_client_change boolean not null default false,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  submitted_at timestamptz,
  approved_at timestamptz,
  last_updated_at timestamptz not null default now(),
  manager_feedback text,
  constraint pmt_tasks_client_revision_check check (client_revision is null or client_revision >= 0),
  constraint pmt_tasks_client_change_revision_check check ((is_client_change and client_revision is not null) or (not is_client_change and client_revision is null)),
  constraint pmt_tasks_timestamp_order_check check ((started_at is null or started_at >= created_at) and (submitted_at is null or submitted_at >= created_at) and (approved_at is null or approved_at >= created_at))
);
create index pmt_tasks_stage_order_idx on public.pmt_tasks (stage_id, task_order);
create index pmt_tasks_assignee_status_idx on public.pmt_tasks (assignee_id, status);
create index pmt_tasks_deadline_idx on public.pmt_tasks (deadline);
create index pmt_tasks_revision_idx on public.pmt_tasks (stage_id, client_revision) where is_client_change;

create table public.pmt_submissions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.pmt_tasks(id) on delete cascade,
  submitted_by uuid references public.pmt_users(id) on delete set null,
  note text,
  manager_feedback text,
  decision_type text check (decision_type in ('APPROVED', 'CHANGES_REQUESTED', 'REJECTED_ALL')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.pmt_users(id) on delete set null,
  constraint pmt_submissions_decision_time_check check ((decision_type is null and reviewed_at is null) or (decision_type is not null and reviewed_at is not null)),
  constraint pmt_submissions_review_time_check check (reviewed_at is null or reviewed_at >= submitted_at)
);
create index pmt_submissions_task_time_idx on public.pmt_submissions (task_id, submitted_at desc);
create index pmt_submissions_submitted_by_idx on public.pmt_submissions (submitted_by);
create index pmt_submissions_reviewed_by_idx on public.pmt_submissions (reviewed_by);

create table public.pmt_submission_options (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.pmt_submissions(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  link text not null check (length(btrim(link)) > 0),
  note text,
  decision text not null default 'PENDING' check (decision in ('PENDING', 'SELECTED', 'REJECTED'))
);
create index pmt_submission_options_submission_id_idx on public.pmt_submission_options (submission_id);
create index pmt_submission_options_decision_idx on public.pmt_submission_options (submission_id, decision);

create table public.pmt_client_decisions (
  id uuid primary key default gen_random_uuid(),
  deliverable_id uuid not null references public.pmt_deliverables(id) on delete cascade,
  stage_id uuid not null references public.pmt_stages(id) on delete restrict,
  decision text not null check (decision in ('APPROVED', 'CHANGES_REQUESTED')),
  client_revision integer not null check (client_revision >= 0),
  channel text check (channel in ('Email', 'Phone', 'WhatsApp', 'Meeting')),
  contact_person text,
  feedback text,
  notes text,
  recorded_by uuid references public.pmt_users(id) on delete set null,
  recorded_at timestamptz not null default now()
);
create index pmt_client_decisions_deliverable_revision_idx on public.pmt_client_decisions (deliverable_id, client_revision);
create index pmt_client_decisions_recorded_at_idx on public.pmt_client_decisions (recorded_at desc);

create table public.pmt_deliverable_feedback (
  id uuid primary key default gen_random_uuid(),
  deliverable_id uuid not null references public.pmt_deliverables(id) on delete cascade,
  stage_id uuid references public.pmt_stages(id) on delete set null,
  client_revision integer not null check (client_revision >= 0),
  feedback_text text not null check (length(btrim(feedback_text)) > 0),
  author_id uuid references public.pmt_users(id) on delete set null,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
create index pmt_deliverable_feedback_revision_idx on public.pmt_deliverable_feedback (deliverable_id, client_revision, created_at desc);
create index pmt_deliverable_feedback_unresolved_idx on public.pmt_deliverable_feedback (deliverable_id) where not resolved;

create table public.pmt_reworks (
  id uuid primary key default gen_random_uuid(),
  deliverable_id uuid not null references public.pmt_deliverables(id) on delete cascade,
  source_stage_id uuid not null references public.pmt_stages(id) on delete restrict,
  target_stage_id uuid not null references public.pmt_stages(id) on delete restrict,
  client_revision integer not null check (client_revision > 0),
  feedback text not null check (length(btrim(feedback)) > 0),
  department text not null check (length(btrim(department)) > 0),
  assigned_by uuid references public.pmt_users(id) on delete set null,
  assigned_at timestamptz not null default now(),
  status text not null default 'OPEN' check (status in ('OPEN', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  completed_by uuid references public.pmt_users(id) on delete set null,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pmt_reworks_completion_status_check check ((status = 'COMPLETED') = (completed_at is not null)),
  constraint pmt_reworks_completion_time_check check (completed_at is null or completed_at >= assigned_at),
  unique (deliverable_id, client_revision, target_stage_id)
);
create index pmt_reworks_deliverable_revision_idx on public.pmt_reworks (deliverable_id, client_revision);
create index pmt_reworks_department_status_idx on public.pmt_reworks (department, status);

create table public.pmt_reminders (
  id uuid primary key default gen_random_uuid(),
  message text not null check (length(btrim(message)) > 0),
  sent_to_dept text not null check (length(btrim(sent_to_dept)) > 0),
  sent_by uuid references public.pmt_users(id) on delete set null,
  status text not null default 'PENDING' check (status in ('PENDING', 'ACKNOWLEDGED', 'RESOLVED')),
  responded_by uuid references public.pmt_users(id) on delete set null,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pmt_reminders_response_pair_check check ((responded_at is null and responded_by is null) or (responded_at is not null and responded_by is not null))
);
create index pmt_reminders_department_status_idx on public.pmt_reminders (sent_to_dept, status);
create index pmt_reminders_sent_by_idx on public.pmt_reminders (sent_by);

create table public.pmt_activity (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('CLIENT', 'CAMPAIGN', 'DELIVERABLE', 'STAGE', 'TASK', 'SUBMISSION', 'CLIENT_DECISION', 'REWORK', 'USER')),
  entity_id uuid not null,
  action text not null check (length(btrim(action)) > 0),
  actor_id uuid references public.pmt_users(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now()
);
create index pmt_activity_entity_idx on public.pmt_activity (entity_type, entity_id, created_at desc);
create index pmt_activity_actor_id_idx on public.pmt_activity (actor_id);
create index pmt_activity_created_at_idx on public.pmt_activity (created_at desc);

create table public.pmt_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.pmt_users(id) on delete cascade,
  type text not null check (length(btrim(type)) > 0),
  message text not null check (length(btrim(message)) > 0),
  entity_type text check (entity_type is null or entity_type in ('CLIENT', 'CAMPAIGN', 'DELIVERABLE', 'STAGE', 'TASK', 'SUBMISSION', 'CLIENT_DECISION', 'REWORK', 'USER')),
  entity_id uuid,
  action_code text,
  read boolean not null default false,
  created_at timestamptz not null default now(),
  constraint pmt_notifications_entity_pair_check check ((entity_type is null and entity_id is null) or (entity_type is not null and entity_id is not null))
);
create index pmt_notifications_user_inbox_idx on public.pmt_notifications (user_id, read, created_at desc);
create index pmt_notifications_entity_idx on public.pmt_notifications (entity_type, entity_id) where entity_type is not null;

create function public.pmt_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger pmt_users_set_updated_at before update on public.pmt_users for each row execute function public.pmt_set_updated_at();
create trigger pmt_clients_set_updated_at before update on public.pmt_clients for each row execute function public.pmt_set_updated_at();
create trigger pmt_campaigns_set_updated_at before update on public.pmt_campaigns for each row execute function public.pmt_set_updated_at();
create trigger pmt_deliverables_set_updated_at before update on public.pmt_deliverables for each row execute function public.pmt_set_updated_at();
create trigger pmt_stages_set_updated_at before update on public.pmt_stages for each row execute function public.pmt_set_updated_at();
create trigger pmt_reworks_set_updated_at before update on public.pmt_reworks for each row execute function public.pmt_set_updated_at();
create trigger pmt_reminders_set_updated_at before update on public.pmt_reminders for each row execute function public.pmt_set_updated_at();

create function public.pmt_set_task_last_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.last_updated_at = now();
  return new;
end;
$$;

create trigger pmt_tasks_set_last_updated_at before update on public.pmt_tasks for each row execute function public.pmt_set_task_last_updated_at();

alter table public.pmt_users enable row level security;
alter table public.pmt_clients enable row level security;
alter table public.pmt_campaigns enable row level security;
alter table public.pmt_deliverables enable row level security;
alter table public.pmt_stages enable row level security;
alter table public.pmt_tasks enable row level security;
alter table public.pmt_submissions enable row level security;
alter table public.pmt_submission_options enable row level security;
alter table public.pmt_client_decisions enable row level security;
alter table public.pmt_deliverable_feedback enable row level security;
alter table public.pmt_reworks enable row level security;
alter table public.pmt_reminders enable row level security;
alter table public.pmt_activity enable row level security;
alter table public.pmt_notifications enable row level security;

comment on table public.pmt_activity is 'Append-only audit events; never the source of current business state.';
comment on table public.pmt_submissions is 'One durable row per task submission event.';
comment on table public.pmt_client_decisions is 'One durable row per client decision event and stage revision.';
comment on table public.pmt_reworks is 'One durable row per client-change rework cycle.';

commit;