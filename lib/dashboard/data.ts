import{createClient}from'@/lib/supabase/server';import type{PmtUser,Role}from'@/lib/auth/types'
export type DashboardTask={id:string;title:string;status:string;deadline:string;assignee_id:string;stage_id:string;dept:string|null;is_client_change:boolean;client_revision:number|null}
export type DashboardStage={id:string;name:string;dept:string;status:string}
export type DashboardDeliverable={id:string;name:string;status:string;client_revision:number}
export type ActivityItem={id:string;action:string;entity_type:string;created_at:string;actorName:string}
export type DashboardData={campaigns:number;deliverables:DashboardDeliverable[];stages:DashboardStage[];tasks:DashboardTask[];activity:ActivityItem[];activeUsers:number;pendingUsers:number;error:string|null}
export async function loadDashboardData(user:PmtUser&{role:Role}):Promise<DashboardData>{
 const db=await createClient();const[campaigns,deliverables,stages,tasks,activity,users]=await Promise.all([
  db.from('pmt_campaigns').select('id,status'),db.from('pmt_deliverables').select('id,name,status,client_revision'),
  db.from('pmt_stages').select('id,name,dept,status'),db.from('pmt_tasks').select('id,title,status,deadline,assignee_id,stage_id,is_client_change,client_revision,pmt_stages(dept)'),
  db.from('pmt_activity').select('id,action,entity_type,created_at,pmt_users(name)').order('created_at',{ascending:false}).limit(8),
  db.from('pmt_users').select('id,status')]);
 const results=[campaigns,deliverables,stages,tasks,activity,users];const errors=results.flatMap(r=>r.error?[r.error.message]:[])
 const allStages=(stages.data??[]) as DashboardStage[]
 const allTasks=(tasks.data??[]).map(row=>{const r=row as unknown as {id:string;title:string;status:string;deadline:string;assignee_id:string;stage_id:string;is_client_change:boolean;client_revision:number|null;pmt_stages:{dept:string}|null};return{id:r.id,title:r.title,status:r.status,deadline:r.deadline,assignee_id:r.assignee_id,stage_id:r.stage_id,is_client_change:r.is_client_change,client_revision:r.client_revision,dept:r.pmt_stages?.dept??null}})
 const visibleTasks=user.role==='MANAGER'?allTasks.filter(t=>t.dept===user.dept):user.role==='MEMBER'?allTasks.filter(t=>t.assignee_id===user.id):allTasks
 const visibleStages=user.role==='MANAGER'?allStages.filter(s=>s.dept===user.dept):allStages
 const acts=(activity.data??[]).map(row=>{const r=row as unknown as{id:string;action:string;entity_type:string;created_at:string;pmt_users:{name:string}|null};return{id:r.id,action:r.action,entity_type:r.entity_type,created_at:r.created_at,actorName:r.pmt_users?.name??'PMT'}})
 const userRows=(users.data??[]) as{id:string;status:string}[]
 return{campaigns:(campaigns.data??[]).length,deliverables:(deliverables.data??[])as DashboardDeliverable[],stages:visibleStages,tasks:visibleTasks,activity:acts,activeUsers:userRows.filter(u=>u.status==='ACTIVE').length,pendingUsers:userRows.filter(u=>u.status==='PENDING').length,error:errors.length?'Some dashboard data could not be loaded.':null}
}
