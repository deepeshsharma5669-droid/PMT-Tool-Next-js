# Consolidated team feedback — local implementation handoff

Date: 2026-08-27. Repository: D:/Deepesh/PMT/pmt-nextjs.

Implemented locally. Migration 006 has NOT been executed. No Supabase connection, seed data, Auth changes, commit, staging, or push was performed for this phase. This report is not approval for remote application: database execution, concurrency behavior, and authenticated end-to-end workflows still require verification.

## 1. Files changed

The following files were added or edited during this phase. The repository was already dirty; its other pre-existing changes, including legacy-migration relocation and earlier Auth work, were preserved.

- [app/actions/campaigns.ts](D:/Deepesh/PMT/pmt-nextjs/app/actions/campaigns.ts)
- [app/actions/client-decisions.ts](D:/Deepesh/PMT/pmt-nextjs/app/actions/client-decisions.ts)
- [app/actions/submissions.ts](D:/Deepesh/PMT/pmt-nextjs/app/actions/submissions.ts)
- [app/actions/tasks.ts](D:/Deepesh/PMT/pmt-nextjs/app/actions/tasks.ts)
- [app/actions/team-workflow.ts](D:/Deepesh/PMT/pmt-nextjs/app/actions/team-workflow.ts)
- [app/campaigns/[campaignId]/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/campaigns/[campaignId]/page.tsx)
- [app/campaigns/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/campaigns/page.tsx)
- [app/clients/[clientId]/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/clients/[clientId]/page.tsx)
- [app/deliverables/[deliverableId]/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/deliverables/[deliverableId]/page.tsx)
- [app/stages/[stageId]/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/stages/[stageId]/page.tsx)
- [app/tasks/[taskId]/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/tasks/[taskId]/page.tsx)
- [app/work/page.tsx](D:/Deepesh/PMT/pmt-nextjs/app/work/page.tsx)
- [app/globals.css](D:/Deepesh/PMT/pmt-nextjs/app/globals.css)
- [components/campaigns/campaign-management.tsx](D:/Deepesh/PMT/pmt-nextjs/components/campaigns/campaign-management.tsx)
- [components/campaigns/campaign-documents.tsx](D:/Deepesh/PMT/pmt-nextjs/components/campaigns/campaign-documents.tsx)
- [components/campaigns/new-project.tsx](D:/Deepesh/PMT/pmt-nextjs/components/campaigns/new-project.tsx)
- [components/client-decision/client-decision-panel.tsx](D:/Deepesh/PMT/pmt-nextjs/components/client-decision/client-decision-panel.tsx)
- [components/client-decision/feedback-work.tsx](D:/Deepesh/PMT/pmt-nextjs/components/client-decision/feedback-work.tsx)
- [components/client-decision/rework-summary.tsx](D:/Deepesh/PMT/pmt-nextjs/components/client-decision/rework-summary.tsx)
- [components/clients/client-poc-manager.tsx](D:/Deepesh/PMT/pmt-nextjs/components/clients/client-poc-manager.tsx)
- [components/dashboard/role-dashboard.tsx](D:/Deepesh/PMT/pmt-nextjs/components/dashboard/role-dashboard.tsx)
- [components/hierarchy/campaign-explorer.tsx](D:/Deepesh/PMT/pmt-nextjs/components/hierarchy/campaign-explorer.tsx)
- [components/shared/common-filters.tsx](D:/Deepesh/PMT/pmt-nextjs/components/shared/common-filters.tsx)
- [components/shared/date-time.tsx](D:/Deepesh/PMT/pmt-nextjs/components/shared/date-time.tsx)
- [components/shared/governance.tsx](D:/Deepesh/PMT/pmt-nextjs/components/shared/governance.tsx)
- [components/shell/navigation.ts](D:/Deepesh/PMT/pmt-nextjs/components/shell/navigation.ts)
- [components/shell/shell-welcome.tsx](D:/Deepesh/PMT/pmt-nextjs/components/shell/shell-welcome.tsx)
- [components/tasks/task-actions.tsx](D:/Deepesh/PMT/pmt-nextjs/components/tasks/task-actions.tsx)
- [components/tasks/task-editor.tsx](D:/Deepesh/PMT/pmt-nextjs/components/tasks/task-editor.tsx)
- [components/tasks/task-workspace.tsx](D:/Deepesh/PMT/pmt-nextjs/components/tasks/task-workspace.tsx)
- [components/tasks/regularization-panel.tsx](D:/Deepesh/PMT/pmt-nextjs/components/tasks/regularization-panel.tsx)
- [components/work/work-explorer.tsx](D:/Deepesh/PMT/pmt-nextjs/components/work/work-explorer.tsx)
- [lib/dashboard/data.ts](D:/Deepesh/PMT/pmt-nextjs/lib/dashboard/data.ts)
- [lib/hierarchy/data.ts](D:/Deepesh/PMT/pmt-nextjs/lib/hierarchy/data.ts)
- [lib/ui/permissions.ts](D:/Deepesh/PMT/pmt-nextjs/lib/ui/permissions.ts)
- [lib/workflow/team.ts](D:/Deepesh/PMT/pmt-nextjs/lib/workflow/team.ts)
- [lib/workflow/__tests__/team-feedback.test.ts](D:/Deepesh/PMT/pmt-nextjs/lib/workflow/__tests__/team-feedback.test.ts)
- [supabase/migrations/20260825000600_consolidated_team_workflow_updates.sql](D:/Deepesh/PMT/pmt-nextjs/supabase/migrations/20260825000600_consolidated_team_workflow_updates.sql)

This handoff report is also newly added.

## 2. Migration created

[20260825000600_consolidated_team_workflow_updates.sql](D:/Deepesh/PMT/pmt-nextjs/supabase/migrations/20260825000600_consolidated_team_workflow_updates.sql).

Forward migration with BEGIN/COMMIT. Canonical 001–005 hashes match their starting values. Legacy migrations and the legacy HTML were not edited.

## 3. Database tables added/changed

New tables: pmt_change_requests, pmt_change_request_tasks, pmt_task_regularizations.

Schema changes: pmt_campaigns, pmt_deliverables and pmt_tasks gain schedules/operational state; Tasks gain reviewer, priority and task type; Deliverables gain DROPPED. pmt_stages and pmt_tasks gain composite unique keys supporting same-stage feedback/task foreign keys. pmt_campaign_documents gains an audit trigger. Existing decisions/reworks/documents remain the canonical entities; no duplicate Project/document/rework tables.

## 4. RPCs added/changed

16 new functions, including 12 authenticated mutation entry points and four private helpers/triggers:

- pmt_create_project_bundle
- pmt_create_task_v2
- pmt_update_task_v2
- pmt_set_operational_state
- pmt_set_schedule
- pmt_drop_deliverable
- pmt_add_change_request
- pmt_link_change_request
- pmt_create_change_task_v2
- pmt_request_regularization
- pmt_review_regularization
- pmt_cancel_change_request
- Private: pmt_workflow_open, pmt_guard_task_progress, pmt_validate_reviewer, pmt_document_business_event

Seven existing functions replaced in 006 only:

- pmt_can_review_task
- pmt_is_rework_target_eligible
- pmt_apply_stage_gate
- pmt_record_client_approval_with_poc
- pmt_change_deliverable_type
- pmt_submit_task_for_review
- pmt_update_campaign

Obsolete task/create-project/targeted-change entry points are revoked for public/anon/authenticated. Unused Server Actions calling those contracts were removed. Current task creation/editing and feedback controls call the new canonical entry points.

## 5. RLS/grants

Three new SELECT policies, scoped through visible Stage/Task context or requester/responsible Manager/Admin. New tables revoke direct access before granting authenticated SELECT only. New function execution is allowlisted; private helpers are not granted to authenticated users. No anonymous grant or new direct business-table write grant. Definers have search_path = public, pg_temp. Identifiers use UUID/UUID[]; JSON is transport for document/Deliverable inputs, not a second stored entity model.

## 6. Project terminology

Navigation, Project pages, cards, setup, context and related Client views use Project/Projects. Internal pmt_campaigns and /campaigns routes remain. One Deliverable derives Project; two or more derive Campaign. Historical database action codes and old audit records retain their original identifiers.

## 7. Project creation flow

Four-step setup: Information, Ideation, Brief, Deliverables. One RPC transaction persists Project, POC links, normalized documents/files, Deliverables, generated Stages, initial activation, activity and notifications. Invalid nested input rolls back the transaction.

## 8. Multi-POC behavior

Multiple active POCs from the chosen Client; one selected Primary. Existing canonical Client/Project POC invariants remain. Client creation can still have zero POCs, but a Project requires an active associated POC under the existing Project rules.

## 9. Multi-Deliverable behavior

One or more named, typed Deliverables, each with its own schedule and stage pipeline. No persisted Deliverable JSON. Duplicate names are rejected before schedule mapping.

## 10. Ideation/Brief

Both are required in setup, with title and content or file links. Existing normalized document tables are reused. Admin editing and relevant-user viewing remain on Project Detail.

## 11. Date/time

start_at/end_at are timestamptz, with database interval constraints, browser validation, datetime-local forms and locale-aware display. Overdue compares instants. Legacy date-only deadlines are converted to end-of-day Asia/Kolkata; existing dates remain compatibility fields. Task end time and Reviewer are mandatory in new Task entry points; Project/Deliverable dates remain optional.

## 12. Filters

Reusable URL-backed CommonFilters with chips, individual clear and Clear all. Project list includes Client, classification, POC, priority, status, overdue/risk. /work supports context-sensitive task/deliverable/stage views, Project/Client/department/type/status/rework filters and Task assignee/reviewer/revision/type/priority/due-range filters. Stage Tasks use the same filter component.

## 13. Admin KPIs

Project totals, active/completed/at-risk; active/overdue/changes-requested Deliverables; Client Decisions; open/in-progress/review/overdue Tasks; active Rework and decision-ready work. Risk includes overdue Project dates or unfinished child work. Values come from visible persisted hierarchy rows, not seeded counts.

## 14. Manager KPIs

Department/responsibility-scoped work, own Tasks/due-today, overdue, explicitly assigned reviews, Client changes, Change Tasks, active Deliverables, Rework, and pending regularization links.

## 15. Stage distribution

Real active Stage counts by department, plus Client review/Rework links. Categories lead to corresponding filtered /work views. Counts are not Project counts.

## 16. Manual status behavior

Operational ACTIVE/ON_HOLD is separate from workflow status. Authorized governance controls cannot select Task APPROVED or bypass Client gates. Backend authorization and a Task progression trigger enforce holds/closed parents; changes write activity.

## 17. Dropped Deliverables

Confirmation/reason in UI; canonical RPC retains Tasks/submissions/history, cancels outstanding feedback/rework and prevents further Task or Client Decision progression. Dropping alone does not complete the Project. Dropped Deliverables are excluded from Project completion requirements.

## 18. Deliverable type change

Transactional, permission-checked, allowed in active production outside review/rework. Compatible department/order prefixes preserve existing Stage IDs/names/history and append required future Stages. Removing or reordering existing responsibilities is rejected. Static Poster to Instagram Reel can retain Content/Design history and append Animation.

## 19. Reviewer

Explicit active same-department Manager selection in Task create/edit; displayed on Task lists/details/dashboard. Server Action preflight and database review RPC check the exact assigned Reviewer, not any department Manager. Existing Tasks retain NULL Reviewers until a responsible Manager explicitly assigns one; no invented assignments.

## 20. Manager Client Decision

Admin or responsible Stage Manager can record approval/changes. Canonical RPCs still validate active associated POC, department responsibility, workflow state and completed feedback work.

## 21. Additional Client feedback

Additional individual requests reuse an open formal revision, including feedback-only requests. Cancelling feedback does not itself start a new formal revision before Client Approval.

## 22. Change Request model

Normalized feedback records with revision, POC, target Stage, lifecycle and actor/time fields. Active pre-006 rework is carried forward as feedback; existing history remains intact. Backfilled items may have unknown POC rather than fabricated identity.

## 23. Feedback ↔ Task mapping

Many-to-many normalized links with unique request/task pair and same-target-stage composite foreign keys. Several feedback items can share a Task; a request can have multiple Tasks or none.

## 24. Reopen versus new Change Task

Target Manager chooses an existing relevant Task or creates a linked Change Task. Reopening APPROVED work preserves its ID and increments iteration. In-review work must finish review before additional work is attached.

## 25. Revision/iteration

Formal Client revision, individual feedback identity and Task iteration remain separate. Additional feedback does not increment the current open revision; reopening approved work increments that Task's iteration.

## 26. Rework behavior

Existing stage-level pmt_reworks remains. Completion waits for feedback coverage and reviewed linked work; unfinished production/current-revision Tasks cannot be waived by the feedback gate. Feedback cancellation is audited. Decision progression waits for all affected work, not one approved Task.

## 27. Task Regularization

Own-Task actual-time request, pending history, responsible non-requesting Manager approval/rejection with comment, and preserved correction history. Original Task audit timestamps are never overwritten by regularization. Pending requests appear in the Manager dashboard.

## 28. Activity persistence

Project, document, schedule/hold, drop/type, reviewer/reassignment, feedback/link/reopen, decision/rework and regularization events are written in the same database transaction. New feedback does not falsely create a second rework row. Existing historical snapshot text remains history; request rows govern new feedback.

## 29. Notifications

Canonical notifications for Reviewer assignment/submission, assignee work changes, targeted Client feedback, Client Decision readiness, next Stage activation and regularization request/outcome. Entity identifiers and action_code links use existing notification routing.

## 30. Tests

npm test: 75 passed, 0 failed. Nine added tests cover classification, datetime, explicit Reviewer, revision reuse, feedback gates and migration structure/security checks. These are unit/static tests, not executed PostgreSQL/RLS integration tests. Earlier pure workflow regression tests remain; their historical models do not establish 006 runtime correctness.

## 31. Typecheck

npx tsc --noEmit: passed.

## 32. Build

npm run build: passed, including /work. An initial server/client import-boundary error was fixed and the build rerun successfully. git diff --check passed. Build/typecheck may update ignored .next/tsbuildinfo artifacts; none were staged.

## 33. Browser verification

Attempted via the Browser skill. The browser runtime exited before connection, including the troubleshooting attempt. No browser workflow was verified and no test data was created.

## 34. Remaining issues / rollout requirements

- Migration 006 is unapplied and has only static review here. PostgreSQL execution, real RLS authorization and concurrent mutation behavior remain unverified; do not treat this as remote-application approval.
- The new UI expects 006 columns/RPCs. Coordinate deployment with reviewed manual migration application; against schema 005, affected loaders can show partial-data warnings.
- Existing Task Reviewers must be explicitly assigned before further start/submit/review. Historical feedback with unknown POC remains nullable.
- Authenticated Admin/Manager browser acceptance tests are still required for Project setup, same-revision multi-stage feedback, reopen/new-task paths, gates, holds/drop, type extension and regularization.
- No changes were staged, committed or pushed. Pre-existing unrelated working-tree changes were preserved.
