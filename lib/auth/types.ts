/**
 * Deliberately separate from lib/mock-data.ts. This is the shape of a real,
 * authenticated PMT user resolved from Supabase Auth + pmt_users — never
 * the hardcoded mock roster the /admin proof-of-concept still uses.
 */
export type Role = 'ADMIN' | 'MANAGER' | 'MEMBER'

export type Status = 'PENDING' | 'ACTIVE' | 'INACTIVE'

export type PmtUser = {
  id: string
  name: string
  email: string | null
  role: Role | null
  dept: string | null
  avatar: string | null
  status: Status
}
