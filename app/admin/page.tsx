import {
  users, campaigns, getPipelineByDept, getManagerEfficiency, getTeamWorkload, getMyStats,
} from '@/lib/mock-data'

const DEPT_COLORS: Record<string, string> = {
  Content: '#4f46e5', Design: '#3b82f6', Animation: '#f59e0b', Review: '#10b981',
}

export default function AdminDashboard() {
  // Swap this for a real logged-in user lookup once auth is wired up.
  const currentUser = users[0]
  const isAdmin = currentUser.role === 'ADMIN'
  const isManager = currentUser.role === 'MANAGER'
  const isMember = currentUser.role === 'MEMBER'

  const activeCampaigns = campaigns.filter(c => c.status === 'ACTIVE').length
  const pipeline = getPipelineByDept()
  const pipelineTotal = Object.values(pipeline).reduce((a, b) => a + b, 0)

  return (
    <div style={{ maxWidth: 1100, margin: '0 auto', padding: 32, fontFamily: 'Inter, sans-serif' }}>
      <div style={{ marginBottom: 32 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>Welcome back, {currentUser.name.split(' ')[0]}</h1>
        <p style={{ color: '#64748b', fontSize: 14 }}>
          {isAdmin ? 'Organization overview' : isManager ? `${currentUser.dept} department` : 'Your work'}
        </p>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 32 }}>
        <StatCard label="Active Campaigns" value={activeCampaigns} />
        <StatCard label="Pipeline Items" value={pipelineTotal} />
      </div>

      <section style={{ background: '#fff', border: '1px solid #e2e8f0', borderRadius: 12, padding: 20, marginBottom: 32 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 16 }}>Pipeline Overview</h2>
        <div style={{ display: 'flex', height: 40, borderRadius: 8, overflow: 'hidden' }}>
          {Object.entries(pipeline).map(([dept, count]) => (
            <div
              key={dept}
              style={{
                flex: count, background: DEPT_COLORS[dept] ?? '#94a3b8',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 12, fontWeight: 700,
              }}
            >
              {dept} · {count}
            </div>
          ))}
        </div>
      </section>

      {isAdmin && <ManagerEfficiencyTable rows={getManagerEfficiency()} />}
      {isManager && <ManagerPanel dept={currentUser.dept} />}
      {isMember && <MemberPanel userId={currentUser.id} />}
    </div>
  )
}

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <div style={{ background: '#fff', border: '1px solid #e2e8f0', borderRadius: 12, padding: 16 }}>
      <div style={{ fontSize: 13, color: '#64748b', fontWeight: 600 }}>{label}</div>
      <div style={{ fontSize: 28, fontWeight: 700, marginTop: 4 }}>{value}</div>
    </div>
  )
}

function ManagerEfficiencyTable({ rows }: { rows: ReturnType<typeof getManagerEfficiency> }) {
  return (
    <section style={{ background: '#fff', border: '1px solid #e2e8f0', borderRadius: 12, overflow: 'hidden' }}>
      <div style={{ padding: '16px 20px', borderBottom: '1px solid #e2e8f0', fontWeight: 700 }}>Manager Efficiency</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
        <thead>
          <tr style={{ background: '#f8fafc', color: '#64748b', textAlign: 'left' }}>
            <th style={th}>Manager</th><th style={th}>On-Time %</th><th style={th}>Avg Rework</th><th style={th}>Load</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.manager.id} style={{ borderTop: '1px solid #f1f5f9' }}>
              <td style={td}>{r.manager.name}</td>
              <td style={{ ...td, color: r.onTimePct < 75 ? '#dc2626' : '#059669', fontWeight: 700 }}>{r.onTimePct}%</td>
              <td style={td}>{r.avgRework}</td>
              <td style={td}>{r.load}%</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function ManagerPanel({ dept }: { dept: string }) {
  const team = getTeamWorkload(dept)
  return (
    <section style={{ background: '#fff', border: '1px solid #e2e8f0', borderRadius: 12, overflow: 'hidden' }}>
      <div style={{ padding: '16px 20px', borderBottom: '1px solid #e2e8f0', fontWeight: 700 }}>{dept} Team Workload</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
        <thead>
          <tr style={{ background: '#f8fafc', color: '#64748b', textAlign: 'left' }}>
            <th style={th}>Member</th><th style={th}>Open</th><th style={th}>Approved</th>
          </tr>
        </thead>
        <tbody>
          {team.map(r => (
            <tr key={r.user.id} style={{ borderTop: '1px solid #f1f5f9' }}>
              <td style={td}>{r.user.name}</td>
              <td style={{ ...td, color: r.open > 3 ? '#dc2626' : undefined, fontWeight: 700 }}>{r.open}</td>
              <td style={{ ...td, color: '#059669', fontWeight: 700 }}>{r.approved}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function MemberPanel({ userId }: { userId: string }) {
  const stats = getMyStats(userId)
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16 }}>
      <StatCard label="My Tasks" value={stats.total} />
      <StatCard label="Approved" value={stats.approved} />
      <StatCard label="In Review" value={stats.inReview} />
      <StatCard label="Changes Requested" value={stats.changesReq} />
    </div>
  )
}

const th: React.CSSProperties = { padding: '10px 20px', fontSize: 11, textTransform: 'uppercase', letterSpacing: 0.5 }
const td: React.CSSProperties = { padding: '12px 20px' }
