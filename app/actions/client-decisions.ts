'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
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

export async function createChangeTasks(stageId: string, tasks: ChangeTaskInput[]): Promise<ActionResult<{ taskIds: string[] }>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('pmt_create_change_tasks', {
    p_stage_id: stageId,
    p_tasks: tasks,
  })
  if (error) return fail(error)
  return ok({ taskIds: data as string[] })
}
