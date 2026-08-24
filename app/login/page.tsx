import Link from 'next/link'
import { redirect } from 'next/navigation'
import { getCurrentPmtUser } from '@/lib/auth/session'
import { resolveDestination } from '@/lib/auth/roles'
import { login } from './actions'

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; message?: string }>
}) {
  const { error, message } = await searchParams

  const pmtUser = await getCurrentPmtUser()
  if (pmtUser) {
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
      <form
        action={login}
        style={{
          background: '#fff',
          border: '1px solid #e2e8f0',
          borderRadius: 12,
          padding: 32,
          width: 340,
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}
      >
        <div>
          <h1 style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>PMT Sign in</h1>
          <p style={{ color: '#64748b', fontSize: 13, marginTop: 4 }}>Sign in with your TheFinPedia work account.</p>
        </div>

        {message && (
          <div style={{ background: '#f0fdf4', color: '#15803d', fontSize: 13, padding: '8px 12px', borderRadius: 8 }}>
            {message}
          </div>
        )}

        {error && (
          <div style={{ background: '#fef2f2', color: '#b91c1c', fontSize: 13, padding: '8px 12px', borderRadius: 8 }}>
            {error}
          </div>
        )}

        <label style={{ fontSize: 13, fontWeight: 600, color: '#334155' }}>
          Email
          <input
            type="email"
            name="email"
            required
            autoComplete="email"
            style={{ display: 'block', width: '100%', marginTop: 4, padding: '8px 10px', border: '1px solid #cbd5e1', borderRadius: 8, fontSize: 14 }}
          />
        </label>

        <label style={{ fontSize: 13, fontWeight: 600, color: '#334155' }}>
          Password
          <input
            type="password"
            name="password"
            required
            autoComplete="current-password"
            style={{ display: 'block', width: '100%', marginTop: 4, padding: '8px 10px', border: '1px solid #cbd5e1', borderRadius: 8, fontSize: 14 }}
          />
        </label>

        <button
          type="submit"
          style={{ background: '#4f46e5', color: '#fff', border: 'none', borderRadius: 8, padding: '10px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}
        >
          Sign in
        </button>

        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13 }}>
          <Link href="/register" style={{ color: '#4f46e5', fontWeight: 600 }}>Create account</Link>
          <Link href="/forgot-password" style={{ color: '#64748b' }}>Forgot password?</Link>
        </div>
      </form>
    </div>
  )
}
