import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {canAssignedReview,canFinalizeRevision,canStartAssignedTask,feedbackGateReady,formalRevisionSource,isDecisionReadyRework,isFormalRevisionOpen,isOverdue,nextClientRevision,projectKind,restoredRevisionBoundary,toInstant,validInterval} from '../team'

test('Project classification is derived from Deliverable count',()=>{
 assert.equal(projectKind(1),'Project');assert.equal(projectKind(2),'Campaign')
})
test('Datetime validation compares instants, not date labels',()=>{
 assert.equal(validInterval('2026-08-27T10:00:00+05:30','2026-08-27T05:00:00Z'),true)
 assert.equal(validInterval('2026-08-27T10:00Z','2026-08-27T09:00Z'),false)
 assert.equal(toInstant('2026-08-27T10:00:00+05:30'),'2026-08-27T04:30:00.000Z')
 assert.throws(()=>toInstant('invalid'))
})
test('Overdue respects end time and closed work',()=>{
 const now=Date.parse('2026-08-27T10:00Z')
 assert.equal(isOverdue('2026-08-27T09:59Z',false,now),true)
 assert.equal(isOverdue('2026-08-27T10:01Z',false,now),false)
 assert.equal(isOverdue('2026-08-27T09:59Z',true,now),false)
})
test('Review requires the explicitly assigned active department Manager',()=>{
 const user={id:'one',role:'MANAGER',dept:'Design',status:'ACTIVE'}
 const task={reviewer_id:'one',status:'IN_REVIEW'}
 assert.equal(canAssignedReview(user,task,'Design'),true)
 assert.equal(canAssignedReview({...user,id:'two'},task,'Design'),false)
 assert.equal(canAssignedReview({...user,role:'ADMIN'},task,'Design'),false)
 assert.equal(canAssignedReview({...user,status:'INACTIVE'},task,'Design'),false)
 assert.equal(canAssignedReview(user,task,'Content'),false)
 assert.equal(canAssignedReview(user,{...task,reviewer_id:null},'Design'),false)
})
test('Additional feedback stays in the current formal revision',()=>{
 assert.equal(nextClientRevision(1,true),1);assert.equal(nextClientRevision(1,false),2)
})
test('Feedback without work blocks the feedback gate; all linked work must pass',()=>{
 assert.equal(feedbackGateReady([{status:'OPEN',tasks:[]}]),false)
 assert.equal(feedbackGateReady([{status:'IN_PROGRESS',tasks:[{status:'APPROVED'},{status:'IN_PROGRESS'}]}]),false)
 assert.equal(feedbackGateReady([{status:'ADDRESSED',tasks:[{status:'APPROVED'}]},{status:'OPEN',tasks:[]}]),false)
 assert.equal(feedbackGateReady([{status:'ADDRESSED',tasks:[{status:'APPROVED'}]}]),true)
})
const migrationUrls=[1,2,3,4,5,6].map(n=>new URL(`../../../supabase/migrations/${['','20260825000100_canonical_pmt_baseline.sql','20260825000200_canonical_workflow_rpc_and_rls.sql','20260825000300_client_management.sql','20260825000400_client_pocs_campaign_documents_workflow.sql','20260825000500_client_poc_creation_flow.sql','20260825000600_consolidated_team_workflow_updates.sql'][n]}`,import.meta.url))
const migrations=migrationUrls.map(url=>readFileSync(url,'utf8'))
const migration=migrations[5]
function effectiveFunction(name:string){let body='';const pattern=new RegExp(`create (?:or replace )?function public\\.${name}\\b[\\s\\S]*?\\$\\$;`,'gi');for(const sql of migrations)for(const match of sql.matchAll(pattern))body=match[0];assert.ok(body,`Missing effective ${name}`);return body}
test('006 is transactional, normalized and has no direct authenticated writes',()=>{
 assert.match(migration,/\bbegin;/i);assert.match(migration,/commit;\s*$/i)
 for(const table of ['pmt_change_requests','pmt_change_request_tasks','pmt_task_regularizations']){
  assert.match(migration,new RegExp('create table public\\.'+table+'\\('))
  assert.match(migration,new RegExp('alter table public\\.'+table+' enable row level security'))
 }
 assert.doesNotMatch(migration,/grant\s+(?:all|insert|update|delete)\s+on\s+table/i)
 assert.doesNotMatch(migration,/grant[^;]+to\s+(?:anon|public)\s*;/i)
})
test('Every 006 definer uses a fixed search path',()=>{
 const functions=migration.split(/create (?:or replace )?function /i).slice(1)
 for(const fn of functions)assert.match(fn.split('as $$')[0],/security definer\s+set search_path\s*=\s*public,\s*pg_temp/i)
})
test('Canonical review and gate safeguards remain present',()=>{
 assert.match(migration,/t\.reviewer_id=public\.pmt_current_pmt_id\(\)/)
 assert.match(migration,/iteration=iteration\+1/)
 assert.match(migration,/unique\(change_request_id,task_id\)/)
 assert.match(migration,/All feedback in this revision must be addressed/)
 assert.match(migration,/Feedback must never waive unfinished production/)
})
test('006 rejects future sources and preserves completed-unapproved revision identity',()=>{
 assert.match(migration,/pmt_is_valid_decision_source\(d\.id,s\.id,d\.client_revision\)/)
 assert.match(migration,/Feedback source must be a worked Stage/)
 assert.match(migration,/pmt_revision_is_open\(d\.id,d\.client_revision\)/)
 const open=effectiveFunction('pmt_revision_is_open')
 assert.match(open,/cd\.stage_id=public\.pmt_revision_source_stage\(p_deliverable_id,p_client_revision\)/)
})
test('006 cancellation and approval cannot waive unfinished work',()=>{
 assert.match(migration,/Feedback cannot be cancelled while linked executable work remains unfinished/)
 assert.match(migration,/Every affected rework Stage must finish before Client Approval/)
 assert.match(migration,/Unfinished work exists inside the proposed Client Approval boundary/)
})
test('effective start and submission ownership are NULL-safe',()=>{
 const start=effectiveFunction('pmt_start_task'),submit=effectiveFunction('pmt_submit_task_for_review')
 assert.match(start,/assignee_id is distinct from public\.pmt_current_pmt_id\(\)/)
 assert.doesNotMatch(start,/assignee_id <> public\.pmt_current_pmt_id\(\)/)
 assert.match(submit,/assignee_id is distinct from public\.pmt_current_pmt_id\(\)/)
 assert.doesNotMatch(submit,/assignee_id <> public\.pmt_current_pmt_id\(\)/)
})
test('task start behavior rejects wrong, NULL and inactive ownership even after Reviewer repair',()=>{
 const task={assignee_id:'member',status:'TODO'},member={id:'member',role:'MEMBER',status:'ACTIVE'}
 assert.equal(canStartAssignedTask(member,task),true)
 assert.equal(canStartAssignedTask({...member,id:'other'},task),false)
 assert.equal(canStartAssignedTask(member,{...task,assignee_id:null}),false)
 const repairedLegacyTask={...task,assignee_id:null,reviewer_id:'valid-manager'}
 assert.equal(canStartAssignedTask(member,repairedLegacyTask),false)
 assert.equal(canStartAssignedTask({...member,status:'INACTIVE'},task),false)
 assert.equal(canStartAssignedTask({...member,role:'ADMIN'},task),false)
})
test('006 provides explicit audited legacy Reviewer repair',()=>{
 const repair=effectiveFunction('pmt_repair_task_reviewer')
 assert.match(repair,/'legacy_repair',true/)
 assert.match(repair,/pmt_validate_reviewer\(t\.stage_id,p_reviewer_id\)/)
 assert.match(repair,/current Reviewer is still eligible/)
})
test('targeted rework converges on the original formal-revision source boundary',()=>{
 const source={id:'design',dept:'Design'},admin={role:'ADMIN',dept:null},designManager={role:'MANAGER',dept:'Design'},contentManager={role:'MANAGER',dept:'Content'}
 assert.equal(restoredRevisionBoundary(source.id,[{status:'COMPLETED'}]),source.id)
 assert.notEqual(restoredRevisionBoundary(source.id,[{status:'COMPLETED'}]),'content')
 assert.equal(canFinalizeRevision(admin,source,'design',[{status:'COMPLETED'}]),true)
 assert.equal(canFinalizeRevision(designManager,source,'design',[{status:'COMPLETED'}]),true)
 assert.equal(canFinalizeRevision(contentManager,source,'design',[{status:'COMPLETED'}]),false)
 assert.equal(restoredRevisionBoundary(source.id,[{status:'COMPLETED'},{status:'OPEN'}]),null)
 assert.equal(restoredRevisionBoundary(source.id,[{status:'COMPLETED'},{status:'COMPLETED'}]),source.id)
 assert.equal(nextClientRevision(1,true),1)
 assert.equal(nextClientRevision(1,false),2)
 const gate=effectiveFunction('pmt_apply_stage_gate'),approval=effectiveFunction('pmt_record_client_approval_with_poc')
 assert.match(gate,/pmt_revision_source_stage\(d\.id,d\.client_revision\)/)
 assert.match(gate,/All targeted rework is complete; the original Stage is ready/)
 assert.match(approval,/v_source is distinct from s\.id/)
})
test('historical target approval does not close the canonical source revision',()=>{
 const changes={id:'1',deliverable_id:'d',stage_id:'design',decision:'CHANGES_REQUESTED',client_revision:1,recorded_at:'2026-08-01T00:00:00Z'}
 const targetApproval={id:'2',deliverable_id:'d',stage_id:'content',decision:'APPROVED',client_revision:1,recorded_at:'2026-08-02T00:00:00Z'}
 const historical=[changes,targetApproval]
 assert.equal(formalRevisionSource(historical,'d',1),'design')
 assert.equal(isFormalRevisionOpen(historical,'d',1),true)
 assert.equal(nextClientRevision(1,isFormalRevisionOpen(historical,'d',1)),1)
 const finalApproval={id:'3',deliverable_id:'d',stage_id:'design',decision:'APPROVED',client_revision:1,recorded_at:'2026-08-03T00:00:00Z'}
 assert.equal(isFormalRevisionOpen([...historical,finalApproval],'d',1),false)
 assert.equal(nextClientRevision(1,isFormalRevisionOpen([...historical,finalApproval],'d',1)),2)
 const sameStage=[{...changes,stage_id:'design'},{...targetApproval,stage_id:'design'}]
 assert.equal(isFormalRevisionOpen(sameStage,'d',1),false)
})
test('Decision-ready counts follow the restored source boundary',()=>{
 const rework={status:'COMPLETED',client_revision:2},source={status:'CLIENT_DECISION'},completedTarget={status:'COMPLETED'}
 assert.equal(isDecisionReadyRework(rework,{status:'CLIENT_REVIEW',client_revision:2},source),true)
 assert.equal(isDecisionReadyRework(rework,{status:'CLIENT_REVIEW',client_revision:2},completedTarget),false)
 assert.equal(isDecisionReadyRework(rework,{status:'DROPPED',client_revision:2},source),false)
 assert.equal(isDecisionReadyRework(rework,{status:'COMPLETED',client_revision:2},source),false)
 assert.equal(isDecisionReadyRework(rework,{status:'CHANGES_REQUESTED',client_revision:3},source),false)
 assert.equal(isDecisionReadyRework(rework,{status:'CLIENT_REVIEW',client_revision:2},{status:'PENDING'}),false)
 assert.equal(isDecisionReadyRework(rework,{status:'CLIENT_REVIEW',client_revision:2},source),true)
})
