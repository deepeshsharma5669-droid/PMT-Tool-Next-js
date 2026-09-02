'use client'
import {useState,useTransition} from 'react'
import {useRouter} from 'next/navigation'
import {teamAction} from '@/app/actions/team-workflow'
import type {HierarchyTask,HierarchyUser} from '@/lib/hierarchy/data'
import {localDateTime} from '@/components/shared/date-time'
import {toInstant,validInterval} from '@/lib/workflow/team'
export function TaskEditor({stageId,dept,users,task,requestId}:{stageId:string;dept:string;users:HierarchyUser[];task?:HierarchyTask;requestId?:string}){
 const router=useRouter(),[pending,start]=useTransition(),[message,setMessage]=useState('');
 const owners=users.filter(u=>u.status==='ACTIVE'&&u.dept===dept&&['MANAGER','MEMBER'].includes(u.role??'')),reviewers=owners.filter(u=>u.role==='MANAGER');
 function submit(fd:FormData){start(async()=>{try{const a=String(fd.get('start_at')),b=String(fd.get('end_at'));if(!validInterval(a,b))throw new Error('End cannot precede Start.');
 const args={p_title:String(fd.get('title')),p_description:String(fd.get('description')),p_assignee_id:String(fd.get('assignee')),p_reviewer_id:String(fd.get('reviewer')),p_start_at:toInstant(a),p_end_at:toInstant(b),p_priority:String(fd.get('priority'))};
 const r=await teamAction(task?'editTask':requestId?'createChangeTask':'createTask',{...args,...(task?{p_task_id:task.id}:requestId?{p_request_id:requestId}:{p_stage_id:stageId})});
 setMessage(r.success?'Saved.':r.error);if(r.success)router.refresh()}catch(e){setMessage(e instanceof Error?e.message:'Unable to save.')}})}
 return <form action={submit} className="task-action-panel"><h3>{task?'Task settings':requestId?'Create linked Change Task':'Create production Task'}</h3>{message&&<p role="status" className="action-feedback">{message}</p>}
 <label>Title *<input name="title" required defaultValue={task?.title}/></label><label>Description<textarea name="description" rows={3} defaultValue={task?.description}/></label>
 <label>Assignee *<select name="assignee" required defaultValue={task?.assignee_id??''}><option value="">Select assignee</option>{owners.map(u=><option key={u.id} value={u.id}>{u.name}</option>)}</select></label>
 <label>Reviewer *<select name="reviewer" required defaultValue={task?.reviewer_id??''}><option value="">Select Reviewer</option>{reviewers.map(u=><option key={u.id} value={u.id}>{u.name}</option>)}</select></label>
 <label>Start<input name="start_at" type="datetime-local" defaultValue={localDateTime(task?.start_at)}/></label><label>End *<input name="end_at" required type="datetime-local" defaultValue={localDateTime(task?.end_at)}/></label>
 <label>Priority<select name="priority" defaultValue={task?.priority??'Medium'}>{['Low','Medium','High'].map(p=><option key={p}>{p}</option>)}</select></label>
 <p>Task type: {requestId||task?.is_client_change?'Client Change':'Production'}. Client Changes must be linked to feedback.</p>
 <button className="button button--primary" disabled={pending}>{pending?'Saving…':'Save Task'}</button></form>
}

export function ReviewerRepair({task,dept,users}:{task:HierarchyTask;dept:string;users:HierarchyUser[]}){
 const router=useRouter(),[pending,start]=useTransition(),[message,setMessage]=useState('');
 const reviewers=users.filter(u=>u.status==='ACTIVE'&&u.dept===dept&&u.role==='MANAGER');
 const currentReviewer=users.find(u=>u.id===task.reviewer_id);
 if(currentReviewer?.status==='ACTIVE'&&currentReviewer.role==='MANAGER'&&currentReviewer.dept===dept)return null;
 function submit(fd:FormData){start(async()=>{const r=await teamAction('repairReviewer',{p_task_id:task.id,p_reviewer_id:String(fd.get('reviewer'))});setMessage(r.success?'Reviewer repaired.':r.error);if(r.success)router.refresh()})}
 return <form action={submit} className="task-action-panel"><h3>Reviewer repair</h3><p>Assigns only the Reviewer; historical assignee and Task timestamps remain unchanged.</p>{message&&<p role="status" className="action-feedback">{message}</p>}<label>Eligible Reviewer *<select name="reviewer" required defaultValue={task.reviewer_id??''}><option value="">Select Reviewer</option>{reviewers.map(u=><option key={u.id} value={u.id}>{u.name}</option>)}</select></label><button className="button" disabled={pending}>{pending?'Repairing…':'Repair Reviewer'}</button></form>
}
