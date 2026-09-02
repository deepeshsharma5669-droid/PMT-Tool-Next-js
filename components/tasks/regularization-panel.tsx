'use client'
import {useState,useTransition} from 'react'
import {useRouter} from 'next/navigation'
import {teamAction} from '@/app/actions/team-workflow'
import type {HierarchyTask,Regularization} from '@/lib/hierarchy/data'
import type {PmtUser} from '@/lib/auth/types'
import {toInstant} from '@/lib/workflow/team'
import {DateTime} from '@/components/shared/date-time'
export function RegularizationPanel({task,user,dept,items}:{task:HierarchyTask;user:PmtUser;dept:string;items:Regularization[]}){
 const router=useRouter(),[message,setMessage]=useState(''),[pending,start]=useTransition();
 function run(action:'requestRegularization'|'reviewRegularization',args:Record<string,unknown>){start(async()=>{const r=await teamAction(action,args);setMessage(r.success?'Regularization saved.':r.error);if(r.success)router.refresh()})}
 return <section className="task-overview"><h2>Task regularization</h2><p>Auditable actual-time corrections. Original Task timestamps are never overwritten.</p>{message&&<p role="status">{message}</p>}
 {user.id===task.assignee_id&&!items.some(r=>r.status==='PENDING')&&<form action={fd=>run('requestRegularization',{p_task_id:task.id,p_actual_start_at:toInstant(String(fd.get('start'))),p_actual_end_at:toInstant(String(fd.get('end'))),p_reason:String(fd.get('reason'))})}><label>Actual start<input required name="start" type="datetime-local"/></label><label>Actual end<input required name="end" type="datetime-local"/></label><label>Reason<textarea required name="reason"/></label><button className="button" disabled={pending}>Request correction</button></form>}
 {items.map(r=><article key={r.id}><h3>{r.status}</h3><DateTime value={r.actual_start_at}/> → <DateTime value={r.actual_end_at}/><p>{r.reason}</p><p>{r.manager_comment}</p>
 {r.status==='PENDING'&&user.role==='MANAGER'&&user.dept===dept&&r.user_id!==user.id&&<form action={fd=>run('reviewRegularization',{p_id:r.id,p_approve:fd.get('decision')==='APPROVED',p_comment:String(fd.get('comment'))})}><label>Manager comment<textarea required name="comment"/></label><select name="decision"><option>APPROVED</option><option>REJECTED</option></select><button className="button" disabled={pending}>Review correction</button></form>}</article>)}
 </section>
}
