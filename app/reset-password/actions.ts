'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'

function fail(msg: string): never {
  redirect('/reset-password?error=' + encodeURIComponent(msg))
}

export async function resetPassword(formData: FormData) {
  const password = String(formData.get('password') ?? '')
  const confirmPassword = String(formData.get('confirmPassword') ?? '')

  if (!password || !confirmPassword) {
    fail('Both fields are required.')
  }
  if (password !== confirmPassword) {
    fail('Passwords do not match.')
  }
  if (password.length < 8) {
    fail('Password must be at least 8 characters.')
  }

  const supabase = await createClient()

  // Requires the recovery session established by app/auth/callback/route.ts
  // — updateUser fails cleanly if there's no session, which the page
  // itself also checks before rendering the form.
  const { error } = await supabase.auth.updateUser({ password })
  if (error) {
    fail(error.message)
  }

  await supabase.auth.signOut()
  redirect('/login?message=' + encodeURIComponent('Password updated. Sign in with your new password.'))
}
