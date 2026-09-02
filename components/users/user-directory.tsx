'use client'

import {useMemo,useState,useTransition} from 'react'
import Link from 'next/link'
import type {PmtUser,Role} from '@/lib/auth/types'
import {RoleBadge,StatusBadge} from '@/components/ui/badges'
import {EmptyState} from '@/components/shared/states'
import {assignRoleAndDept,activateUser,deactivateUser} from '@/app/admin/users/actions'

const roles:Role[]=['ADMIN','MANAGER','MEMBER']
const depts=['Content','Design','Animation','ALL']
const initials=(name:string)=>name.split(/\s+/).map(x=>x[0]).join('').slice(0,2).toUpperCase()

function UserRow({user}:{user:PmtUser}){
 const[editing,setEditing]=useState(false),[selectedRole,setSelectedRole]=useState(user.role??''),[selectedDept,setSelectedDept]=useState(user.dept??''),[pending,start]=useTransition(),dirty=selectedRole!==(user.role??'')||selectedDept!==(user.dept??'')
 function save(){if(!selectedRole||!selectedDept||!dirty)return;const fd=new FormData();fd.set('userId',user.id);fd.set('role',selectedRole);fd.set('dept',selectedDept);start(async()=>{await assignRoleAndDept(fd);setEditing(false)})}
 function cancel(){setSelectedRole(user.role??'');setSelectedDept(user.dept??'');setEditing(false)}
 return <div className={`user-row ${editing?'is-editing':''}`}>
  <Link href={`/users/${user.id}`} className="user-cell"><span className="avatar">{initials(user.name)}</span><span><strong>{user.name}</strong><small>{user.email??'Email unavailable'}</small></span></Link>
  {editing?<select value={selectedRole} onChange={e=>setSelectedRole(e.target.value as Role|'')} aria-label={`Role for ${user.name}`}><option value="" disabled>Choose role</option>{roles.map(x=><option key={x}>{x}</option>)}</select>:<span className="user-value">{user.role?<RoleBadge role={user.role}/>:<span className="muted-cell">Unassigned</span>}</span>}
  {editing?<select value={selectedDept} onChange={e=>setSelectedDept(e.target.value)} aria-label={`Department for ${user.name}`}><option value="" disabled>Choose department</option>{depts.map(x=><option key={x}>{x}</option>)}</select>:<span className="user-value">{user.dept??'Unassigned'}</span>}
  <span data-label="Status"><StatusBadge status={user.status}/></span>
  <span className="user-actions">{editing?<><button type="button" className="button button--primary" disabled={!dirty||!selectedRole||!selectedDept||pending} onClick={save}>{pending?'Saving…':'Save'}</button><button type="button" className="button" disabled={pending} onClick={cancel}>Cancel</button></>:<><button type="button" className="button" onClick={()=>setEditing(true)}>Edit access</button><form action={user.status==='ACTIVE'?deactivateUser:activateUser}><input type="hidden" name="userId" value={user.id}/><button className={user.status==='ACTIVE'?'button button--danger':'button'}>{user.status==='PENDING'?'Approve':user.status==='INACTIVE'?'Activate':'Deactivate'}</button></form></>}</span>
 </div>
}

export function UserDirectory({users}:{users:PmtUser[]}){
 const[q,setQ]=useState(''),[role,setRole]=useState('ALL'),[dept,setDept]=useState('ALL'),[status,setStatus]=useState('ALL')
 const rows=useMemo(()=>users.filter(u=>(u.name+' '+(u.email??'')).toLowerCase().includes(q.toLowerCase())&&(role==='ALL'||u.role===role)&&(dept==='ALL'||u.dept===dept)&&(status==='ALL'||u.status===status)),[users,q,role,dept,status])
 return <><div className="filter-bar user-filters"><label className="filter-search"><span>⌕</span><input value={q} onChange={e=>setQ(e.target.value)} placeholder="Search name or email"/></label><select value={role} onChange={e=>setRole(e.target.value)} aria-label="Role filter"><option value="ALL">All roles</option>{roles.map(x=><option key={x}>{x}</option>)}</select><select value={dept} onChange={e=>setDept(e.target.value)} aria-label="Department filter"><option value="ALL">All departments</option>{depts.filter(x=>x!=='ALL').map(x=><option key={x}>{x}</option>)}</select><select value={status} onChange={e=>setStatus(e.target.value)} aria-label="Status filter"><option value="ALL">All statuses</option>{['PENDING','ACTIVE','INACTIVE'].map(x=><option key={x}>{x}</option>)}</select></div>{rows.length?<div className="user-table"><div className="user-table__head"><span>User</span><span>Role</span><span>Department</span><span>Status</span><span>Access</span></div>{rows.map(u=><UserRow user={u} key={u.id}/>)}</div>:<EmptyState title="No users found." description="Try changing your filters."/>}</>
}
