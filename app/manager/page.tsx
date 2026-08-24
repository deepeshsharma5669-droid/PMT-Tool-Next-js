import { requireManager } from '@/lib/auth/guards'
import { logout } from '@/app/login/actions'

export default async function ManagerHome() {
  const user = await requireManager()

  return (
    <div style={{ maxWidth: 640, margin: '64px auto', padding: 24, fontFamily: 'Inter, sans-serif' }}>
      <h1 style={{ fontSize: 20, fontWeight: 700 }}>Manager area</h1>
      <p style={{ color: '#64748b', fontSize: 14 }}>
        Signed in as <b>{user.name}</b> ({user.role}, {user.dept ?? 'no department'}). UI not yet migrated —
        this page exists to prove real Supabase Auth identity resolution and route protection work.
      </p>
      <form action={logout} style={{ marginTop: 16 }}>
        <button type="submit" style={{ fontSize: 13, padding: '8px 14px', borderRadius: 8, border: '1px solid #cbd5e1', background: '#f1f5f9', cursor: 'pointer' }}>
          Sign out
        </button>
      </form>
    </div>
  )
}
