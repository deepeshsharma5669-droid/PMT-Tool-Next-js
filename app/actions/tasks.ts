'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
import { requireTaskManager } from '@/lib/auth/guards'
import { ok, fail, type ActionResult } from './result'

/**
 * Resolves a Stage's department server-side, for the task-management guard
 * below — never trusted from a client-supplied value. Returns null if the
 * stage doesn't exist or isn't visible to the caller under RLS (e.g. a
 * wrong-department Manager), which requireTaskManager() below then turns
 * into a clean ForbiddenError.
 */
async function stageDept(stageId: string): Promise<string | null> {
  const supabase = await createClient()
  const { data } = await supabase.from('pmt_stages').select('dept').eq('id', stageId).maybeSingle()
  return (data?.dept as string | undefined) ?? null
}

/** Same as stageDept(), but resolved via a task id (for task-scoped operations). */
async function taskStageDept(taskId: string): Promise<string | null> {
  const supabase = await createClient()
  const { data } = await supabase.from('pmt_tasks').select('pmt_stages(dept)').eq('id', taskId).maybeSingle()
  const stage = (data as { pmt_stages: { dept: string } | null } | null)?.pmt_stages
  return stage?.dept ?? null
}

/**
 * Server Action layer authorization: every normal task-management mutation
 * explicitly enforces ACTIVE Manager + matching department here, in
 * addition to (never instead of) the workflow RPC's own checks and the
 * database RLS/trigger backstop. See supabase/migrations/0008_task_management_permissions.sql.
 */
async function requireTaskManagerForStage(stageId: string) {
  const dept = await stageDept(stageId)
  if (!dept) throw new Error('Stage not found or not visible to you.')
  return requireTaskManager(dept)
}

async function requireTaskManagerForTask(taskId: string) {
  const dept = await taskStageDept(taskId)
  if (!dept) throw new Error('Task not found or not visible to you.')
  return requireTaskManager(dept)
}

export async function reorderTasks(stageId: string, draggedTaskId: string, targetTaskId: string): Promise<ActionResult<null>> {
  try {
    await requireTaskManagerForStage(stageId)
  } catch (error) {
    return fail(error)
  }
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
