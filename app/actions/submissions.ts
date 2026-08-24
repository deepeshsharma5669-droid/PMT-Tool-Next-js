'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
import { requireTaskManager } from '@/lib/auth/guards'
import { canManagerReviewOwnTask } from '@/lib/workflow/permissions'
import type { TaskStatus } from '@/lib/workflow/types'
import { ok, fail, type ActionResult } from './result'

export type SubmissionOptionInput = { name: string; link: string; note?: string }

/**
 * Server Action layer authorization for submission review — enforces
 * "ACTIVE Manager, same department as the Stage, task.status = IN_REVIEW"
 * here explicitly (not just via the RPC/RLS), and additionally resolves
 * the self-review rule from the database: if the reviewing Manager is ALSO
 * the task's assignee, another ACTIVE Manager in the same department must
 * exist for a normal reviewer to be required; otherwise the assignee may
 * review their own submission. Mirrors pmt_can_review_task() in
 * supabase/migrations/0008_task_management_permissions.sql — as of the
 * 0008 revision, that SQL function (also checking task.status = 'IN_REVIEW')
 * is the sole authoritative gate, since direct INSERT/UPDATE/DELETE on
 * pmt_submissions/pmt_submission_options is revoked from anon/authenticated
 * and every review RPC is SECURITY DEFINER.
 */
async function requireCanReviewTask(taskId: string): Promise<void> {
  const supabase = await createClient()
  const { data } = await supabase.from('pmt_tasks').select('assignee_id, status, pmt_stages(dept)').eq('id', taskId).maybeSingle()
  const row = data as { assignee_id: string; status: string; pmt_stages: { dept: string } | null } | null
  const dept = row?.pmt_stages?.dept
  const assigneeId = row?.assignee_id
  const status = row?.status
  if (!dept || !assigneeId || !status) throw new Error('Task not found or not visible to you.')

  const manager = await requireTaskManager(dept)

  if (status !== 'IN_REVIEW') {
    throw new Error('This task is not currently awaiting review.')
  }

  if (manager.id !== assigneeId) return // reviewing someone else's task — normal review path

  const { count } = await supabase
    .from('pmt_users')
    .select('id', { count: 'exact', head: true })
    .eq('role', 'MANAGER')
    .eq('status', 'ACTIVE')
    .eq('dept', dept)
    .neq('id', manager.id)
  const otherActiveManagerExists = (count ?? 0) > 0

  if (!canManagerReviewOwnTask({ id: manager.id, role: 'MANAGER', dept, status: 'ACTIVE' }, { assigneeId, status: status as TaskStatus }, otherActiveManagerExists)) {
    throw new Error('Another active Manager in your department must review this task since you are its assignee.')
  }
}

export async function createSubmission(
  taskId: string,
  note: string,
  options: SubmissionOptionInput[]
): Promise<ActionResult<{ submissionId: string }>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('pmt_submit_task_for_review', {
    p_task_id: taskId,
    p_note: note,
    p_options: options,
  })
  if (error) return fail(error)
  return ok({ submissionId: data as string })
}

// submitTaskForReview() is the same operation as createSubmission() above —
// the legacy code creates the submission and flips the task to IN_REVIEW as
// one atomic step (there's no separate "create a bare submission" action).
export const submitTaskForReview = createSubmission

export async function approveSubmissionOption(
  taskId: string,
  selectedOptionIds: string[],
  managerFeedback: string
): Promise<ActionResult<null>> {
  try {
    await requireCanReviewTask(taskId)
  } catch (error) {
    return fail(error)
  }
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_approve_submission_option', {
    p_task_id: taskId,
    p_selected_option_ids: selectedOptionIds,
    p_manager_feedback: managerFeedback,
  })
  if (error) return fail(error)
  return ok(null)
}

export async function requestSubmissionChanges(taskId: string, managerFeedback: string): Promise<ActionResult<null>> {
  try {
    await requireCanReviewTask(taskId)
  } catch (error) {
    return fail(error)
  }
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_request_submission_changes', {
    p_task_id: taskId,
    p_manager_feedback: managerFeedback,
  })
  if (error) return fail(error)
  return ok(null)
}

export async function rejectAllSubmissionOptions(taskId: string, managerFeedback: string): Promise<ActionResult<null>> {
  try {
    await requireCanReviewTask(taskId)
  } catch (error) {
    return fail(error)
  }
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_reject_all_submission_options', {
    p_task_id: taskId,
    p_manager_feedback: managerFeedback,
  })
  if (error) return fail(error)
  return ok(null)
}

// Task approval is the same underlying operation as reviewing a submission
// option in this codebase — the legacy PMT never has a task-approval path
// independent of the submitted variant(s). See "Remaining Risks" in the
// Phase 6 report for why approveTask()/requestTaskChanges() are aliased
// here rather than implemented as separate flows.
export const approveTask = approveSubmissionOption
export const requestTaskChanges = requestSubmissionChanges
