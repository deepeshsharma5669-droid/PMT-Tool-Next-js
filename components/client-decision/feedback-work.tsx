'use client'
import {useState,useTransition} from 'react'
import {useRouter} from 'next/navigation'
import Link from 'next/link'
import type {HierarchyData,Stage} from '@/lib/hierarchy/data'
import type {PmtUser} from '@/lib/auth/types'
import {teamAction} from '@/app/actions/team-workflow'
import {TaskEditor} from '@/components/tasks/task-editor'
export function FeedbackWork({data,stage,user}:{data:HierarchyData;stage:Stage;user:PmtUser}){
 const deliverable=data.deliverables.find(d=>d.id===stage.deliverable_id),project=data.campaigns.find(c=>c.id===deliverable?.campaign_id);
 const router=useRouter(),[message,setMessage]=useState(''),[pending,start]=useTransition(),manager=user.role==='MANAGER'&&user.dept===stage.dept&&deliverable?.status!=='DROPPED'&&deliverable?.operational_status==='ACTIVE'&&project?.operational_status==='ACTIVE'&&project.status==='ACTIVE';
 const requests=data.changeRequests.filter(r=>r.target_stage_id===stage.id),tasks=data.tasks.filter(t=>t.stage_id===stage.id);
 function run(action:'linkFeedback'|'cancelFeedback',args:Record<string,unknown>){start(async()=>{const r=await teamAction(action,args);setMessage(r.success?'Feedback updated.':r.error);if(r.success)router.refresh()})}
 if(!requests.length)return <section className="hierarchy-primary client-feedback client-feedback--empty"><span className="client-feedback__icon">◇</span><div><span className="eyebrow">Client feedback</span><h2>No Client feedback for this Stage</h2><p>Change Requests will appear here when targeted feedback is recorded.</p></div></section>
 return <section className="hierarchy-primary client-feedback client-feedback--active"><div className="section-heading"><div><span className="eyebrow">Revision work</span><h2>Client feedback</h2></div><span>{requests.length} request{requests.length===1?'':'s'}</span></div><p>Individual requests within a revision. Feedback can exist before any Task is assigned.</p>{message&&<p role="status">{message}</p>}
 {requests.map(r=><article className="task-action-panel" key={r.id}><h3>Revision {r.client_revision} · {r.status}</h3><p>{r.feedback}</p>
 <ul>{data.changeLinks.filter(l=>l.change_request_id===r.id).map(l=><li key={l.id}><Link href={'/tasks/'+l.task_id}>{tasks.find(t=>t.id===l.task_id)?.title??'Task'}</Link></li>)}</ul>
 {manager&&!['RESOLVED','CANCELLED'].includes(r.status)&&<><form action={fd=>run('linkFeedback',{p_request_id:r.id,p_task_id:String(fd.get('task'))})}><label>Existing Task<select name="task" required><option value="">Choose relevant Task</option>{tasks.filter(t=>t.status!=='IN_REVIEW').map(t=><option key={t.id} value={t.id}>{t.title} · {t.status} · iteration {t.iteration}</option>)}</select></label><button className="button" disabled={pending}>Attach / reopen approved Task</button></form>
 <details><summary>Create New Change Task</summary><TaskEditor stageId={stage.id} dept={stage.dept} users={data.users} requestId={r.id}/></details>
 <button className="button" disabled={pending} onClick={()=>{const reason=window.prompt('Reason for cancelling this feedback item');if(reason)run('cancelFeedback',{p_id:r.id,p_reason:reason})}}>Cancel feedback</button></>}
 </article>)}</section>
}
