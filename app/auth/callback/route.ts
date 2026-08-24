import { NextResponse, type NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/**
 * Landing point for Supabase Auth email links (password recovery today;
 * would also handle email-confirmation links if that flow is enabled).
 * Exchanges the one-time `code` for a real session (this has to happen in
 * a Route Handler, not a Server Component, since only a Route Handler can
 * set the resulting session cookies on the response) and forwards on to
 * `next`.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url)
  const code = searchParams.get('code')
  const next = searchParams.get('next') ?? '/reset-password'

  if (code) {
    const supabase = await createClient()
    const { error } = await supabase.auth.exchangeCodeForSession(code)
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`)
    }
  }

  return NextResponse.redirect(`${origin}/login?error=${encodeURIComponent('That link is invalid or has expired.')}`)
}
