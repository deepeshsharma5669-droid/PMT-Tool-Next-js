import Link from 'next/link'
import { redirect } from 'next/navigation'
import { getCurrentPmtUser } from '@/lib/auth/session'
import { resolveDestination } from '@/lib/auth/roles'
import { register } from './actions'

const fieldStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  marginTop: 4,
  padding: '8px 10px',
  border: '1px solid #cbd5e1',
  borderRadius: 8,
  fontSize: 14,
}
const labelStyle: React.CSSProperties = { fontSize: 13, fontWeight: 600, color: '#334155' }

export default async function RegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>
}) {
  const { error } = await searchParams

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
        action={register}
        style={{
          background: '#fff',
          border: '1px solid #e2e8f0',
          borderRadius: 12,
          padding: 32,
          width: 360,
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}
      >
        <div>
          <h1 style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>Create your PMT account</h1>
          <p style={{ color: '#64748b', fontSize: 13, marginTop: 4 }}>
            For TheFinPedia team members. An administrator approves access after you register.
          </p>
        </div>

        {error && (
          <div style={{ background: '#fef2f2', color: '#b91c1c', fontSize: 13, padding: '8px 12px', borderRadius: 8 }}>
            {error}
          </div>
        )}

        <label style={labelStyle}>
          Full Name
          <input type="text" name="name" required autoComplete="name" style={fieldStyle} />
        </label>

        <label style={labelStyle}>
          Work Email
          <input type="email" name="email" required autoComplete="email" style={fieldStyle} />
        </label>

        <label style={labelStyle}>
          Password
          <input type="password" name="password" required minLength={8} autoComplete="new-password" style={fieldStyle} />
        </label>

        <label style={labelStyle}>
          Confirm Password
          <input type="password" name="confirmPassword" required minLength={8} autoComplete="new-password" style={fieldStyle} />
        </label>

        <button
          type="submit"
          style={{ background: '#4f46e5', color: '#fff', border: 'none', borderRadius: 8, padding: '10px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}
        >
          Register
        </button>

        <p style={{ fontSize: 13, color: '#64748b', textAlign: 'center', margin: 0 }}>
          Already have an account? <Link href="/login" style={{ color: '#4f46e5', fontWeight: 600 }}>Sign in</Link>
        </p>
      </form>
    </div>
  )
}
