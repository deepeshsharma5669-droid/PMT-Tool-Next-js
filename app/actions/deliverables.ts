'use server'

import { createClient } from '@/lib/supabase/server'
import { requirePmtUser } from '@/lib/auth/session'
import { ok, fail, type ActionResult } from './result'

export async function createDeliverable(
  campaignId: string,
  name: string,
  type: string
): Promise<ActionResult<{ deliverableId: string }>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('pmt_add_deliverable', {
    p_campaign_id: campaignId,
    p_name: name,
    p_type: type,
  })
  if (error) return fail(error)
  return ok({ deliverableId: data as string })
}

// addDeliverableToCampaign() is the same operation as createDeliverable()
// above — the legacy code has one function for both the wizard's initial
// deliverable list and "add to an existing campaign" (saveAddDeliverableToCampaign),
// both of which just insert a deliverable + generate its stage pipeline.
export const addDeliverableToCampaign = createDeliverable

export async function updateDeliverableType(deliverableId: string, newType: string): Promise<ActionResult<null>> {
  await requirePmtUser()
  const supabase = await createClient()
  const { error } = await supabase.rpc('pmt_change_deliverable_type', {
    p_deliverable_id: deliverableId,
    p_new_type: newType,
  })
  if (error) return fail(error)
  return ok(null)
}
