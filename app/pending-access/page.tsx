import { redirect } from 'next/navigation'
import { requireAuth, getCurrentPmtUser } from '@/lib/auth/session'
import { resolveDestination } from '@/lib/auth/roles'
import { logout } from '@/app/login/actions'

export default async function PendingAccessPage() {
  await requireAuth() // -> /login if not authenticated

  const pmtUser = await getCurrentPmtUser()
  if (!pmtUser) {
    redirect('/no-access')
  }
  // If an admin has since acted on this account, don't strand them here.
  if (pmtUser.status !== 'PENDING') {
    redirect(resolveDestination(pmtUser))
  }

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
        <h1 style={{ fontSize: 18, fontWeight: 700, margin: 0 }}>Registration successful.</h1>
        <p style={{ color: '#64748b', fontSize: 14, marginTop: 12 }}>
          Your PMT access is pending approval. An administrator will review your registration shortly.
        </p>
        <p style={{ color: '#94a3b8', fontSize: 12, marginTop: 16 }}>Signed in as {pmtUser.email ?? pmtUser.name}</p>
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
