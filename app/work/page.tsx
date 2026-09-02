import {requirePmtUser} from '@/lib/auth/session'
import {loadHierarchy} from '@/lib/hierarchy/data'
import {AppShell} from '@/components/shell/app-shell'
import {WorkExplorer} from '@/components/work/work-explorer'
import {PartialData} from '@/components/shared/states'
import {PageHeader} from '@/components/ui/page-header'
export default async function Page(){const user=await requirePmtUser(),data=await loadHierarchy();return <AppShell user={user}><div className="page-container"><PageHeader eyebrow="Operations" title="Work" description="Tasks, Stages, and Deliverables across the PMT workflow." breadcrumbs={[{label:'PMT',href:'/dashboard'},{label:'Work'}]}/>{data.partial&&<PartialData/>}<WorkExplorer data={data} user={user}/></div></AppShell>}
