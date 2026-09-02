'use server'

import { redirect } from 'next/navigation'
import { headers } from 'next/headers'
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

  const h = await headers()
  const host = h.get('x-forwarded-host') ?? h.get('host')
  const protocol = h.get('x-forwarded-proto') ?? 'http'
  const origin = `${protocol}://${host}`

  const supabase = await createClient()

  const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${origin}/auth/callback?next=/register/success`,
      data: { pmt_registration_name: name },
    },
  })
  if (signUpError) {
    fail(signUpError.message)
  }

  const authUserId = signUpData.user?.id
  if (!authUserId) {
    fail('Could not create account. Please try again.')
  }

  // Migration 007 creates the PENDING PMT profile in the Auth insert
  // transaction. An immediate session lets us verify/reconcile that invariant;
  // confirmed-email callbacks do the same.
  if (signUpData.session) {
    const { error: provisionError } = await supabase.rpc('pmt_ensure_current_user_profile')
    if (provisionError) fail('Could not complete registration. Please contact an administrator.')
  }

  redirect('/register/success')
}
