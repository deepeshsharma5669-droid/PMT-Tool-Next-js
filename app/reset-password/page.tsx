import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { resetPassword } from './actions'

export default async function ResetPasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>
}) {
  const { error } = await searchParams

  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
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
          <h1 style={{ fontSize: 18, fontWeight: 700, margin: 0 }}>This link is invalid or has expired.</h1>
          <p style={{ color: '#64748b', fontSize: 14, marginTop: 12 }}>Request a new password reset link.</p>
          <Link href="/forgot-password" style={{ display: 'inline-block', marginTop: 20, fontSize: 13, fontWeight: 600, color: '#4f46e5' }}>
            Reset password
          </Link>
        </div>
      </div>
    )
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
        action={resetPassword}
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
          <h1 style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>Choose a new password</h1>
          <p style={{ color: '#64748b', fontSize: 13, marginTop: 4 }}>Signed in as {user.email}</p>
        </div>

        {error && (
          <div style={{ background: '#fef2f2', color: '#b91c1c', fontSize: 13, padding: '8px 12px', borderRadius: 8 }}>
            {error}
          </div>
        )}

        <label style={{ fontSize: 13, fontWeight: 600, color: '#334155' }}>
          New Password
          <input
            type="password"
            name="password"
            required
            minLength={8}
            autoComplete="new-password"
            style={{ display: 'block', width: '100%', marginTop: 4, padding: '8px 10px', border: '1px solid #cbd5e1', borderRadius: 8, fontSize: 14 }}
          />
        </label>

        <label style={{ fontSize: 13, fontWeight: 600, color: '#334155' }}>
          Confirm New Password
          <input
            type="password"
            name="confirmPassword"
            required
            minLength={8}
            autoComplete="new-password"
            style={{ display: 'block', width: '100%', marginTop: 4, padding: '8px 10px', border: '1px solid #cbd5e1', borderRadius: 8, fontSize: 14 }}
          />
        </label>

        <button
          type="submit"
          style={{ background: '#4f46e5', color: '#fff', border: 'none', borderRadius: 8, padding: '10px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}
        >
          Update password
        </button>
      </form>
    </div>
  )
}
