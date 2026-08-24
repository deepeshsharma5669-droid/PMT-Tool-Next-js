/**
 * Task status transition rules and ordering, ported from the legacy
 * status-transition points (submitTaskForReview, updateTaskStatus,
 * approveSelectedOption/requestChangesOnSubmission/rejectAllOptions) and
 * the drag-reorder handler `mgrDrop()` (~line 2018).
 *
 * These mirror exactly what the pmt_validate_task_transition trigger
 * enforces in the database (supabase/migrations/0003_rls_security_hardening.sql)
 * — kept intentionally simple and side-by-side comparable to minimize the
 * risk of the two drifting apart. The trigger is authoritative at
 * runtime; these are the tested reference implementation of the same rule.
 */
import type { TaskStatus, WorkflowTask } from './types'

export function isValidMemberTransition(
  oldStatus: TaskStatus,
  newStatus: TaskStatus,
  hasSubmission: boolean
): boolean {
  if (oldStatus === newStatus) return true
  if ((oldStatus === 'TODO' || oldStatus === 'CHANGES_REQUIRED') && newStatus === 'IN_PROGRESS') return true
  if (oldStatus === 'IN_PROGRESS' && newStatus === 'IN_REVIEW' && hasSubmission) return true
  return false
}

export function isValidManagerReviewTransition(oldStatus: TaskStatus, newStatus: TaskStatus): boolean {
  return oldStatus === 'IN_REVIEW' && (newStatus === 'APPROVED' || newStatus === 'CHANGES_REQUIRED')
}

/**
 * Port of mgrDrop's eligibility filter:
 *   DB.tasks.filter(t => t.stageId === task.stageId && t.status !== 'APPROVED' && t.status !== 'IN_REVIEW')
 *     .sort((a,b) => a.order - b.order)
 *
 * APPROVED tasks are historical/read-only; IN_REVIEW tasks are locked
 * pending a Manager decision — neither participates in reordering.
 */
export function reorderableTasks(stageTasks: WorkflowTask[]): WorkflowTask[] {
  return stageTasks.filter((t) => t.status !== 'APPROVED' && t.status !== 'IN_REVIEW').sort((a, b) => a.order - b.order)
}

/**
 * Port of mgrDrop's splice-and-renumber:
 *   const [draggedTask] = stageTasks.splice(draggedIdx, 1);
 *   stageTasks.splice(targetIdx, 0, draggedTask);
 *   stageTasks.forEach((t, i) => t.order = i + 1);
 *
 * Returns the full new order assignment for every reorderable task in the
 * stage (1-based, contiguous) — the caller writes these back atomically.
 */
export function recalculateTaskOrder(
  stageTasks: WorkflowTask[],
  draggedTaskId: string,
  targetTaskId: string
): { id: string; order: number }[] {
  const eligible = reorderableTasks(stageTasks)
  const draggedIdx = eligible.findIndex((t) => t.id === draggedTaskId)
  const targetIdx = eligible.findIndex((t) => t.id === targetTaskId)

  if (draggedIdx === -1 || targetIdx === -1) {
    throw new Error('Both the dragged and target task must be in the reorderable (non-APPROVED, non-IN_REVIEW) set.')
  }

  const reordered = [...eligible]
  const [draggedTask] = reordered.splice(draggedIdx, 1)
  reordered.splice(targetIdx, 0, draggedTask)

  return reordered.map((t, i) => ({ id: t.id, order: i + 1 }))
}

/**
 * Port of saveNewTask's order assignment for a brand-new task:
 *   const stageTasks = DB.tasks.filter(t => t.stageId === stageId && t.status !== 'APPROVED');
 *   const newOrder = stageTasks.length > 0 ? Math.max(...stageTasks.map(t=>t.order)) + 1 : 1;
 */
export function nextTaskOrder(stageTasks: WorkflowTask[]): number {
  const active = stageTasks.filter((t) => t.status !== 'APPROVED')
  if (active.length === 0) return 1
  return Math.max(...active.map((t) => t.order)) + 1
}

/**
 * Port of the Change Task modal's order assignment — deliberately
 * DIFFERENT from nextTaskOrder above: it does not exclude APPROVED tasks
 * from the max() calculation.
 *   const stageTasks = DB.tasks.filter(t => t.stageId === stageId);
 *   let nextOrder = stageTasks.length > 0 ? Math.max(...stageTasks.map(t => t.order)) + 1 : 1;
 */
export function nextChangeTaskOrder(stageTasks: WorkflowTask[]): number {
  if (stageTasks.length === 0) return 1
  return Math.max(...stageTasks.map((t) => t.order)) + 1
}
