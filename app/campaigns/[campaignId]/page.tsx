import Link from 'next/link'
import {notFound} from 'next/navigation'
import {requirePmtUser} from '@/lib/auth/session'
import {AppShell} from '@/components/shell/app-shell'
import {PageHeader} from '@/components/ui/page-header'
import {StatusBadge} from '@/components/ui/badges'
import {ActivityTimeline} from '@/components/hierarchy/workflow'
import {CampaignDetailActions,CampaignPocManager} from '@/components/campaigns/campaign-management'
import {CampaignDocuments} from '@/components/campaigns/campaign-documents'
import {Governance} from '@/components/shared/governance'
import {DateTime} from '@/components/shared/date-time'
import {EmptyState,PartialData,ProgressBar} from '@/components/shared/states'
import {projectKind} from '@/lib/workflow/team'
import {campaignProgress,deliverableProgress,loadHierarchy} from '@/lib/hierarchy/data'

export default async function Page({params}:{params:Promise<{campaignId:string}>}){
 const user=await requirePmtUser(),{campaignId}=await params,data=await loadHierarchy(),c=data.campaigns.find(x=>x.id===campaignId)
 if(!c)notFound()
 const ds=data.deliverables.filter(x=>x.campaign_id===c.id),links=data.campaignPocs.filter(x=>x.campaign_id===c.id),documents=data.documents.filter(x=>x.campaign_id===c.id),ids=new Set(ds.map(x=>x.id)),activity=data.activity.filter(x=>x.entity_id===c.id||ids.has(x.entity_id)),progress=campaignProgress(c.id,data)
 const canManage=user.role==='ADMIN'||user.role==='MANAGER'&&data.stages.some(s=>s.dept===user.dept&&ids.has(s.deliverable_id))
 return <AppShell user={user}><div className="page-container project-detail-page">
  <PageHeader eyebrow={c.clientName} title={c.name} description={`${projectKind(ds.length)} · ${c.priority??'Standard'} priority · ${ds.length} deliverable${ds.length===1?'':'s'}`} breadcrumbs={[{label:'PMT',href:'/dashboard'},{label:'Projects',href:'/campaigns'},{label:c.name}]} actions={<div className="project-header-actions"><StatusBadge status={c.status}/>{user.role==='ADMIN'&&<CampaignDetailActions campaign={c}/>}</div>}/>
  {data.partial&&<PartialData/>}
  <section className="project-summary-strip"><div className="project-progress-summary"><span>Overall progress</span><strong>{progress}%</strong><ProgressBar value={progress} label={false}/></div><div><span>Client</span><strong>{c.clientName}</strong><small>Account</small></div><div><span>Target date</span><strong><DateTime value={c.end_at}/></strong><small>Starts <DateTime value={c.start_at}/></small></div><div><span>Delivery scope</span><strong>{ds.length}</strong><small>{projectKind(ds.length)} workflow</small></div></section>
  <div className="project-detail-layout">
   <section className="hierarchy-primary project-deliverables"><div className="section-heading"><div><span className="eyebrow">Delivery workflow</span><h2>Deliverables</h2></div><span>{ds.filter(d=>d.status==='COMPLETED').length} of {ds.length} complete</span></div>
    {ds.length?<div className="deliverable-grid">{ds.map(d=>{const stages=data.stages.filter(s=>s.deliverable_id===d.id),current=stages.find(s=>s.status==='ACTIVE'||s.status==='CLIENT_DECISION'),done=stages.filter(s=>s.status==='COMPLETED').length;return <Link href={`/deliverables/${d.id}`} className="deliverable-card" key={d.id}><div className="deliverable-card__header"><span className="deliverable-card__index">{d.name.slice(0,1).toUpperCase()}</span><div><small>{d.type}</small><h3>{d.name}</h3></div><StatusBadge status={d.status}/></div><div className="deliverable-card__current"><small>Current stage</small><strong>{current?.name??(d.status==='COMPLETED'?'Complete':'Pending')}</strong><span>{current?.dept??'Workflow'}</span></div><ProgressBar value={deliverableProgress(d.id,data)}/><div className="stage-mini" aria-label={`${d.name} workflow`}>{stages.map(s=><i className={`stage-mini__step stage-mini__step--${s.status.toLowerCase()}`} title={`${s.name}: ${s.status}`} key={s.id}/>)}</div><div className="deliverable-card__secondary"><span><b>Revision {d.client_revision}</b>Client cycle</span><span><b>{done}/{stages.length}</b>Stages complete</span></div><footer><span><DateTime value={d.end_at}/></span><strong>Open deliverable →</strong></footer></Link>})}</div>:<EmptyState title="No deliverables in this Project."/>}
   </section>
   <aside className="project-detail-aside">
   <Governance entity="CAMPAIGN" id={c.id} startAt={c.start_at} endAt={c.end_at} state={c.operational_status} status={c.status} canManage={canManage}/>
   <CampaignPocManager campaignId={c.id} clientId={c.client_id} pocs={data.pocs} links={links} isAdmin={user.role==='ADMIN'}/>
   </aside>
   <CampaignDocuments campaignId={c.id} documents={documents} isAdmin={user.role==='ADMIN'}/>
   <section className="hierarchy-aside project-activity"><div className="section-heading"><div><span className="eyebrow">Audit trail</span><h2>Activity</h2></div><Link href="/activity">View all activity</Link></div><ActivityTimeline items={activity.slice(0,6)}/></section>
  </div>
 </div></AppShell>
}
