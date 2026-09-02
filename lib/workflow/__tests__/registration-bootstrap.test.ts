import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolveDestination } from '../../auth/roles'
import type { PmtUser } from '../../auth/types'

const read = (path: string) => readFileSync(new URL(path, import.meta.url), 'utf8')
const baseline = read('../../../supabase/migrations/20260825000100_canonical_pmt_baseline.sql')
const workflow = read('../../../supabase/migrations/20260825000200_canonical_workflow_rpc_and_rls.sql')
const migration = read('../../../supabase/migrations/20260825000700_auth_profile_bootstrap.sql')
const session = read('../../auth/session.ts')
const usersData = read('../../support/data.ts')
const adminActions = read('../../../app/admin/users/actions.ts')

function functionBody(name: string) {
  const match = migration.match(new RegExp(`create function public\\.${name}\\b[\\s\\S]*?\\$\\$;`, 'i'))
  assert.ok(match, `Missing ${name}`)
  return match[0]
}

test('Auth signup transaction creates exactly one unassigned PENDING PMT profile', () => {
  assert.match(migration, /after insert on auth\.users[\s\S]*pmt_handle_new_auth_user\(\)/i)
  const bootstrap = functionBody('pmt_bootstrap_auth_profile')
  assert.match(bootstrap, /insert into public\.pmt_users[\s\S]*role, dept, status[\s\S]*null, null, 'PENDING'/i)
  assert.match(baseline, /auth_user_id uuid unique references auth\.users/i)
  assert.match(baseline, /create unique index pmt_users_email_key on public\.pmt_users \(lower\(email\)\)/i)
})

test('bootstrap is serialized, idempotent, and never reassigns another Auth profile', () => {
  const bootstrap = functionBody('pmt_bootstrap_auth_profile')
  assert.match(bootstrap, /pg_advisory_xact_lock\(hashtextextended\(v_email, 0\)\)/i)
  assert.match(bootstrap, /where auth_user_id = p_auth_user_id[\s\S]*return v_profile_id/i)
  assert.match(bootstrap, /auth_user_id is not null[\s\S]*auth_user_id <> p_auth_user_id[\s\S]*already linked/i)
  assert.match(bootstrap, /auth_user_id is null[\s\S]*status = 'PENDING'[\s\S]*role is null[\s\S]*dept is null[\s\S]*approved_at is null[\s\S]*approved_by is null/i)
})

test('self-registration cannot claim an unlinked ACTIVE, privileged, or previously approved profile', () => {
  const bootstrap = functionBody('pmt_bootstrap_auth_profile')
  assert.match(bootstrap, /auth_user_id is null[\s\S]*status is distinct from 'PENDING'[\s\S]*role is not null[\s\S]*dept is not null[\s\S]*approved_at is not null[\s\S]*approved_by is not null[\s\S]*requires Admin reconciliation/i)
  assert.match(migration, /from auth\.users u[\s\S]*p\.auth_user_id is null[\s\S]*p\.status is distinct from 'PENDING'[\s\S]*p\.role is not null[\s\S]*p\.dept is not null[\s\S]*p\.approved_at is not null[\s\S]*p\.approved_by is not null/i)
})

test('repair RPC only bootstraps auth.uid and internal helpers are not callable', () => {
  const ensure = functionBody('pmt_ensure_current_user_profile')
  assert.match(ensure, /auth\.uid\(\) is null/i)
  assert.match(ensure, /pmt_bootstrap_auth_profile\(auth\.uid\(\)\)/i)
  assert.match(migration, /revoke all on function public\.pmt_bootstrap_auth_profile\(uuid\) from public, anon, authenticated/i)
  assert.match(migration, /grant execute on function public\.pmt_ensure_current_user_profile\(\) to authenticated/i)
  assert.match(migration, /from auth\.users u[\s\S]*p\.auth_user_id = u\.id[\s\S]*pmt_bootstrap_auth_profile\(v_auth_user\.id\)/i)
  assert.match(migration, /raw_user_meta_data->>'name'[\s\S]*v_email/i)
})

test('PENDING users cannot reach ACTIVE-only routes and missing profiles are not PENDING', () => {
  const pending: PmtUser = { id: 'pending', name: 'Pending', email: 'pending@example.com', role: null, dept: null, avatar: null, status: 'PENDING' }
  assert.equal(resolveDestination(pending), '/pending-access')
  assert.match(session, /if \(!pmtUser\) \{[\s\S]*redirect\('\/no-access'\)/i)
  assert.match(session, /pmtUser\.status !== 'ACTIVE' \|\| !pmtUser\.role/i)
})

test('Admin directory includes pending profiles and approval makes them ACTIVE', () => {
  assert.match(usersData, /from\('pmt_users'\)[\s\S]*select\('id,name,email,role,dept,avatar,status'\)[\s\S]*order\('name'\)/i)
  assert.doesNotMatch(usersData, /\.eq\('status',\s*'ACTIVE'\)/i)
  assert.match(workflow, /create function public\.pmt_approve_pending_user[\s\S]*not public\.pmt_is_admin\(\)[\s\S]*status = 'ACTIVE'[\s\S]*where id = p_user_id and status = 'PENDING'/i)
  assert.match(adminActions, /target\.status === 'PENDING'[\s\S]*pmt_approve_pending_user/i)
  assert.doesNotMatch(adminActions, /revalidatePath\('\/admin\/users'\)/i)
  assert.equal(adminActions.match(/revalidatePath\('\/users'\)/g)?.length, 3)
})

test('Migration 007 is transactional and does not alter RLS or assign access defaults', () => {
  assert.match(migration, /^begin;/m)
  assert.match(migration, /commit;\s*$/)
  assert.doesNotMatch(migration, /create policy|alter policy|drop policy|disable row level security/i)
  assert.doesNotMatch(migration, /'ADMIN'|'MANAGER'|'MEMBER'/)
})
