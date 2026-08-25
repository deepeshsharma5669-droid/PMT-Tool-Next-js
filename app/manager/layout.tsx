import{requireManager}from'@/lib/auth/guards';import{AppShell}from'@/components/shell/app-shell'
export default async function ManagerLayout({children}:{children:React.ReactNode}){const user=await requireManager();return <AppShell user={user}>{children}</AppShell>}
