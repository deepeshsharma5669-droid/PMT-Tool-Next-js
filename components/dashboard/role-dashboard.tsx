'use client'
import Link from 'next/link'
import type {PmtUser,Role} from '@/lib/auth/types'
import type {DashboardData} from '@/lib/dashboard/data'
import {PageHeader} from '@/components/ui/page-header'
import {SectionCard,StatTile} from '@/components/ui/surface'
import {StatusBadge} from '@/components/ui/badges'
import {PartialData} from '@/components/shared/states'
import {DateTime} from '@/components/shared/date-time'
import {ActivityTimeline} from '@/components/hierarchy/workflow'
import {isDecisionReadyRework,isOverdue,isProjectAtRisk} from '@/lib/workflow/team'
import {MY_REVIEWS_HREF,MY_TASKS_HREF} from '@/components/shell/navigation'

type Metric={label:string;value:number;href:string;tone:'default'|'purple'|'warning'|'danger'|'success';detail:string}
const priorityMetrics=new Set(['Active Projects','At risk','Client decision','Awaiting review','Awaiting my review','Active rework','Overdue tasks','Overdue deliverables'])

export function RoleDashboard({user,data:d}:{user:PmtUser&{role:Role};data:DashboardData}){
 const admin=user.role==='ADMIN',manager=user.role==='MANAGER'
 const stages=d.stages.filter(s=>admin||manager&&s.dept===user.dept||d.tasks.some(t=>t.stage_id===s.id&&t.assignee_id===user.id))
 const ds=d.deliverables.filter(x=>stages.some(s=>s.deliverable_id===x.id)),active=ds.filter(x=>!['DROPPED','COMPLETED'].includes(x.status))
 const tasks=d.tasks.filter(t=>stages.some(s=>s.id===t.stage_id)&&ds.some(x=>x.status!=='DROPPED'&&stages.some(s=>s.id===t.stage_id&&s.deliverable_id===x.id)))
 const open=tasks.filter(t=>t.status!=='APPROVED'),mine=open.filter(t=>t.assignee_id===user.id),reviews=tasks.filter(t=>t.status==='IN_REVIEW'&&t.reviewer_id===user.id)
 const reworks=d.reworks.filter(r=>['OPEN','IN_PROGRESS'].includes(r.status)&&stages.some(s=>s.id===r.target_stage_id))
 const decisionStages=stages.filter(s=>s.status==='CLIENT_DECISION'&&active.some(x=>x.id===s.deliverable_id))
 const readyReworks=new Set(d.reworks.filter(r=>isDecisionReadyRework(r,d.deliverables.find(x=>x.id===r.deliverable_id),decisionStages.find(s=>s.id===r.source_stage_id))).map(r=>`${r.deliverable_id}:${r.client_revision}:${r.source_stage_id}`))
 const scope=manager?'&dept='+encodeURIComponent(user.dept??''):!admin?'&assignee=me':''
 const primary:Metric[]=[],operational:Metric[]=[]
 const metric=(target:Metric[],label:string,value:number,href:string,tone:Metric['tone']='default',detail='Open workspace')=>target.push({label,value,href,tone,detail})
 if(admin){
  metric(primary,'Total Projects',d.campaigns.length,'/campaigns','purple','All client work')
  metric(primary,'Active Projects',d.campaigns.filter(c=>c.status==='ACTIVE').length,'/campaigns?status=ACTIVE','success','Currently in delivery')
  metric(primary,'Completed',d.campaigns.filter(c=>c.status==='COMPLETED').length,'/campaigns?status=COMPLETED','default','Closed Projects')
  metric(primary,'At risk',d.campaigns.filter(c=>isProjectAtRisk(c.id,d)).length,'/campaigns?risk=1','danger','Needs attention')
  metric(operational,'Active deliverables',active.length,'/work?kind=deliverables&status=ACTIVE','default','In production')
  metric(operational,'Overdue deliverables',active.filter(x=>isOverdue(x.end_at)).length,'/work?kind=deliverables&overdue=1','danger','Past schedule')
  metric(operational,'Client decision',decisionStages.length,'/work?kind=stages&status=CLIENT_DECISION','warning','Awaiting response')
  metric(operational,'Changes requested',active.filter(x=>x.status==='CHANGES_REQUESTED').length,'/work?kind=deliverables&status=CHANGES_REQUESTED','warning','Client feedback')
  metric(operational,'Open tasks',open.length,'/work?status=OPEN','default','Across the team')
  metric(operational,'Awaiting review',open.filter(t=>t.status==='IN_REVIEW').length,'/work?status=IN_REVIEW','purple','Reviewer action')
 }else{
  metric(primary,'My Tasks',mine.length,'/work?assignee=me&status=OPEN'+scope,'purple','Open assignments')
  metric(primary,'Due today',mine.filter(t=>t.end_at&&new Date(t.end_at).toDateString()===new Date().toDateString()).length,'/work?assignee=me&today=1&status=OPEN'+scope,'warning','Due before day end')
  if(manager){metric(primary,'Awaiting my review',reviews.length,'/work?reviewer=me&status=IN_REVIEW','purple','Assigned to you');metric(primary,'Client changes',active.filter(x=>x.status==='CHANGES_REQUESTED').length,'/work?kind=deliverables&status=CHANGES_REQUESTED'+scope,'warning','Department action')}
 }
 metric(operational,'Overdue tasks',(admin||manager?open:mine).filter(t=>isOverdue(t.end_at)).length,'/work?overdue=1&status=OPEN'+scope,'danger','Past due')
 if(admin||manager){metric(operational,'Active rework',reworks.length,'/work?kind=stages&rework=1'+scope,'warning','Revision work');metric(operational,'Ready for client',readyReworks.size,'/work?kind=stages&status=CLIENT_DECISION'+scope,'success','Decision ready')}
 const depts=[...new Set(stages.map(s=>s.dept))],maxDept=Math.max(1,...depts.map(dept=>stages.filter(s=>s.dept===dept&&s.status==='ACTIVE'&&active.some(x=>x.id===s.deliverable_id)).length))
 const actions=[
  ...decisionStages.map(s=>({key:'decision-'+s.id,href:'/stages/'+s.id,label:'Client decision required',title:d.deliverables.find(x=>x.id===s.deliverable_id)?.name??s.name,meta:`${s.name} · ${s.dept}`,status:'CLIENT_DECISION'})),
  ...reworks.map(r=>({key:'rework-'+r.id,href:'/deliverables/'+r.deliverable_id,label:'Active client rework',title:d.deliverables.find(x=>x.id===r.deliverable_id)?.name??'Deliverable',meta:`Revision ${r.client_revision} · ${r.department}`,status:'CLIENT_REWORK'})),
  ...open.filter(t=>isOverdue(t.end_at)).map(t=>({key:'task-'+t.id,href:'/tasks/'+t.id,label:'Overdue task',title:t.title,meta:d.users.find(u=>u.id===t.assignee_id)?.name??'Unassigned',status:'OVERDUE'}))
 ].slice(0,6)
 return <div className="page-container dashboard-page"><PageHeader title={`Welcome back, ${user.name.split(' ')[0]}`} eyebrow={admin?'Admin dashboard':manager?'Manager dashboard':'My workspace'} description={admin?'A live view of delivery health, client decisions, and team execution.':manager?'Your department, reviews, assignments, and client feedback in one place.':'Your assignments, deadlines, and feedback.'}/>
  {d.partial&&<PartialData/>}
  <div className="dashboard-primary-metrics">{primary.map(c=><Link className={priorityMetrics.has(c.label)?'metric-link metric-link--priority':'metric-link'} href={c.href} key={c.label}><StatTile label={c.label} value={c.value} detail={c.detail} tone={c.tone}/></Link>)}</div>
  {operational.length>0&&<div className="dashboard-operational-metrics">{operational.map(c=><Link className={priorityMetrics.has(c.label)?'metric-link metric-link--priority':'metric-link'} href={c.href} key={c.label}><StatTile label={c.label} value={c.value} detail={c.detail} tone={c.tone}/></Link>)}</div>}
  {(admin||manager)&&<div className="dashboard-layout dashboard-layout--lead">
   <SectionCard title="Actions required" description="Priority items that need an owner or decision" action={<Link className="text-link" href="/work">View all work →</Link>} className="dashboard-attention-card">
    {actions.length?<div className="attention-list">{actions.map(a=><Link href={a.href} key={a.key}><span className="attention-list__mark"/><div><small>{a.label}</small><strong>{a.title}</strong><span>{a.meta}</span></div><StatusBadge status={a.status}/><b>→</b></Link>)}</div>:<div className="dashboard-empty dashboard-empty--success"><span>✓</span><p>No urgent workflow actions right now.</p></div>}
   </SectionCard>
   <SectionCard title="Delivery distribution" description="Active deliverable stages by department">
    <div className="department-bars">{depts.map(dept=>{const count=stages.filter(s=>s.dept===dept&&s.status==='ACTIVE'&&active.some(x=>x.id===s.deliverable_id)).length;return <Link key={dept} href={'/work?kind=stages&status=ACTIVE&dept='+encodeURIComponent(dept)}><span><strong>{dept}</strong><small>{count} active</small></span><i><b style={{width:`${count/maxDept*100}%`}}/></i></Link>})}<Link href={'/work?kind=stages&status=CLIENT_DECISION'+scope}><span><strong>Client review</strong><small>{decisionStages.length} waiting</small></span><i><b className="is-warning" style={{width:`${decisionStages.length/maxDept*100}%`}}/></i></Link><Link href={'/work?kind=stages&rework=1'+scope}><span><strong>Rework</strong><small>{reworks.length} active</small></span><i><b className="is-danger" style={{width:`${reworks.length/maxDept*100}%`}}/></i></Link></div>
   </SectionCard>
  </div>}
  <div className="dashboard-layout">
   <SectionCard title="Awaiting my review" description="Tasks assigned to you as reviewer" action={<Link className="text-link" href={MY_REVIEWS_HREF}>Open reviews →</Link>} className="dashboard-work-list" ><div id="reviews">{reviews.length?reviews.slice(0,5).map(t=><Link key={t.id} href={'/tasks/'+t.id}><div><strong>{t.title}</strong><span>Reviewer: you · Due <DateTime value={t.end_at}/></span></div><StatusBadge status={t.status}/></Link>):<div className="dashboard-empty"><span>✓</span><p>No assigned reviews waiting.</p></div>}</div></SectionCard>
   <SectionCard title="My tasks" description="Your open production assignments" action={<Link className="text-link" href={MY_TASKS_HREF}>Open my work →</Link>} className="dashboard-work-list"><div id="my-tasks">{mine.length?mine.slice(0,5).map(t=><Link key={t.id} href={'/tasks/'+t.id}><div><strong>{t.title}</strong><span>{d.users.find(u=>u.id===t.reviewer_id)?.name?`Reviewer: ${d.users.find(u=>u.id===t.reviewer_id)?.name}`:'Reviewer assignment required'} · <DateTime value={t.end_at}/></span></div><StatusBadge status={t.status}/></Link>):<div className="dashboard-empty"><span>✓</span><p>No open assignments.</p></div>}</div></SectionCard>
  </div>
  {admin&&<SectionCard title="Recent activity" description="Latest durable workflow events across the workspace" action={<Link className="text-link" href="/activity">View audit log →</Link>} className="dashboard-activity"><ActivityTimeline items={d.activity.slice(0,8)}/></SectionCard>}
  {manager&&<SectionCard title="Regularization requests" description="Pending timing corrections from your team" className="dashboard-regularizations">{d.regularizations.filter(r=>r.status==='PENDING'&&r.user_id!==user.id&&tasks.some(t=>t.id===r.task_id)).map(r=><Link href={'/tasks/'+r.task_id} key={r.id}><strong>{tasks.find(t=>t.id===r.task_id)?.title}</strong><span>{r.reason}</span></Link>)}</SectionCard>}
 </div>
}
