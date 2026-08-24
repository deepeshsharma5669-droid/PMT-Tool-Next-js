/**
 * Pure predicate mirrors of the RLS helper functions
 * (pmt_is_active/pmt_is_admin/pmt_is_manager_of/pmt_can_manage_stage in
 * supabase/migrations/0003_rls_security_hardening.sql). Server Actions use
 * these for early, clean-error rejection BEFORE hitting the database —
 * RLS remains the authoritative backstop regardless of what this returns.
 */
import type { Identity } from './types'

export function isActive(identity: Identity): boolean {
  return identity.status === 'ACTIVE'
}

export function isAdmin(identity: Identity): boolean {
  return isActive(identity) && identity.role === 'ADMIN'
}

export function isManagerOfDept(identity: Identity, dept: string): boolean {
  return isActive(identity) && identity.role === 'MANAGER' && identity.dept === dept
}

export function canManageDept(identity: Identity, dept: string): boolean {
  return isAdmin(identity) || isManagerOfDept(identity, dept)
}

export function isTaskOwner(identity: Identity, assigneeId: string): boolean {
  return isActive(identity) && identity.role === 'MEMBER' && identity.id === assigneeId
}
