import type { Role } from '@/lib/auth/types'
const tones: Record<string,string> = { ACTIVE:'success',COMPLETED:'success',APPROVED:'success',IN_PROGRESS:'info',IN_REVIEW:'purple',CLIENT_DECISION:'warning',CLIENT_REWORK:'warning',CHANGES_REQUIRED:'danger',OVERDUE:'danger',PENDING:'neutral',TODO:'neutral',INACTIVE:'neutral' }
const label=(v:string)=>v.toLowerCase().replaceAll('_',' ').replace(/\b\w/g,l=>l.toUpperCase())
export function StatusBadge({status}:{status:string}) { return <span className={`badge badge--${tones[status]??'neutral'}`}><span className="badge__dot" />{label(status)}</span> }
const roleTones:Record<Role,string>={ADMIN:'purple',MANAGER:'info',MEMBER:'success'}
export function RoleBadge({role}:{role:Role}) { return <span className={`badge badge--${roleTones[role]}`}>{label(role)}</span> }
