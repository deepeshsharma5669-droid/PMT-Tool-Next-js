'use server'
import { requirePmtUser } from '@/lib/auth/session'
import { createClient } from '@/lib/supabase/server'
import { ok, fail, type ActionResult } from './result'
const rpcNames = {
 createProject:'pmt_create_project_bundle', createTask:'pmt_create_task_v2', editTask:'pmt_update_task_v2', repairReviewer:'pmt_repair_task_reviewer',
 createChangeTask:'pmt_create_change_task_v2', linkFeedback:'pmt_link_change_request', cancelFeedback:'pmt_cancel_change_request',
 operationalState:'pmt_set_operational_state', schedule:'pmt_set_schedule', dropDeliverable:'pmt_drop_deliverable',
 requestRegularization:'pmt_request_regularization', reviewRegularization:'pmt_review_regularization',
} as const
export async function teamAction(action:keyof typeof rpcNames, args:Record<string,unknown>):Promise<ActionResult<unknown>> {
 await requirePmtUser()
 if (!Object.prototype.hasOwnProperty.call(rpcNames,action)) return fail(new Error('Unknown operation.'))
 const db=await createClient()
 const {data,error}=await db.rpc(rpcNames[action],args)
 return error?fail(error):ok(data)
}
