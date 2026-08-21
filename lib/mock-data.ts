export type Role = 'ADMIN' | 'MANAGER' | 'MEMBER'

export type PmtUser = {
  id: string
  name: string
  role: Role
  dept: string
  avatar: string
}

export type Client = { id: string; name: string; contact: string; status: string }
export type Campaign = { id: string; clientId: string; name: string; priority: string; deadline: string; status: string }
export type Deliverable = { id: string; campaignId: string; name: string; type: string; revision: number }
export type Stage = { id: string; deliverableId: string; name: string; dept: string; order: number; status: string }
export type Task = { id: string; stageId: string; title: string; assigneeId: string; deadline: string; status: string; revision: number }

export const users: PmtUser[] = [
  { id: 'u1', name: 'Admin User', role: 'ADMIN', dept: 'ALL', avatar: 'https://i.pravatar.cc/150?u=u1' },
  { id: 'u2', name: 'Sarah (Design Mgr)', role: 'MANAGER', dept: 'Design', avatar: 'https://i.pravatar.cc/150?u=u2' },
  { id: 'u3', name: 'John (Content Mgr)', role: 'MANAGER', dept: 'Content', avatar: 'https://i.pravatar.cc/150?u=u3' },
  { id: 'u4', name: 'Alex (Designer)', role: 'MEMBER', dept: 'Design', avatar: 'https://i.pravatar.cc/150?u=u4' },
  { id: 'u5', name: 'Chloe (Designer)', role: 'MEMBER', dept: 'Design', avatar: 'https://i.pravatar.cc/150?u=u5' },
  { id: 'u6', name: 'Deepesh (Writer)', role: 'MEMBER', dept: 'Content', avatar: 'https://i.pravatar.cc/150?u=u6' },
]

export const clients: Client[] = [
  { id: 'c1', name: 'ICICI Prudential', contact: 'Ramesh Patel', status: 'ACTIVE' },
]

export const campaigns: Campaign[] = [
  { id: 'camp1', clientId: 'c1', name: 'Q4 SIP Growth Campaign', priority: 'High', deadline: '2026-08-30', status: 'ACTIVE' },
]

export const deliverables: Deliverable[] = [
  { id: 'd1', campaignId: 'camp1', name: 'Key Visual', type: 'Static Poster', revision: 1 },
  { id: 'd2', campaignId: 'camp1', name: 'Instagram Carousel', type: 'Instagram Carousel', revision: 1 },
  { id: 'd3', campaignId: 'camp1', name: 'Q4 Reel', type: 'Instagram Reel', revision: 1 },
]

export const stages: Stage[] = [
  { id: 's1', deliverableId: 'd1', name: 'Content Strategy', dept: 'Content', order: 1, status: 'COMPLETED' },
  { id: 's2', deliverableId: 'd1', name: 'Visual Design', dept: 'Design', order: 2, status: 'ACTIVE' },
  { id: 's3', deliverableId: 'd2', name: 'Copywriting', dept: 'Content', order: 1, status: 'COMPLETED' },
  { id: 's4', deliverableId: 'd2', name: 'Layout Design', dept: 'Design', order: 2, status: 'ACTIVE' },
  { id: 's5', deliverableId: 'd3', name: 'Scripting', dept: 'Content', order: 1, status: 'ACTIVE' },
  { id: 's6', deliverableId: 'd3', name: 'Storyboarding', dept: 'Design', order: 2, status: 'PENDING' },
  { id: 's7', deliverableId: 'd3', name: 'Animation', dept: 'Animation', order: 3, status: 'PENDING' },
]

export const tasks: Task[] = [
  { id: 't1', stageId: 's2', title: 'Design Main Key Visual', assigneeId: 'u4', deadline: '2026-08-18', status: 'IN_PROGRESS', revision: 1 },
  { id: 't2', stageId: 's2', title: 'Typography Review', assigneeId: 'u5', deadline: '2026-08-17', status: 'IN_REVIEW', revision: 1 },
  { id: 't3', stageId: 's4', title: 'Carousel Slide 1-3', assigneeId: 'u5', deadline: '2026-08-19', status: 'CHANGES_REQUIRED', revision: 1 },
  { id: 't4', stageId: 's4', title: 'Carousel Slide 4-5', assigneeId: 'u4', deadline: '2026-08-19', status: 'APPROVED', revision: 1 },
]

export function getUser(id: string) {
  return users.find(u => u.id === id) ?? { id, name: 'Unassigned', role: 'MEMBER' as Role, dept: '', avatar: '' }
}
export function getStage(id: string) { return stages.find(s => s.id === id) }
export function getDeliverable(id: string) { return deliverables.find(d => d.id === id) }
export function getCampaign(id: string) { return campaigns.find(c => c.id === id) }
export function getClient(id: string) { return clients.find(c => c.id === id) }

export function getPipelineByDept() {
  const counts: Record<string, number> = {}
  stages.forEach(s => {
    if (s.status === 'ACTIVE' || s.status === 'CLIENT_DECISION') {
      counts[s.dept] = (counts[s.dept] || 0) + 1
    }
  })
  return counts
}

export function getManagerEfficiency(scopeDept?: string) {
  let managers = users.filter(u => u.role === 'MANAGER')
  if (scopeDept) managers = managers.filter(m => m.dept === scopeDept)

  return managers.map(m => {
    const deptStages = stages.filter(s => s.dept === m.dept)
    const deptTasks = tasks.filter(t => deptStages.some(s => s.id === t.stageId))
    const approved = deptTasks.filter(t => t.status === 'APPROVED').length
    const onTimePct = deptTasks.length ? Math.round((approved / deptTasks.length) * 100) : 0
    const teamSize = users.filter(u => u.dept === m.dept && u.role === 'MEMBER').length
    const open = deptTasks.filter(t => t.status !== 'APPROVED').length
    const load = teamSize ? Math.min(100, Math.round((open / (teamSize * 4)) * 100)) : 0
    return { manager: m, onTimePct, load, avgRework: deptTasks.filter(t => t.revision > 1).length }
  })
}

export function getTeamWorkload(dept: string) {
  return users.filter(u => u.dept === dept && u.role === 'MEMBER').map(u => {
    const t = tasks.filter(x => x.assigneeId === u.id)
    return { user: u, open: t.filter(x => x.status !== 'APPROVED').length, approved: t.filter(x => x.status === 'APPROVED').length }
  })
}

export function getMyStats(userId: string) {
  const t = tasks.filter(x => x.assigneeId === userId)
  const approved = t.filter(x => x.status === 'APPROVED').length
  return {
    total: t.length,
    approved,
    inReview: t.filter(x => x.status === 'IN_REVIEW').length,
    changesReq: t.filter(x => x.status === 'CHANGES_REQUIRED').length,
    onTimePct: t.length ? Math.round((approved / t.length) * 100) : 0,
  }
}
