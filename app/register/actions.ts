'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'

function fail(msg: string): never {
  redirect('/register?error=' + encodeURIComponent(msg))
}

/**
 * Public self-registration. Deliberately does NOT accept role or dept —
 * those are Admin-only assignments made later in /admin/users. Every new
 * account starts status='PENDING' and cannot reach any protected route
 * until an Admin activates it (see lib/auth/roles.ts resolveDestination
 * and lib/auth/session.ts requirePmtUser).
 */
export async function register(formData: FormData) {
  const name = String(formData.get('name') ?? '').trim()
  const email = String(formData.get('email') ?? '').trim().toLowerCase()
  const password = String(formData.get('password') ?? '')
  const confirmPassword = String(formData.get('confirmPassword') ?? '')

  if (!name || !email || !password || !confirmPassword) {
    fail('All fields are required.')
  }
  if (password !== confirmPassword) {
    fail('Passwords do not match.')
  }
  if (password.length < 8) {
    fail('Password must be at least 8 characters.')
  }

  const supabase = await createClient()

  const { data: signUpData, error: signUpError } = await supabase.auth.signUp({ email, password })
  if (signUpError) {
    fail(signUpError.message)
  }

  const authUserId = signUpData.user?.id
  if (!authUserId) {
    fail('Could not create account. Please try again.')
  }

  // If an Admin already pre-created a placeholder pmt_users row for this
  // email (not a flow this phase builds, but the column supports it), link
  // to it instead of creating a duplicate. Otherwise, create a fresh
  // PENDING profile with no role/dept.
  const { data: existing } = await supabase
    .from('pmt_users')
    .select('id, auth_user_id')
    .eq('email', email)
    .maybeSingle()

  if (existing?.auth_user_id) {
    fail('An account with this email already exists.')
  } else if (existing) {
    const { error: linkError } = await supabase
      .from('pmt_users')
      .update({ auth_user_id: authUserId, name })
      .eq('id', existing.id)
    if (linkError) fail('Could not complete registration. Please contact an administrator.')
  } else {
    const { error: insertError } = await supabase.from('pmt_users').insert({
      id: authUserId,
      auth_user_id: authUserId,
      name,
      email,
      status: 'PENDING',
      role: null,
      dept: null,
    })
    if (insertError) fail('Could not complete registration. Please contact an administrator.')
  }

  redirect('/register/success')
}
