import { requireManager } from '@/lib/auth/guards'

export default async function ManagerLayout({ children }: { children: React.ReactNode }) {
  await requireManager()
  return <>{children}</>
}
