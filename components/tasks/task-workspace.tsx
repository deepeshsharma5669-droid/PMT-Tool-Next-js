'use client'
import Link from 'next/link'
import {useState,useTransition} from 'react'
import {useRouter} from 'next/navigation'
import type {PmtUser} from '@/lib/auth/types'
import type {HierarchyTask,HierarchyUser} from '@/lib/hierarchy/data'
import {reorderTasks} from '@/app/actions/tasks'
import {TaskEditor} from './task-editor'
import {CommonFilters,useCommonFilters} from '@/components/shared/common-filters'
import {DateTime} from '@/components/shared/date-time'
import {StatusBadge} from '@/components/ui/badges'
import {EmptyState} from '@/components/shared/states'
import {isOverdue} from '@/lib/workflow/team'
export function TaskWorkspace({stageId,dept,user,tasks,users,blocked=false}:{stageId:string;dept:string;user:PmtUser;tasks:HierarchyTask[];users:HierarchyUser[];currentRevision:number;reworkActive:boolean;blocked?:boolean}){
 const f=useCommonFilters(),router=useRouter(),[message,setMessage]=useState(''),[pending,start]=useTransition(),manager=user.role==='MANAGER'&&user.dept===dept&&!blocked
 const rows=tasks.filter(t=>(!f.get('q')||t.title.toLowerCase().includes(f.get('q').toLowerCase()))&&(!f.get('status')||t.status===f.get('status'))&&(!f.get('assignee')||t.assignee_id===f.get('assignee'))&&(!f.get('reviewer')||t.reviewer_id===f.get('reviewer'))&&(!f.get('taskType')||t.task_type===f.get('taskType'))&&(!f.get('overdue')||isOverdue(t.end_at,t.status==='APPROVED'))).sort((a,b)=>a.task_order-b.task_order)
 function move(t:HierarchyTask,dir:number){const all=tasks.filter(x=>['TODO','IN_PROGRESS'].includes(x.status)).sort((a,b)=>a.task_order-b.task_order),target=all[all.findIndex(x=>x.id===t.id)+dir];if(target)start(async()=>{const r=await reorderTasks(stageId,t.id,target.id);setMessage(r.success?'Order updated.':r.error);if(r.success)router.refresh()})}
 const people=users.filter(u=>u.dept===dept).map(u=>({value:u.id,label:u.name}))
 return <section className="task-workspace"><div className="task-workspace__heading"><div><span className="eyebrow">Department workspace</span><h2>Tasks</h2><p>{rows.length} visible · {tasks.filter(t=>t.status==='IN_REVIEW').length} awaiting review</p></div>{manager&&<details><summary className="button button--primary">+ Add production Task</summary><div className="task-create-panel"><TaskEditor stageId={stageId} dept={dept} users={users}/></div></details>}</div>{message&&<p className="action-feedback" role="status">{message}</p>}{blocked&&<p className="readonly-notice">Workflow is paused or this Deliverable is dropped. History remains available.</p>}
 <CommonFilters results={rows.length} fields={[{key:'q',label:'Search Tasks'},{key:'status',label:'Status',options:['TODO','IN_PROGRESS','IN_REVIEW','CHANGES_REQUIRED','APPROVED'].map(value=>({value,label:value}))},{key:'assignee',label:'Assignee',options:people},{key:'reviewer',label:'Reviewer',options:people},{key:'taskType',label:'Task type',options:['PRODUCTION','CLIENT_CHANGE'].map(value=>({value,label:value}))},{key:'overdue',label:'Schedule',options:[{value:'1',label:'Overdue'}]}]}/>
 {rows.length?<div className="task-table-shell"><div className="task-table__head"><span>Task</span><span>Assignee</span><span>Reviewer</span><span>Status</span><span>Schedule</span><span>Order</span></div>{rows.map(t=><article className="task-row" key={t.id}><div className="task-row__title"><Link href={'/tasks/'+t.id}>{t.title}</Link><small>{t.task_type==='CLIENT_CHANGE'?`Client change · Revision ${t.client_revision} · Iteration ${t.iteration??1}`:`Production · ${t.priority} priority · Iteration ${t.iteration??1}`}</small></div><span>{users.find(u=>u.id===t.assignee_id)?.name??'Unassigned'}</span><span>{users.find(u=>u.id===t.reviewer_id)?.name??'Required'}</span><StatusBadge status={t.status}/><span className={isOverdue(t.end_at,t.status==='APPROVED')?'is-overdue':''}><DateTime value={t.end_at}/></span><div className="task-row__actions"><Link href={'/tasks/'+t.id}>Open</Link>{manager&&['TODO','IN_PROGRESS'].includes(t.status)&&<><button disabled={pending} onClick={()=>move(t,-1)} aria-label="Move task up">↑</button><button disabled={pending} onClick={()=>move(t,1)} aria-label="Move task down">↓</button></>}</div></article>)}</div>:<EmptyState title="No tasks match these filters." description="Clear or change filters to see more Stage work."/>}
 </section>
}
