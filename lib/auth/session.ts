import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { resolveDestination } from './roles'
import type { PmtUser, Role } from './types'

/**
 * Lowest-level guard: is there a Supabase Auth session at all? Used by
 * page/layout code that needs the raw auth user (rare — most code should
 * call requirePmtUser()/requireRole() instead, which also resolve identity
 * against pmt_users).
 */
export async function requireAuth() {
  const supabase = await createClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()

  if (error || !user) {
    redirect('/login')
  }

  return user
}

/**
 * Resolves the currently authenticated Supabase user to their pmt_users
 * row. Returns null if there's no session, or if the session exists but
 * has no pmt_users.auth_user_id mapping at all (rare now that registration
 * always creates a row — this is the residual "auth account exists but was
 * never provisioned" fallback case).
 *
 * Role, dept, and status ALWAYS come from this DB lookup. Nothing here
 * ever reads role/dept/status from a client-supplied value.
 */
export async function getCurrentPmtUser(): Promise<PmtUser | null> {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) return null

  const { data, error } = await supabase
    .from('pmt_users')
    .select('id, name, email, role, dept, avatar, status')
    .eq('auth_user_id', user.id)
    .maybeSingle()

  if (error || !data) return null

  return data as PmtUser
}

/**
 * Authenticated, provisioned, ACTIVE, and has a role — the only state from
 * which a route should actually be allowed to render its real content.
 * Redirects everywhere else:
 *   no session          -> /login (via requireAuth)
 *   no pmt_users row     -> /no-access
 *   status = PENDING     -> /pending-access
 *   status = INACTIVE    -> /no-access
 *   ACTIVE but no role   -> /pending-access (defensive; shouldn't occur)
 */
export async function requirePmtUser(): Promise<PmtUser & { role: Role }> {
  await requireAuth()
  const pmtUser = await getCurrentPmtUser()

  if (!pmtUser) {
    redirect('/no-access')
  }

  if (pmtUser.status !== 'ACTIVE' || !pmtUser.role) {
    redirect(resolveDestination(pmtUser))
  }

  return pmtUser as PmtUser & { role: Role }
}
