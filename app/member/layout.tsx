import { requireMember } from '@/lib/auth/guards'

export default async function MemberLayout({ children }: { children: React.ReactNode }) {
  await requireMember()
  return <>{children}</>
}
