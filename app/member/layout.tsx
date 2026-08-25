import{requireMember}from'@/lib/auth/guards';import{AppShell}from'@/components/shell/app-shell'
export default async function MemberLayout({children}:{children:React.ReactNode}){const user=await requireMember();return <AppShell user={user}>{children}</AppShell>}
