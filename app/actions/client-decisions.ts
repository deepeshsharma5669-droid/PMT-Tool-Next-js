'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
import { requireTaskManager } from '@/lib/auth/guards'
import { ok, fail, type ActionResult } from './result'

export async function recordClientApproval(
  stageId: string,
  channel: string,
  contactPerson: string,
  notes: string
): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_record_client_approval', {
    p_stage_id: stageId,
    p_channel: channel,
    p_contact_person: contactPerson,
    p_notes: notes,
  })
  if (error) return fail(error)
  return ok(null)
}

export async function recordClientChanges(
  stageId: string,
  channel: string,
  contactPerson: string,
  feedback: string,
  notes: string
): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_record_client_changes', {
    p_stage_id: stageId,
    p_channel: channel,
    p_contact_person: contactPerson,
    p_feedback: feedback,
    p_notes: notes,
  })
  if (error) return fail(error)
  return ok(null)
}

export type ChangeTaskInput = { title: string; description: string; assignee_id: string; deadline: string }

// Change Task creation is normal task-management authority (Manager-only,
// same department) — see supabase/migrations/0008_task_management_permissions.sql.
// This is distinct from the Client Decision RPCs above, whose Admin
// governance authority is unchanged.
export async function createChangeTasks(stageId: string, tasks: ChangeTaskInput[]): Promise<ActionResult<{ taskIds: string[] }>> {
  const supabase = await createClient()
  {
    const { data } = await supabase.from('pmt_stages').select('dept').eq('id', stageId).maybeSingle()
    const dept = (data?.dept as string | undefined) ?? null
    if (!dept) return fail(new Error('Stage not found or not visible to you.'))
    try {
      await requireTaskManager(dept)
    } catch (error) {
      return fail(error)
    }
  }
  const { data, error } = await supabase.rpc('pmt_create_change_tasks', {
    p_stage_id: stageId,
    p_tasks: tasks,
  })
  if (error) return fail(error)
  return ok({ taskIds: data as string[] })
}
