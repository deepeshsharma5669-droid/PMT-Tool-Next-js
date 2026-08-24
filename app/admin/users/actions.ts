'use server'

import { revalidatePath } from 'next/cache'
import { requireAdmin } from '@/lib/auth/guards'
import { createClient } from '@/lib/supabase/server'

const VALID_ROLES = ['ADMIN', 'MANAGER', 'MEMBER']
const VALID_DEPTS = ['Content', 'Design', 'Animation', 'ALL']

/**
 * Every action here starts with requireAdmin() — role is re-derived from
 * the caller's own session server-side every time, never trusted from any
 * hidden form field or client state. A user can never assign their own
 * role/dept/status through this or any other path.
 */

export async function assignRoleAndDept(formData: FormData) {
  await requireAdmin()

  const userId = String(formData.get('userId') ?? '')
  const role = String(formData.get('role') ?? '')
  const dept = String(formData.get('dept') ?? '')

  if (!userId || !VALID_ROLES.includes(role) || !VALID_DEPTS.includes(dept)) {
    throw new Error('Invalid role or department selection.')
  }

  const supabase = await createClient()
  const { error } = await supabase.from('pmt_users').update({ role, dept }).eq('id', userId)
  if (error) throw new Error(error.message)

  revalidatePath('/admin/users')
}

export async function activateUser(formData: FormData) {
  await requireAdmin()

  const userId = String(formData.get('userId') ?? '')
  if (!userId) throw new Error('Missing user id.')

  const supabase = await createClient()

  const { data: target } = await supabase.from('pmt_users').select('role, dept').eq('id', userId).maybeSingle()
  if (!target?.role || !target?.dept) {
    throw new Error('Assign a role and department before activating this user.')
  }

  const { error } = await supabase.from('pmt_users').update({ status: 'ACTIVE' }).eq('id', userId)
  if (error) throw new Error(error.message)

  revalidatePath('/admin/users')
}

export async function deactivateUser(formData: FormData) {
  const admin = await requireAdmin()

  const userId = String(formData.get('userId') ?? '')
  if (!userId) throw new Error('Missing user id.')
  if (userId === admin.id) {
    throw new Error('You cannot deactivate your own account.')
  }

  const supabase = await createClient()
  const { error } = await supabase.from('pmt_users').update({ status: 'INACTIVE' }).eq('id', userId)
  if (error) throw new Error(error.message)

  revalidatePath('/admin/users')
}
