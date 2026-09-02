'use client'
import{useMemo,useState}from'react'
import type{HierarchyActivity,HierarchyData}from'@/lib/hierarchy/data'
import{EmptyState}from'@/components/shared/states'
const humanize=(value:string)=>value.replace(/^CAMPAIGN_/,'PROJECT_').toLowerCase().replaceAll('_',' ').replace(/\b\w/g,x=>x.toUpperCase())
const entityLabel=(value:string)=>humanize(value==='CAMPAIGN'?'PROJECT':value.replace(/^CAMPAIGN_/,'PROJECT_'))
function contextFor(item:HierarchyActivity,data:HierarchyData){
 const id=item.entity_id,type=item.entity_type
 if(type==='CAMPAIGN'||type==='PROJECT')return data.campaigns.find(x=>x.id===id)?.name??'Project'
 if(type==='DELIVERABLE')return data.deliverables.find(x=>x.id===id)?.name??'Deliverable'
 if(type==='STAGE')return data.stages.find(x=>x.id===id)?.name??'Workflow stage'
 if(type==='TASK')return data.tasks.find(x=>x.id===id)?.title??'Task'
 if(type==='CLIENT')return data.campaigns.find(x=>x.client_id===id)?.clientName??'Client'
 if(type==='CLIENT_POC'||type==='CAMPAIGN_POC')return data.pocs.find(x=>x.id===id)?.name??'Client contact'
 if(type==='CAMPAIGN_DOCUMENT')return data.documents.find(x=>x.id===id)?.title??'Project document'
 if(type==='USER')return data.users.find(x=>x.id===id)?.name??'Team member'
 const rework=data.reworks.find(x=>x.id===id)
 if(type==='REWORK')return data.deliverables.find(x=>x.id===rework?.deliverable_id)?.name??'Client rework'
 const change=data.changeRequests.find(x=>x.id===id)
 if(type==='CHANGE_REQUEST')return data.stages.find(x=>x.id===change?.target_stage_id)?.name??'Client feedback'
 const regularization=data.regularizations.find(x=>x.id===id)
 if(type==='REGULARIZATION')return data.tasks.find(x=>x.id===regularization?.task_id)?.title??'Timing correction'
 return entityLabel(type)
}
export function ActivityExplorer({items,data}:{items:HierarchyActivity[];data:HierarchyData}){const[type,setType]=useState('ALL'),[q,setQ]=useState('');const enriched=useMemo(()=>items.map(item=>({item,context:contextFor(item,data)})),[items,data]),rows=useMemo(()=>enriched.filter(({item,context})=>(type==='ALL'||item.entity_type===type)&&(item.action+' '+item.actorName+' '+context).toLowerCase().includes(q.toLowerCase())),[enriched,type,q]);return <><div className="filter-bar activity-filters"><label className="filter-search"><span aria-hidden="true">⌕</span><input value={q} onChange={e=>setQ(e.target.value)} placeholder="Search activity" aria-label="Search activity"/></label><select value={type} onChange={e=>setType(e.target.value)} aria-label="Entity type"><option value="ALL">All activity</option>{['CAMPAIGN','DELIVERABLE','STAGE','TASK','CLIENT'].map(x=><option value={x} key={x}>{entityLabel(x)}{x==='CAMPAIGN'?'s':''}</option>)}</select><span className="filter-count">{rows.length} event{rows.length===1?'':'s'}</span></div>{rows.length?<div className="audit-table-wrap"><table className="audit-table"><thead><tr><th>Action</th><th>Entity</th><th>Actor</th><th>Context</th><th>Timestamp</th></tr></thead><tbody>{rows.map(({item:x,context})=><tr key={x.id}><td><span className="audit-action-mark"/><strong>{humanize(x.action)}</strong></td><td><span className="audit-entity">{entityLabel(x.entity_type)}</span></td><td>{x.actorName}</td><td><strong className="audit-context">{context}</strong></td><td><time dateTime={x.created_at}>{new Intl.DateTimeFormat('en-IN',{dateStyle:'medium',timeStyle:'short'}).format(new Date(x.created_at))}</time></td></tr>)}</tbody></table></div>:<EmptyState title="No activity matches your filters." description="Try a different search or entity type."/>}</>}
