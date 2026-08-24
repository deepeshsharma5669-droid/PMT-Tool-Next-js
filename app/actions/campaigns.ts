'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
import { ok, fail, type ActionResult } from './result'

export type DeliverableInput = { name: string; type: string }

export async function createCampaign(
  clientId: string,
  name: string,
  deadline: string,
  deliverables: DeliverableInput[]
): Promise<ActionResult<{ campaignId: string }>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('pmt_create_campaign', {
    p_client_id: clientId,
    p_name: name,
    p_deadline: deadline,
    p_deliverables: deliverables,
  })
  if (error) return fail(error)
  return ok({ campaignId: data as string })
}

export async function updateCampaign(
  campaignId: string,
  name: string,
  priority: string,
  deadline: string,
  status: string
): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_update_campaign', {
    p_campaign_id: campaignId,
    p_name: name,
    p_priority: priority,
    p_deadline: deadline,
    p_status: status,
  })
  if (error) return fail(error)
  return ok(null)
}

export async function archiveCampaign(campaignId: string): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_archive_campaign', { p_campaign_id: campaignId })
  if (error) return fail(error)
  return ok(null)
}
