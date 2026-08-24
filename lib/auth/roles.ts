import type { PmtUser, Role } from './types'

/** Where an ACTIVE role lands after login. */
export function roleHome(role: Role): string {
  switch (role) {
    case 'ADMIN':
      return '/admin'
    case 'MANAGER':
      return '/manager'
    case 'MEMBER':
      return '/member'
  }
}

/**
 * Single source of truth for "where does this authenticated PMT user
 * belong right now" — used by both the login Server Action and
 * requirePmtUser(), so the status/role -> destination mapping only exists
 * in one place.
 *
 * PENDING  -> /pending-access
 * INACTIVE -> /no-access
 * ACTIVE with no role assigned yet (shouldn't happen — activation requires
 *   a role — but treated as still-pending defensively) -> /pending-access
 * ACTIVE with a role -> that role's home
 */
export function resolveDestination(pmtUser: PmtUser): string {
  if (pmtUser.status === 'PENDING') return '/pending-access'
  if (pmtUser.status === 'INACTIVE') return '/no-access'
  if (!pmtUser.role) return '/pending-access'
  return roleHome(pmtUser.role)
}
