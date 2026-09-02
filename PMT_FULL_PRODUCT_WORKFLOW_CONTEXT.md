# PMT — Full Product, Workflow & Database Context

## 1. Product Overview

PMT is a production/project management application for managing creative/marketing work from initial client/project setup through execution, review, client feedback, revisions, rework, and completion.

The application is being built as a real **Next.js + TypeScript + Supabase** system.

The key product requirement is:

> Everything meaningful performed from the frontend must be captured and persisted in Supabase in a structured way.

The system must distinguish:

- Current state
- Business history
- Relationships
- Audit/activity
- Notifications

The frontend must never be the only source of truth for meaningful business events.

---

## 2. Technology

Current stack:

- Next.js
- TypeScript
- Supabase
- Supabase Auth
- PostgreSQL
- Server Actions
- PostgreSQL RPCs
- RLS

The old HTML application was an earlier prototype.

### Important

The old HTML application and its old Supabase database are **legacy only**.

Do not use the old HTML implementation as the source of truth.

Do not connect the current application to the old Supabase project.

Current source of truth:

1. Current Next.js codebase
2. Current canonical Supabase database
3. Current migrations/RPCs
4. Explicit product requirements

Screenshots can be considered UX references only.

---

# 3. New Canonical Supabase Project

A brand-new Supabase project was created for the real PMT application.

The old HTML data is disposable.

The new Supabase project is the canonical database.

Applied migrations:

- `20260825000100_canonical_pmt_baseline.sql`
- `20260825000200_canonical_workflow_rpc_and_rls.sql`
- `20260825000300_client_management.sql`
- `20260825000400_client_pocs_campaign_documents_workflow.sql`
- `20260825000500_client_poc_creation_flow.sql`

Current Migration 006:

`20260825000600_consolidated_team_workflow_updates.sql`

is currently **NOT approved for remote application** until its blockers are fixed and reviewed.

---

# 4. Current Core Database Model

Core:

- `pmt_users`
- `pmt_clients`
- `pmt_campaigns`
- `pmt_deliverables`
- `pmt_stages`
- `pmt_tasks`

Execution:

- `pmt_submissions`
- `pmt_submission_options`

Client workflow:

- `pmt_client_decisions`
- `pmt_deliverable_feedback`
- `pmt_reworks`

Operations:

- `pmt_reminders`
- `pmt_activity`
- `pmt_notifications`

Additional normalized tables already added:

- `pmt_client_pocs`
- `pmt_campaign_pocs`
- `pmt_campaign_documents`
- `pmt_campaign_document_files`

Migration 006 locally adds/proposes:

- `pmt_change_requests`
- `pmt_change_request_tasks`
- `pmt_task_regularizations`

---

# 5. Database Design Rules

Never mix unrelated concepts in one table.

### Current state

Examples:

- `pmt_tasks.status`
- `pmt_stages.status`
- `pmt_deliverables.status`
- `pmt_deliverables.client_revision`

### Business history

Examples:

- `pmt_submissions`
- `pmt_client_decisions`
- `pmt_deliverable_feedback`
- `pmt_reworks`
- `pmt_change_requests`

### Relationships

Examples:

- `pmt_client_pocs`
- `pmt_campaign_pocs`
- `pmt_change_request_tasks`
- `pmt_campaign_document_files`

### Audit

`pmt_activity`

### Notifications

`pmt_notifications`

Do NOT use JSON as the canonical source of truth for relational data.

Do NOT store:

- POCs in JSON
- Campaign POCs in JSON
- Deliverables in JSON
- files in JSON
- submissions in JSON
- Change Request ↔ Task relationships in JSON

JSON is acceptable for:

- RPC transport payloads
- variable metadata

---

# 6. Authentication

Supabase Auth maps into:

`pmt_users.auth_user_id`

One Auth user corresponds to one PMT user profile.

Roles:

- ADMIN
- MANAGER
- MEMBER

Statuses:

- PENDING
- ACTIVE
- INACTIVE

There is no CLIENT user role.

A real Admin has been created in the new Supabase project.

The root route was fixed so:

```text
/
→ unauthenticated → /login
→ authenticated ACTIVE PMT user → /dashboard
```

The previous crash happened because `/` used the legacy HTML application and accessed `AppState.currentUser.role` before the user existed.

Do not reintroduce the legacy root implementation.

---

# 7. Client Model

A Client represents an organization.

The Client itself is NOT deactivated in the product.

There should be no Client Deactivate UI/action.

Do not physically delete Clients in the normal product workflow.

The Client may have:

- zero POCs
- one POC
- multiple POCs

---

# 8. Client POC Model

Table:

`pmt_client_pocs`

A POC is a person associated with a Client.

Typical fields:

- id
- client_id
- name
- designation
- email
- phone
- whatsapp
- is_primary
- status
- notes
- created_at
- updated_at

POC status:

- ACTIVE
- INACTIVE

Rules:

- Adding a POC during Client creation is optional.
- Client creation with zero POCs is valid.
- Client creation with one POC is valid.
- Client creation with multiple POCs is valid.
- POCs can also be added later from Client Detail.
- An inactive POC cannot be Primary.
- If active POCs exist, exactly one active POC may be Primary.
- If there are zero active POCs, no Primary is required.
- Deactivating a Primary POC should promote a deterministic active replacement if available.
- Do not create fake POCs.

---

# 9. Client Creation UX

Preferred flow:

```text
+ New Client

Client Information
- Client Name *
- Email
- Phone
- WhatsApp

Client POCs
- Optional

+ Add POC

POC:
- Name
- Designation
- Email
- Phone
- WhatsApp
- Primary

+ Add another POC

[Create Client]
```

Valid:

```text
Client with 0 POCs
Client with 1 POC
Client with many POCs
```

If no POCs are supplied:

- Client must still be created successfully.
- No Primary POC is required.

If POCs are supplied:

- exactly one active POC is Primary.

Creation should be atomic:

```text
pmt_clients
+
0..N pmt_client_pocs
+
activity
```

---

# 10. Project / Campaign Terminology

The team wants **Campaign** renamed to **Project** in the main product UX.

Do NOT rename the database table `pmt_campaigns` yet.

Do NOT create a duplicate `pmt_projects` table just for terminology.

Business classification:

- 1 Deliverable = Project
- 2+ Deliverables = Campaign

The UI should primarily use:

- Projects
- Project
- Project Detail

The underlying database can still use:

`pmt_campaigns`

---

# 11. Project Structure

Conceptual hierarchy:

```text
Client
├── Client POCs
└── Project
    ├── Project information
    ├── Project POCs
    ├── Ideation
    ├── Brief
    └── Deliverables
        └── Stages
            └── Tasks
```

A Project/Campaign can have multiple Deliverables.

A Project/Campaign can have multiple selected Client POCs.

---

# 12. Project POCs

Table:

`pmt_campaign_pocs`

A Project/Campaign can have multiple POCs from the Client's POC pool.

Rules:

- POC must belong to the Project's Client.
- Only active POCs can be selected.
- Multiple Project POCs are allowed.
- Exactly one Project POC is Primary when Project POCs exist.
- Database-level ownership/primary invariants exist.
- Do not store multiple POC IDs in JSON.

---

# 13. Project Creation

Preferred setup flow:

```text
+ New Project

1. Project Details
2. Client
3. Project POCs
4. Ideation
5. Brief
6. Deliverables
7. Create Project
```

Project creation should support:

- Project name
- Client
- multiple Project POCs
- Priority
- Start date/time
- End date/time
- Ideation
- Brief
- multiple Deliverables

Each Deliverable:

- Name
- Type
- Start date/time
- End date/time

Creation should be atomic.

Expected transaction:

```text
Project
+
Project POCs
+
Ideation
+
Brief
+
Deliverables
+
Stages
+
First-stage activation where required
+
Activity
+
Notifications where required
```

No partial Project should remain if a required operation fails.

---

# 14. Ideation and Brief

Every Project has:

- Ideation
- Brief

These are Project-level.

They are not Client-level.

They are not Deliverable-level.

Admin can:

- Add
- Edit
- Delete

Manager and Member:

- View
- Open links/files
- No edit
- No delete

Use the existing normalized tables:

`pmt_campaign_documents`

and

`pmt_campaign_document_files`

Document types:

- IDEATION
- BRIEF

Each document can have multiple files.

Each file stores:

- file_name
- file_url

Do not store files in JSON.

---

# 15. Project/Deliverable/Task Schedule

Project, Deliverable and Task should have:

- `start_at`
- `end_at`

Use PostgreSQL `timestamptz`.

Do not use separate date and time fields.

Validate:

`end_at >= start_at`

Schedule needs to be displayed consistently in:

- create forms
- edit forms
- cards
- details
- dashboards
- filters

---

# 16. Deliverables

Table:

`pmt_deliverables`

A Project can have multiple Deliverables.

Deliverables are independent database rows.

Typical statuses:

- IN_PROGRESS
- CLIENT_REVIEW
- CHANGES_REQUESTED
- COMPLETED
- DROPPED

---

# 17. Dropped Deliverable

A Client may say they no longer need a Deliverable.

The Deliverable becomes:

`DROPPED`

Dropping is NOT deletion.

When a Deliverable is dropped:

- preserve history
- preserve Tasks
- preserve submissions
- preserve Client Decision history
- preserve activity
- stop future production
- prevent new Tasks
- prevent Client Decision progression
- exclude from active production lists
- exclude from Awaiting Client Decision counts
- Project itself remains unaffected

Activity:

`DELIVERABLE_DROPPED`

---

# 18. Deliverable Type Change

Deliverable Type may change during the workflow.

Example:

```text
Static Poster
→ Instagram Reel
```

This is not only a label change.

Backend must:

- validate current state
- preserve completed history
- preserve existing Stage/Task IDs where applicable
- reconcile future workflow stages
- append compatible future stages if necessary
- not silently delete completed work
- write Activity
- perform change atomically

Example:

```text
Static Poster
→ Content
→ Design
```

can become:

```text
Instagram Reel
→ Content
→ Design
→ Animation
```

without destroying historical work.

If the change is unsafe at the current workflow state, reject it clearly.

---

# 19. Stages

Stages belong to Deliverables.

Examples may include:

- Content
- Design
- Animation

but stage names must remain data-driven.

A stage can be:

- PENDING
- ACTIVE
- CLIENT_DECISION
- COMPLETED

A stage can also have targeted rework.

Do not hardcode Content/Design/Animation logic if equivalent dynamic workflow data exists.

---

# 20. Tasks

Tasks belong to Stages.

Task contains:

- title
- description
- assignee
- reviewer
- start/end
- deadline/schedule
- priority
- type
- status
- iteration
- task order
- Client Revision where applicable
- `is_client_change`
- feedback/context
- timestamps

Normal Task statuses:

- TODO
- IN_PROGRESS
- IN_REVIEW
- CHANGES_REQUIRED
- APPROVED

---

# 21. Task Assignee and Reviewer

Every new Task should have:

- Assignee
- Reviewer

`reviewer_id` identifies the specific person who should review.

Normal review authorization:

```text
current_user.id = task.reviewer_id
```

Only the assigned Reviewer can perform normal review.

Do not use:

```text
any Manager in the department can review
```

as the normal rule.

Admin may have governance/override capabilities where explicitly required.

---

# 22. Historical Tasks and Reviewer Repair

Some Tasks existed before `reviewer_id`.

Historical Tasks may have:

- `reviewer_id = NULL`
- inactive assignee
- historically valid but currently ineligible assignment/reviewer state

Do NOT randomly assign Reviewers.

Provide a controlled repair mechanism for authorized Admin/Manager users.

Repair should:

- preserve historical assignment
- assign a valid active Reviewer
- be audited
- allow the Task to continue/reopen where appropriate

Once repaired, normal Reviewer-specific enforcement applies.

---

# 23. Submissions

A Task can have multiple submission events.

Table:

`pmt_submissions`

Submission is business history.

Do not store submission history in `pmt_tasks.submissions` JSON.

Submission can have multiple options via:

`pmt_submission_options`

---

# 24. Client Decision

Client Decision supports:

- APPROVED
- CHANGES_REQUESTED

Both:

- Admin
- Authorized Manager

may record Client Decisions.

Members cannot.

Client Decision must identify:

- Client POC
- Channel
- Feedback
- Notes
- Deliverable
- Stage context
- Client Revision
- Recorded by
- Timestamp

The POC must:

- be ACTIVE
- belong to the correct Client
- be valid for the Project/context

Do not make free-text Contact Person the canonical source.

---

# 25. Client Changes

Client Changes can be recorded by:

- Admin
- Authorized Manager

When Client Changes are recorded, user selects:

- Client POC
- Channel
- Feedback
- Target Stage
- Notes

The target Stage is SINGLE-select.

The target Stage must be a stage that has actually produced/submitted work for the Deliverable.

Example:

```text
Stages:
Content
Design
Animation

Content worked
Design worked
Animation not worked
```

Eligible:

```text
Content
Design
```

Animation must NOT be selectable.

If only Content worked:

```text
Content
```

only.

Do not list every configured workflow Stage.

Do not allow future/unworked stages.

Backend and UI must enforce the same rule.

---

# 26. Source Stage Safety

A future/unworked Stage must not become the source/decision Stage for additional Client feedback.

Approval must independently validate every Stage it will complete.

Never use:

- highest stage order
- Stage existence
- arbitrary metadata

as proof of prior-work completion.

---

# 27. Rework

Rework remains a STAGE-level concept.

Example:

```text
Revision 1
Design Rework
```

can contain:

```text
Change Request 1 → Task A
Change Request 2 → Task A
Change Request 3 → Task B
```

Only the affected Stage should be in targeted rework.

Only the Manager responsible for that Stage gets:

`+ Add Change Task`

Other Managers do not.

Members do not.

Backend must enforce.

---

# 28. Client Revision

Client Revision is a FORMAL revision cycle.

Example:

```text
Revision 1
```

can contain multiple Client feedback items.

Do NOT increment revision every time the Client sends another message.

Example:

```text
Revision 1

Feedback 1
Feedback 2
Feedback 3
```

All remain Revision 1 if the formal revision cycle is still active.

Revision 2 should start only after Revision 1 is genuinely closed and a new formal client revision cycle begins.

---

# 29. Change Requests / Client Feedback

Individual Client feedback should have its own structured records.

Concept:

`pmt_change_requests`

Typical fields:

- id
- deliverable_id
- client_revision
- client_poc_id
- target_stage_id
- feedback
- status
- created_by
- created_at
- resolved_by
- resolved_at

Suggested statuses:

- OPEN
- IN_PROGRESS
- ADDRESSED
- RESOLVED
- CANCELLED

A Change Request may exist without a Task.

Important:

> One Client feedback item does NOT automatically mean one Task.

---

# 30. Feedback ↔ Task Relationship

Concept:

`pmt_change_request_tasks`

This allows:

```text
Feedback 1 → Task A
Feedback 2 → Task A
Feedback 3 → Task B
```

A single Task may address multiple feedback items.

A feedback item may be handled by one or multiple Tasks where appropriate.

Do not enforce:

```text
1 feedback = 1 task
```

---

# 31. Client Feedback While Rework Is In Progress

This is a critical real-world scenario.

Example:

```text
Revision 1

Client Change #1:
"Change headline"

Manager reopens Task A.

Task A:
Iteration 2
IN_PROGRESS

Client then sends:

Client Change #2:
"Also change CTA"
```

This is STILL:

```text
Revision 1
```

It is NOT Revision 2.

The Manager can decide:

```text
Change Request #2
→ attach to existing Task A
```

No new Task required.

Or:

```text
Change Request #2
→ create new Change Task
```

if separate work is actually required.

---

# 32. Task Reopen Behavior

If an existing approved Task is enough to handle Client feedback:

- reuse same Task ID
- reopen it
- increment Task iteration
- preserve old Task history
- attach Change Request to it
- return to executable state

Example:

```text
Task A
Iteration 1 → APPROVED

Client Change
→ reopen

Task A
Iteration 2 → IN_PROGRESS
```

Do not create a duplicate Task.

---

# 33. New Change Task

If the existing Tasks do not cover the Client feedback:

Manager can create a new Change Task.

It should have:

- `is_client_change = true`
- current `client_revision`
- target `stage_id`
- relationship to Change Request

---

# 34. Client Feedback and Task Independence

A Change Request can exist without any Task yet.

Example:

```text
Revision 1
Change Request #4
Status = OPEN
No Task attached
```

Manager later decides whether to:

- attach existing Task
- reopen Task
- create new Change Task

Task creation is an operational decision, not an automatic reaction to every feedback message.

---

# 35. Rework Completion

A Stage/Rework must not be considered complete simply because one Task is approved.

Completion must take into account:

- unresolved Change Requests
- linked Tasks
- current revision
- active rework
- workflow gate

A completed Change Task does not automatically mean all Client feedback has been resolved.

---

# 36. Cancellation

Cancellation must not be a way to bypass unfinished required work.

Before any workflow completion/approval:

- active/incomplete rework must be checked
- OPEN/IN_PROGRESS feedback must be checked
- required Tasks must be checked
- Stage completion must be independently validated

Cancelled feedback should not implicitly waive unfinished executable work.

---

# 37. Task Regularization

Task Regularization handles cases where a user completed work but updated PMT late.

Example:

```text
Actual work:
6:00 PM → 7:30 PM

PMT updated:
9:00 PM
```

User can request Regularization.

Suggested table:

`pmt_task_regularizations`

Fields:

- id
- task_id
- user_id
- actual_start_at
- actual_end_at
- reason
- status
- requested_at
- reviewed_by
- reviewed_at
- manager_comment

Statuses:

- PENDING
- APPROVED
- REJECTED

Workflow:

```text
User
→ Request Regularization
→ Manager reviews
→ Approve / Reject
```

Do NOT overwrite original Task timestamps.

Create Activity:

- `REGULARIZATION_REQUESTED`
- `REGULARIZATION_APPROVED`
- `REGULARIZATION_REJECTED`

---

# 38. Manual Status Changes

Admin and authorized Managers need controlled manual status editing.

However:

> Manual status control must not bypass workflow rules.

Operational states can be changed where appropriate.

Workflow-sensitive states remain validated.

Do not allow arbitrary:

```text
TODO → APPROVED
```

or equivalent bypasses.

Every meaningful manual status change should write:

`STATUS_CHANGED`

to Activity.

---

# 39. Dashboard — Admin

Admin dashboard should answer:

> What do I need to know immediately?

Useful KPIs:

### Projects

- Total
- Active
- Completed
- At Risk

### Deliverables

- Active
- Overdue
- Client Decision Required
- Changes Requested

### Tasks

- Open
- In Progress
- Awaiting Review
- Overdue

### Rework

- Active Rework
- Ready for Client Decision

---

# 40. Admin Stage/Department Distribution

Admin needs a visual distribution of where Deliverables currently are.

Example:

```text
Content       12
Design         8
Animation      4
Client Review  3
Rework         2
```

This represents Deliverable/Stage operational state.

It should NOT represent entire Projects.

A Project can remain:

```text
IN PROGRESS
```

while one of its Deliverables is:

```text
IN REWORK
```

Do not display Rework as the Project status.

---

# 41. Admin Actions Required

Admin dashboard needs an operational queue.

Examples:

```text
Client Decision Required
Project
Client
Deliverable
POC
Revision
Stage
Action
```

and:

```text
Client Rework
Project
Deliverable
Revision
Target Stage
Manager
Change Request count
Task progress
Status
```

and:

```text
Rework Complete
Ready for Client Decision
```

The Admin should not need to navigate through multiple levels to discover urgent work.

No hardcoded counts.

---

# 42. Manager Dashboard

Manager KPIs should be focused on responsibility/department.

Examples:

- My Tasks
- Due Today
- Overdue
- Awaiting My Review
- Client Changes
- Change Tasks
- Active Deliverables
- Rework
- Regularization requests

Manager should immediately understand:

- What do I work on?
- What do I review?
- What is overdue?
- Which Client Changes need action?

---

# 43. Universal Filtering

The application needs a common filtering architecture.

Possible filters:

- Client
- Project
- Project Type
- Deliverable
- Deliverable Type
- Stage
- Department
- Status
- Priority
- Assignee
- Reviewer
- POC
- Revision
- Task Type
- Due Status
- Date Range
- Rework
- Change Task

Filters should be context-specific.

Prefer URL query parameters.

Show active filter chips.

Support:

- clear individual
- clear all

---

# 44. Activity / Audit

Every meaningful business mutation must generate a durable Activity record.

Examples:

### Client

- `CLIENT_CREATED`
- `CLIENT_POC_CREATED`
- `CLIENT_POC_UPDATED`
- `CLIENT_POC_DEACTIVATED`

### Project

- `PROJECT_CREATED`
- `PROJECT_UPDATED`
- `STATUS_CHANGED`

### Deliverable

- `DELIVERABLE_CREATED`
- `DELIVERABLE_DROPPED`
- `DELIVERABLE_TYPE_CHANGED`

### Task

- `TASK_CREATED`
- `TASK_ASSIGNED`
- `TASK_REASSIGNED`
- `TASK_REVIEWER_CHANGED`
- `TASK_STARTED`
- `TASK_SUBMITTED`
- `TASK_REOPENED`
- `TASK_APPROVED`

### Client workflow

- `CLIENT_DECISION_APPROVED`
- `CLIENT_DECISION_CHANGES_REQUESTED`
- `CHANGE_REQUEST_CREATED`
- `CHANGE_REQUEST_UPDATED`
- `CHANGE_REQUEST_LINKED_TO_TASK`
- `CHANGE_REQUEST_RESOLVED`

### Rework

- `REWORK_CREATED`
- `REWORK_COMPLETED`
- `REWORK_CANCELLED`

### Deliverable lifecycle

- `DELIVERABLE_DROPPED`
- `DELIVERABLE_TYPE_CHANGED`

### Regularization

- `REGULARIZATION_REQUESTED`
- `REGULARIZATION_APPROVED`
- `REGULARIZATION_REJECTED`

### Documents

- `CAMPAIGN_DOCUMENT_CREATED`
- `CAMPAIGN_DOCUMENT_UPDATED`
- `CAMPAIGN_DOCUMENT_DELETED`
- `CAMPAIGN_DOCUMENT_FILE_ADDED`
- `CAMPAIGN_DOCUMENT_FILE_REMOVED`

Activity must be durable in Supabase.

---

# 45. Notifications

Notifications are separate from Activity.

Activity:

> What happened?

Notification:

> Who needs to know?

Meaningful notifications include:

- Task assigned
- Reviewer assigned
- Submission received
- Client Changes received
- Stage ready for Client Decision
- Regularization requested
- Regularization approved/rejected
- Rework completed

Use structured:

- entity_type
- entity_id
- action_code

Do not create noisy notifications for trivial UI interactions.

---

# 46. Role Summary

## Admin

Can:

- manage Clients
- manage Client POCs
- manage Projects
- manage Project POCs
- manage Ideation/Brief
- manage Deliverables
- change Deliverable type
- drop Deliverables
- record Client Approval
- record Client Changes
- perform workflow governance
- manage Users
- view organization-wide dashboards
- view Activity
- view Notifications

## Manager

Can:

- see authorized Projects
- see Project/Client context
- manage department Tasks
- select/assign Reviewer where allowed
- perform review when assigned Reviewer
- record Client Decision for authorized workflow context
- record Client Changes for authorized context
- manage targeted Rework
- attach feedback to Tasks
- reopen Tasks
- create Change Tasks
- approve/reject Task Regularization

## Member

Can:

- see relevant Project context
- see Ideation/Brief
- work assigned Tasks
- submit work
- request Task Regularization

Members cannot:

- record Client Decisions
- create Change Tasks
- change Project/Client configuration

---

# 47. Current Important UI Routes

Current application routes include:

- `/`
- `/login`
- `/dashboard`
- `/clients`
- `/clients/[clientId]`
- `/campaigns`
- `/campaigns/[campaignId]`
- `/deliverables/[deliverableId]`
- `/stages/[stageId]`
- `/tasks/[taskId]`
- `/users`
- `/users/[userId]`
- `/notifications`
- `/activity`
- `/profile`

The UI is being transitioned toward Project terminology.

---

# 48. Current Test/Quality History

Previous implementation checkpoints have passed:

- 59/59 tests
- then 66 tests
- then 75 tests

with typecheck/build passing at those stages.

The current repository must be tested from its actual current state.

Always run:

```text
npm test
npx tsc --noEmit
npm run build
git diff --check
```

when making substantial changes.

---

# 49. Current Migration 006 Status

Migration:

`20260825000600_consolidated_team_workflow_updates.sql`

is NOT approved for remote application.

Latest static review found five blockers:

## Blocker 1 — Future source Stage

A future/unworked Stage can potentially become the source of additional feedback and bypass the pipeline.

Fix:

- validate source Stage against real workflow/decision/rework context
- never allow future/unworked Stage as source
- approval independently validates every Stage it completes

## Blocker 2 — Cancellation bypass

Cancellation may allow unfinished work to be bypassed.

Fix:

- validate active/incomplete rework before approval
- validate OPEN/IN_PROGRESS feedback
- validate linked Tasks
- independently validate Stage completion

## Blocker 3 — NULL-safe submission ownership

Current ownership logic has nullable `assignee_id`.

Use:

`IS DISTINCT FROM`

where NULL-safe identity comparison is required.

An unassigned Task must not pass ownership checks unexpectedly.

## Blocker 4 — Historical Reviewer repair

Historical Tasks may have no valid Reviewer.

Fix:

- controlled repair path
- no random reviewer assignment
- preserve historical assignment
- explicit audited reviewer repair
- normal Reviewer authorization after repair

## Blocker 5 — Completed-but-unapproved revision

Completed Rework that is still awaiting Client Approval must still belong to the current formal revision.

Additional feedback in that state must NOT start a new formal revision.

---

# 50. Migration 006 Non-Blocking Caveats

Previously identified:

- dropped Deliverables may appear in some Client Decision counts
- historical reworks may inflate Ready for Client Decision
- Manager Active Deliverables navigation may omit active filtering
- work lists may include dropped work
- hierarchy queries are not paginated
- differing lock ordering may create concurrency risk

The first four should be corrected if practical during 006.

Pagination/concurrency can be handled later.

---

# 51. What Must Happen Next

Immediate sequence:

```text
1. Fix Migration 006 blockers
2. Add regression tests
3. Run tests/typecheck/build/diff-check
4. Final read-only review
5. Get:
   "006 READY FOR FINAL REVIEW"
6. Apply 006 to NEW Supabase only
7. Verify database/RPC/RLS
8. Begin real end-to-end application testing
```

Do not apply 006 until final review passes.

Do not touch the legacy Supabase project.

---

# 52. Target End-to-End PMT Workflow

## Setup

```text
Client
→ optional Client POCs
→ Project
→ Project POCs
→ Ideation
→ Brief
→ Multiple Deliverables
→ Stages
→ first Stage activation
```

## Production

```text
Stage
→ Tasks
→ Assignee
→ Reviewer
→ Start
→ Work
→ Submit
→ Assigned Reviewer
→ Approve / Changes Required
```

## Client Decision

```text
Stage
→ Ready for Client Decision
→ Admin OR authorized Manager
→ select Client POC
→ Approve
OR
→ Client Changes
```

## Client Changes

```text
Client Changes
→ select ONE eligible target Stage
→ create Change Request
→ stage-specific Rework
→ responsible Manager
```

Manager chooses for each Change Request:

```text
Attach to existing Task
OR
Reopen existing approved Task
OR
Create new Change Task
```

## Additional Feedback

During the same Revision:

```text
Revision 1
├── Feedback 1 → Task A
├── Feedback 2 → Task A
└── Feedback 3 → Task B
```

Still:

```text
Revision 1
```

No automatic Revision 2.

## Rework completion

```text
All relevant feedback addressed
+
required work approved
→ Stage ready
→ Client Decision
```

## New formal revision

Only after the previous formal revision cycle is genuinely closed.

---

# 53. Fundamental PMT Data Meaning

Always keep these concepts distinct:

### Project
The overall client work container.

### Campaign
A Project with multiple Deliverables.

### Deliverable
A concrete output/product inside a Project.

### Stage
A department/workflow phase for a Deliverable.

### Task
A unit of work inside a Stage.

### Client Revision
A formal client revision cycle.

### Change Request
An individual piece of Client feedback within a Revision.

### Task Iteration
How many times a particular Task has been reopened/worked.

### Rework
Stage-level revision work.

### Submission
A historical Task submission event.

### Client Decision
A formal client outcome.

### Activity
Audit/history of what happened.

### Notification
A user-facing message about what needs attention.

### Regularization
A formal correction request for late/incorrect Task timing records.

---

# 54. Core Product Principle

The PMT system should always preserve:

```text
CURRENT STATE
+
BUSINESS HISTORY
+
RELATIONSHIPS
+
AUDIT
+
NOTIFICATIONS
```

Do not collapse them into one table.

Do not make the frontend cache the source of truth.

Do not create multiple competing mutation paths.

Do not create duplicate entities to solve terminology problems.

Do not bypass existing workflow rules just to make a button work.

The system should be operationally useful, structured, traceable, and easy for Admins, Managers, and Members to understand.
