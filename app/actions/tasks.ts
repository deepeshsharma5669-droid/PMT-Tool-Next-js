'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
import { ok, fail, type ActionResult } from './result'

export async function createTask(
  stageId: string,
  title: string,
  description: string,
  assigneeId: string,
  deadline: string
): Promise<ActionResult<{ taskId: string }>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('pmt_create_task', {
    p_stage_id: stageId,
    p_title: title,
    p_description: description,
    p_assignee_id: assigneeId,
    p_deadline: deadline,
  })
  if (error) return fail(error)
  return ok({ taskId: data as string })
}

export async function reorderTasks(stageId: string, draggedTaskId: string, targetTaskId: string): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_reorder_tasks', {
    p_stage_id: stageId,
    p_dragged_task_id: draggedTaskId,
    p_target_task_id: targetTaskId,
  })
  if (error) return fail(error)
  return ok(null)
}

export async function startTask(taskId: string): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_start_task', { p_task_id: taskId })
  if (error) return fail(error)
  return ok(null)
}
