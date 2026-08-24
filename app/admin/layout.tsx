import Link from 'next/link'
import { requireAdmin } from '@/lib/auth/guards'
import { logout } from '@/app/login/actions'

/**
 * Gates everything under /admin behind real Supabase Auth + ADMIN role.
 * Adds a minimal top bar (User Access link + sign out) so the new
 * /admin/users page is reachable — does not touch app/admin/page.tsx
 * itself, which is still the existing mock-data.ts proof-of-concept
 * (UI migration is a later phase).
 */
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  await requireAdmin()

  return (
    <div>
      <div
        style={{
          display: 'flex',
          justifyContent: 'flex-end',
          gap: 16,
          alignItems: 'center',
          padding: '10px 24px',
          borderBottom: '1px solid #e2e8f0',
          background: '#fff',
          fontFamily: 'Inter, sans-serif',
          fontSize: 13,
        }}
      >
        <Link href="/admin/users" style={{ color: '#4f46e5', fontWeight: 600 }}>
          User Access
        </Link>
        <form action={logout}>
          <button
            type="submit"
            style={{ background: 'none', border: 'none', color: '#64748b', cursor: 'pointer', fontSize: 13 }}
          >
            Sign out
          </button>
        </form>
      </div>
      {children}
    </div>
  )
}
