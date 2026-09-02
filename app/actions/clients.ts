'use server'
import { requireAdmin } from '@/lib/auth/guards'
import { createClient as dbClient } from '@/lib/supabase/server'
import { fail, ok, type ActionResult } from './result'
import type { ClientPoc, ClientRecord } from '@/lib/clients/data'
import { prepareClientPocs, type NewClientPoc } from '@/lib/clients/poc-input'

export type ClientInput = { name: string; contact: string; email: string; phone: string; whatsapp: string }
export type PocInput = { name: string; designation: string; email: string; phone: string; whatsapp: string; is_primary: boolean; status: 'ACTIVE' | 'INACTIVE'; notes: string }

export async function createClient(input: ClientInput, pocs: NewClientPoc[] = []): Promise<ActionResult<ClientRecord>> {
  await requireAdmin()
  let definitions: NewClientPoc[]
  try { definitions = prepareClientPocs(pocs) } catch (error) { return fail(error) }
  const db = await dbClient()
  const { data, error } = await db.rpc('pmt_create_client_bundle', {
    p_name: input.name, p_contact: input.contact, p_email: input.email,
    p_phone: input.phone, p_whatsapp: input.whatsapp, p_pocs: definitions,
  })
  return error ? fail(error) : ok({ ...data, campaignCount: 0 } as ClientRecord)
}

export async function updateClient(id: string, input: ClientInput): Promise<ActionResult<ClientRecord>> {
  await requireAdmin()
  const db = await dbClient()
  const { data, error } = await db.rpc('pmt_update_client', {
    p_client_id: id, p_name: input.name, p_contact: input.contact, p_email: input.email,
    p_phone: input.phone, p_whatsapp: input.whatsapp, p_status: null,
  })
  return error ? fail(error) : ok(data as ClientRecord)
}

export async function createClientPoc(clientId:string,input:PocInput):Promise<ActionResult<ClientPoc>>{await requireAdmin();const db=await dbClient(),{data,error}=await db.rpc('pmt_create_client_poc',{p_client_id:clientId,p_name:input.name,p_designation:input.designation,p_email:input.email,p_phone:input.phone,p_whatsapp:input.whatsapp,p_is_primary:input.is_primary,p_notes:input.notes});return error?fail(error):ok(data as ClientPoc)}
export async function updateClientPoc(id:string,input:PocInput):Promise<ActionResult<ClientPoc>>{await requireAdmin();const db=await dbClient(),{data,error}=await db.rpc('pmt_update_client_poc',{p_poc_id:id,p_name:input.name,p_designation:input.designation,p_email:input.email,p_phone:input.phone,p_whatsapp:input.whatsapp,p_is_primary:input.is_primary,p_status:input.status,p_notes:input.notes});return error?fail(error):ok(data as ClientPoc)}
export async function deactivateClientPoc(id:string):Promise<ActionResult<ClientPoc>>{await requireAdmin();const db=await dbClient(),{data,error}=await db.rpc('pmt_deactivate_client_poc',{p_poc_id:id});return error?fail(error):ok(data as ClientPoc)}
