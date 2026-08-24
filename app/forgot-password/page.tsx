import Link from 'next/link'
import { requestPasswordReset } from './actions'

export default async function ForgotPasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>
}) {
  const { error } = await searchParams

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
        action={requestPasswordReset}
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
          <h1 style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>Reset your password</h1>
          <p style={{ color: '#64748b', fontSize: 13, marginTop: 4 }}>
            We&apos;ll email you a link to choose a new password.
          </p>
        </div>

        {error && (
          <div style={{ background: '#fef2f2', color: '#b91c1c', fontSize: 13, padding: '8px 12px', borderRadius: 8 }}>
            {error}
          </div>
        )}

        <label style={{ fontSize: 13, fontWeight: 600, color: '#334155' }}>
          Work Email
          <input
            type="email"
            name="email"
            required
            autoComplete="email"
            style={{ display: 'block', width: '100%', marginTop: 4, padding: '8px 10px', border: '1px solid #cbd5e1', borderRadius: 8, fontSize: 14 }}
          />
        </label>

        <button
          type="submit"
          style={{ background: '#4f46e5', color: '#fff', border: 'none', borderRadius: 8, padding: '10px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}
        >
          Send reset link
        </button>

        <p style={{ fontSize: 13, color: '#64748b', textAlign: 'center', margin: 0 }}>
          <Link href="/login" style={{ color: '#4f46e5', fontWeight: 600 }}>Back to sign in</Link>
        </p>
      </form>
    </div>
  )
}
