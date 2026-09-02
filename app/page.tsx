import { redirect } from 'next/navigation'
import { requirePmtUser } from '@/lib/auth/session'

export default async function Home() {
  await requirePmtUser()
  redirect('/dashboard')
}
