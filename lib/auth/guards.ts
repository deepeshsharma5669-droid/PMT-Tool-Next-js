import { redirect } from 'next/navigation'
import { requirePmtUser } from './session'
import { roleHome } from './roles'
import type { PmtUser, Role } from './types'

/**
 * Route-level guards — for layouts/pages. On failure they redirect
 * (unauthenticated -> /login via requirePmtUser, wrong role -> the
 * visitor's own role home) rather than throwing, since these run during
 * page rendering.
 */

export async function requireRole(...roles: Role[]): Promise<PmtUser> {
  const pmtUser = await requirePmtUser()
  if (!roles.includes(pmtUser.role)) {
    redirect(roleHome(pmtUser.role))
  }
  return pmtUser
}

/** /admin — ADMIN only. */
export async function requireAdmin(): Promise<PmtUser> {
  return requireRole('ADMIN')
}

/** /manager — MANAGER or ADMIN (Admin has global access per the RLS model). */
export async function requireManager(): Promise<PmtUser> {
  return requireRole('ADMIN', 'MANAGER')
}

/** /member — any authenticated PMT user (a Manager/Admin may still want to see "my work"). */
export async function requireMember(): Promise<PmtUser> {
  return requireRole('ADMIN', 'MANAGER', 'MEMBER')
}

/**
 * Resource-level guards — for use inside future Server Actions (Phase 6),
 * not page rendering. These THROW instead of redirecting: a mutation that
 * fails an authorization check should return a clean error to the caller,
 * not navigate the browser away mid-request. Not wired into any UI yet —
 * built now per this phase's "Server Identity" requirement, consumed later.
 */

export class ForbiddenError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ForbiddenError'
  }
}

/** Admin, or a Manager whose own dept matches the resource's dept. */
export async function requireDepartment(dept: string): Promise<PmtUser> {
  const pmtUser = await requirePmtUser()
  if (pmtUser.role === 'ADMIN') return pmtUser
  if (pmtUser.role === 'MANAGER' && pmtUser.dept === dept) return pmtUser
  throw new ForbiddenError(
    `User ${pmtUser.id} (role=${pmtUser.role}, dept=${pmtUser.dept}) is not authorized for department "${dept}".`
  )
}

/** The task's assignee themself — never derived from a client-supplied assigneeId. */
export async function requireTaskAssignee(taskAssigneeId: string): Promise<PmtUser> {
  const pmtUser = await requirePmtUser()
  if (pmtUser.id !== taskAssigneeId) {
    throw new ForbiddenError(
      `User ${pmtUser.id} is not the assignee of this task (assignee=${taskAssigneeId}).`
    )
  }
  return pmtUser
}
