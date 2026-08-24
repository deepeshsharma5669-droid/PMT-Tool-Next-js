import Link from 'next/link'

export default function RegisterSuccessPage() {
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
        <p style={{ color: '#64748b', fontSize: 14, marginTop: 12 }}>Your PMT access is pending approval.</p>
        <Link
          href="/login"
          style={{ display: 'inline-block', marginTop: 20, fontSize: 13, fontWeight: 600, color: '#4f46e5' }}
        >
          Go to sign in
        </Link>
      </div>
    </div>
  )
}
