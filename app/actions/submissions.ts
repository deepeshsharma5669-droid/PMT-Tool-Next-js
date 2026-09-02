'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'



import { ok, fail, type ActionResult } from './result'

export type SubmissionOptionInput = { name: string; link: string; note?: string }

/** The canonical RPC enforces the explicitly assigned active Reviewer. */
async function requireCanReviewTask(taskId:string):Promise<void>{
 const supabase=await createClient();const {data,error}=await supabase.rpc('pmt_can_review_task',{p_task_id:taskId});
 if(error||!data)throw new Error('Only the assigned active Reviewer may review this Task.');
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
