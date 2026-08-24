import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getCurrentPmtUser } from '@/lib/auth/session'
import { resolveDestination } from '@/lib/auth/roles'
import { logout } from '@/app/login/actions'

export default async function NoAccessPage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const pmtUser = await getCurrentPmtUser()

  // Only PENDING/no-mapping/INACTIVE belong on this page. Anything else
  // (ACTIVE, or PENDING which has its own page) should be sent onward.
  if (pmtUser && pmtUser.status !== 'INACTIVE') {
    redirect(resolveDestination(pmtUser))
  }

  const message = pmtUser
    ? 'Your PMT account has been deactivated.'
    : 'Your account is not provisioned for PMT.'

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontFamily: 'Inter, sans-serif',
        background: '#f8fafc',
      }}
    >
      <div style={{ background: '#fff', border: '1px solid #e2e8f0', borderRadius: 12, padding: 32, width: 380, textAlign: 'center' }}>
        <h1 style={{ fontSize: 18, fontWeight: 700, margin: 0 }}>{message}</h1>
        <p style={{ color: '#64748b', fontSize: 14, marginTop: 12 }}>
          Contact an administrator.
        </p>
        <p style={{ color: '#94a3b8', fontSize: 12, marginTop: 16 }}>Signed in as {user.email}</p>
        <form action={logout} style={{ marginTop: 20 }}>
          <button
            type="submit"
            style={{ background: '#f1f5f9', color: '#334155', border: '1px solid #cbd5e1', borderRadius: 8, padding: '8px 16px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}
          >
            Sign out
          </button>
        </form>
      </div>
    </div>
  )
}
