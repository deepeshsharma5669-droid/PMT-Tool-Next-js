import { requireAdmin } from '@/lib/auth/guards'
import { createClient } from '@/lib/supabase/server'
import type { PmtUser } from '@/lib/auth/types'
import { assignRoleAndDept, activateUser, deactivateUser } from './actions'

const ROLES = ['ADMIN', 'MANAGER', 'MEMBER'] as const
const DEPTS = ['Content', 'Design', 'Animation', 'ALL'] as const

export default async function AdminUsersPage() {
  await requireAdmin()

  const supabase = await createClient()
  const { data } = await supabase
    .from('pmt_users')
    .select('id, name, email, role, dept, avatar, status')
    .order('name')

  const users = (data ?? []) as PmtUser[]
  const pending = users.filter((u) => u.status === 'PENDING')
  const rest = users.filter((u) => u.status !== 'PENDING')

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: 32, fontFamily: 'Inter, sans-serif' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700 }}>User Access</h1>
      <p style={{ color: '#64748b', fontSize: 13, marginBottom: 24 }}>
        Assign a role and department, then activate. Only ACTIVE users can sign in to PMT.
      </p>

      <section style={{ marginBottom: 32 }}>
        <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 12 }}>
          Pending registrations ({pending.length})
        </h2>
        {pending.length === 0 && <p style={{ color: '#94a3b8', fontSize: 13 }}>No pending registrations.</p>}
        {pending.map((u) => (
          <UserRow key={u.id} user={u} />
        ))}
      </section>

      <section>
        <h2 style={{ fontSize: 15, fontWeight: 700, marginBottom: 12 }}>All users ({rest.length})</h2>
        {rest.map((u) => (
          <UserRow key={u.id} user={u} />
        ))}
      </section>
    </div>
  )
}

function UserRow({ user }: { user: PmtUser }) {
  const statusColor =
    user.status === 'ACTIVE' ? '#059669' : user.status === 'PENDING' ? '#d97706' : '#94a3b8'

  return (
    <form
      action={assignRoleAndDept}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        flexWrap: 'wrap',
        background: '#fff',
        border: '1px solid #e2e8f0',
        borderRadius: 10,
        padding: '12px 16px',
        marginBottom: 8,
      }}
    >
      <input type="hidden" name="userId" value={user.id} />

      <div style={{ minWidth: 200 }}>
        <div style={{ fontSize: 13, fontWeight: 700 }}>{user.name}</div>
        <div style={{ fontSize: 12, color: '#64748b' }}>{user.email ?? '—'}</div>
      </div>

      <span style={{ fontSize: 11, fontWeight: 700, color: statusColor, textTransform: 'uppercase' }}>
        {user.status}
      </span>

      <select name="role" defaultValue={user.role ?? ''} style={selectStyle}>
        <option value="" disabled>
          Role…
        </option>
        {ROLES.map((r) => (
          <option key={r} value={r}>
            {r}
          </option>
        ))}
      </select>

      <select name="dept" defaultValue={user.dept ?? ''} style={selectStyle}>
        <option value="" disabled>
          Department…
        </option>
        {DEPTS.map((d) => (
          <option key={d} value={d}>
            {d}
          </option>
        ))}
      </select>

      <button type="submit" style={btnStyle}>
        Save role/dept
      </button>

      {user.status === 'ACTIVE' ? (
        <button type="submit" formAction={deactivateUser} style={{ ...btnStyle, background: '#fef2f2', color: '#b91c1c', border: '1px solid #fecaca' }}>
          Deactivate
        </button>
      ) : (
        <button type="submit" formAction={activateUser} style={{ ...btnStyle, background: '#f0fdf4', color: '#15803d', border: '1px solid #bbf7d0' }}>
          Activate
        </button>
      )}
    </form>
  )
}

const selectStyle: React.CSSProperties = {
  fontSize: 13,
  padding: '6px 8px',
  borderRadius: 6,
  border: '1px solid #cbd5e1',
}

const btnStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 700,
  padding: '7px 12px',
  borderRadius: 6,
  border: '1px solid #cbd5e1',
  background: '#f1f5f9',
  color: '#334155',
  cursor: 'pointer',
}
