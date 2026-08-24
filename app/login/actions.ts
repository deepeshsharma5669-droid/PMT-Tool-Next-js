'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getCurrentPmtUser } from '@/lib/auth/session'
import { resolveDestination } from '@/lib/auth/roles'

export async function login(formData: FormData) {
  const email = String(formData.get('email') ?? '').trim()
  const password = String(formData.get('password') ?? '')

  if (!email || !password) {
    redirect('/login?error=' + encodeURIComponent('Email and password are required.'))
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword({ email, password })

  if (error) {
    redirect('/login?error=' + encodeURIComponent('Invalid email or password.'))
  }

  // Destination (role home / /pending-access / /no-access) is derived
  // entirely from pmt_users, never from anything the login form submitted.
  const pmtUser = await getCurrentPmtUser()
  if (!pmtUser) {
    redirect('/no-access')
  }

  redirect(resolveDestination(pmtUser))
}

export async function logout() {
  const supabase = await createClient()
  await supabase.auth.signOut()
  redirect('/login')
}
