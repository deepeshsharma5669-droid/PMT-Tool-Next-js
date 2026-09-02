export type Schedule = { start_at?: string | null; end_at?: string | null }
export function toInstant(value: string) { if (!value) return null; const d = new Date(value); if (!Number.isFinite(d.getTime())) throw new Error('Invalid date/time.'); return d.toISOString() }
export function validInterval(start?: string | null, end?: string | null) { return (!start||Number.isFinite(Date.parse(start)))&&(!end||Number.isFinite(Date.parse(end)))&&(!start||!end||Date.parse(end)>=Date.parse(start)) }
export function isOverdue(end?: string | null, closed = false, now = Date.now()) { return !!end && !closed && new Date(end).getTime() < now }
export function projectKind(count: number) { return count >= 2 ? 'Campaign' : 'Project' }
export function canAssignedReview(user: {id:string;role:string|null;dept:string|null;status:string}, task: {reviewer_id?:string|null;status:string}, dept:string) { return user.status==='ACTIVE' && user.role==='MANAGER' && user.dept===dept && user.id===task.reviewer_id && task.status==='IN_REVIEW' }
export function nextClientRevision(current:number, hasOpenFeedback:boolean) { return hasOpenFeedback ? current : current+1 }
export function feedbackGateReady(items: {status:string;tasks:{status:string}[]}[]) { return items.length>0 && items.every(r=>r.status==='CANCELLED'||(r.tasks.length>0&&r.tasks.every(t=>t.status==='APPROVED'))) }
export function canStartAssignedTask(user:{id:string;role:string|null;status:string},task:{assignee_id?:string|null;status:string}){
 return user.status==='ACTIVE'&&['MEMBER','MANAGER'].includes(user.role??'')&&task.assignee_id!=null&&task.assignee_id===user.id&&['TODO','CHANGES_REQUIRED'].includes(task.status)
}
export function restoredRevisionBoundary(sourceStageId:string,reworks:{status:string}[]){
 return reworks.length>0&&reworks.every(r=>['COMPLETED','CANCELLED'].includes(r.status))?sourceStageId:null
}
export function canFinalizeRevision(user:{role:string;dept:string|null},source:{id:string;dept:string},decisionStageId:string,reworks:{status:string}[]){
 return restoredRevisionBoundary(source.id,reworks)===decisionStageId&&(user.role==='ADMIN'||user.role==='MANAGER'&&user.dept===source.dept)
}
export function formalRevisionSource(decisions:{id:string;deliverable_id:string;stage_id:string;decision:string;client_revision:number;recorded_at:string}[],deliverableId:string,revision:number){
 return decisions.filter(d=>d.deliverable_id===deliverableId&&d.client_revision===revision&&d.decision==='CHANGES_REQUESTED').sort((a,b)=>a.recorded_at.localeCompare(b.recorded_at)||a.id.localeCompare(b.id))[0]?.stage_id??null
}
export function isFormalRevisionOpen(decisions:{id:string;deliverable_id:string;stage_id:string;decision:string;client_revision:number;recorded_at:string}[],deliverableId:string,revision:number){
 const source=formalRevisionSource(decisions,deliverableId,revision)
 return source!==null&&!decisions.some(d=>d.deliverable_id===deliverableId&&d.client_revision===revision&&d.stage_id===source&&d.decision==='APPROVED')
}
export function isDecisionReadyRework(rework:{status:string;client_revision:number},deliverable:{status:string;client_revision:number}|undefined,stage:{status:string}|undefined){
 return rework.status==='COMPLETED'&&!!deliverable&&!['DROPPED','COMPLETED'].includes(deliverable.status)&&deliverable.client_revision===rework.client_revision&&stage?.status==='CLIENT_DECISION'
}
export function isProjectAtRisk(id:string,data:import('../hierarchy/data').HierarchyData,now=Date.now()){
 const project=data.campaigns.find(c=>c.id===id);if(!project||project.status!=='ACTIVE')return false
 const deliverables=data.deliverables.filter(d=>d.campaign_id===id&&!['DROPPED','COMPLETED'].includes(d.status))
 const stages=data.stages.filter(s=>deliverables.some(d=>d.id===s.deliverable_id))
 return isOverdue(project.end_at,false,now)||deliverables.some(d=>isOverdue(d.end_at,false,now))||data.tasks.some(t=>stages.some(s=>s.id===t.stage_id)&&isOverdue(t.end_at,t.status==='APPROVED',now))
}
