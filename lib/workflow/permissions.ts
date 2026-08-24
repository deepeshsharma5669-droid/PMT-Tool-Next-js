/**
 * Pure predicate mirrors of the RLS helper functions
 * (pmt_is_active/pmt_is_admin/pmt_is_manager_of/pmt_can_manage_stage in
 * supabase/migrations/0003_rls_security_hardening.sql). Server Actions use
 * these for early, clean-error rejection BEFORE hitting the database —
 * RLS remains the authoritative backstop regardless of what this returns.
 */
import type { Identity, TaskStatus } from './types'

export function isActive(identity: Identity): boolean {
  return identity.status === 'ACTIVE'
}

export function isAdmin(identity: Identity): boolean {
  return isActive(identity) && identity.role === 'ADMIN'
}

export function isManagerOfDept(identity: Identity, dept: string): boolean {
  return isActive(identity) && identity.role === 'MANAGER' && identity.dept === dept
}

export function canManageDept(identity: Identity, dept: string): boolean {
  return isAdmin(identity) || isManagerOfDept(identity, dept)
}

export function isTaskOwner(identity: Identity, assigneeId: string): boolean {
  return isActive(identity) && identity.role === 'MEMBER' && identity.id === assigneeId
}

/**
 * Task-management authorization — deliberately narrower than
 * canManageDept(), which also grants Admin (used for Client Decision /
 * general stage governance, unchanged by this model). Normal task CRUD
 * (create, assign, edit, reorder, deadline, Change Task creation) is
 * Manager-only: Admin's role is oversight, not day-to-day management, so
 * Admin must NOT satisfy this check even though it satisfies
 * canManageDept(). Mirrors pmt_is_task_manager() in
 * supabase/migrations/0008_task_management_permissions.sql.
 */
export function canManageTaskManagement(identity: Identity, dept: string): boolean {
  return isManagerOfDept(identity, dept)
}

/**
 * Faithful mirror of pmt_can_review_task() in
 * supabase/migrations/0008_task_management_permissions.sql — answers "is
 * this Manager authorized to review this task RIGHT NOW", not just the
 * self-review sub-case. The SQL function is authoritative at runtime
 * (enforced in the review RPCs, the pmt_tasks transition trigger, and — as
 * of the 0008 revision — is itself the sole gate, since direct
 * INSERT/UPDATE/DELETE on pmt_submissions/pmt_submission_options is
 * revoked from anon/authenticated); this is the tested reference
 * implementation of the same rule, same pattern as lib/workflow/tasks.ts.
 *
 * Callers must already have confirmed the manager is an ACTIVE Manager of
 * the task's department — this function does not re-check that.
 * `otherActiveManagerExistsInDept` must be computed from the database
 * (never trusted from the browser).
 */
export function canManagerReviewOwnTask(
  manager: Identity,
  task: { assigneeId: string; status: TaskStatus },
  otherActiveManagerExistsInDept: boolean
): boolean {
  if (task.status !== 'IN_REVIEW') return false
  if (manager.id !== task.assigneeId) return true
  return !otherActiveManagerExistsInDept
}
