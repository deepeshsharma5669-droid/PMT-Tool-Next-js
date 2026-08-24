import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import {
  isActive,
  isAdmin,
  isManagerOfDept,
  canManageDept,
  isTaskOwner,
  canManageTaskManagement,
  canManagerReviewOwnTask,
} from '../permissions'
import type { Identity } from '../types'

function identity(overrides: Partial<Identity>): Identity {
  return { id: 'u1', role: 'MEMBER', dept: null, status: 'ACTIVE', ...overrides }
}

describe('permissions: Test 18/19 (unauthorized Member / wrong-department Manager)', () => {
  test('PENDING and INACTIVE users are never active, regardless of role', () => {
    assert.equal(isActive(identity({ role: 'ADMIN', status: 'PENDING' })), false)
    assert.equal(isActive(identity({ role: 'ADMIN', status: 'INACTIVE' })), false)
  })

  test('a Manager cannot manage a department that is not their own (Test 19)', () => {
    const mgr = identity({ role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(isManagerOfDept(mgr, 'Design'), true)
    assert.equal(isManagerOfDept(mgr, 'Content'), false)
    assert.equal(canManageDept(mgr, 'Content'), false)
  })

  test('Admin can manage every department', () => {
    const admin = identity({ role: 'ADMIN', dept: 'ALL', status: 'ACTIVE' })
    assert.equal(canManageDept(admin, 'Design'), true)
    assert.equal(canManageDept(admin, 'Content'), true)
  })

  test('a Member is only the owner of their own assigned task (Test 18)', () => {
    const member = identity({ id: 'u4', role: 'MEMBER', status: 'ACTIVE' })
    assert.equal(isTaskOwner(member, 'u4'), true)
    assert.equal(isTaskOwner(member, 'u5'), false) // cannot touch another Member's task
  })

  test('a PENDING Member owns nothing, even their own task id', () => {
    const pendingMember = identity({ id: 'u4', role: 'MEMBER', status: 'PENDING' })
    assert.equal(isTaskOwner(pendingMember, 'u4'), false)
  })
})

describe('canManageTaskManagement: Task Management Permission Model (Tests 1-6, 10, 19-24, 37-43)', () => {
  test('Admin is denied task management even though canManageDept() would grant it (Tests 1-6)', () => {
    const admin = identity({ role: 'ADMIN', dept: 'ALL', status: 'ACTIVE' })
    assert.equal(canManageDept(admin, 'Design'), true) // general stage governance still grants Admin
    assert.equal(canManageTaskManagement(admin, 'Design'), false) // normal task management does not
  })

  test('an ACTIVE Manager of the matching department may manage tasks (Test 10)', () => {
    const mgr = identity({ role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManageTaskManagement(mgr, 'Design'), true)
  })

  test('a wrong-department Manager is denied (Tests 19-24)', () => {
    const mgr = identity({ role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManageTaskManagement(mgr, 'Content'), false)
  })

  test('a PENDING Manager is denied', () => {
    const mgr = identity({ role: 'MANAGER', dept: 'Design', status: 'PENDING' })
    assert.equal(canManageTaskManagement(mgr, 'Design'), false)
  })

  test('an INACTIVE Manager is denied', () => {
    const mgr = identity({ role: 'MANAGER', dept: 'Design', status: 'INACTIVE' })
    assert.equal(canManageTaskManagement(mgr, 'Design'), false)
  })

  test('a Member is denied task management even for their own department (Tests 37-43)', () => {
    const member = identity({ role: 'MEMBER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManageTaskManagement(member, 'Design'), false)
  })
})

describe('canManagerReviewOwnTask: Manager Self-Review (Tests 17, 18, 31-36)', () => {
  test('reviewing a task assigned to someone else, IN_REVIEW, always returns true — normal review path applies (Tests 17-18)', () => {
    const mgr = identity({ id: 'mgr1', role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'member4', status: 'IN_REVIEW' }, true), true)
    assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'member4', status: 'IN_REVIEW' }, false), true)
  })

  test('self-assigned task: another ACTIVE same-department Manager exists -> self-review denied (Tests 31-33)', () => {
    const mgr = identity({ id: 'mgr1', role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'mgr1', status: 'IN_REVIEW' }, true), false)
  })

  test('self-assigned task: no other ACTIVE same-department Manager exists -> self-review allowed (Tests 34-36)', () => {
    const mgr = identity({ id: 'mgr1', role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'mgr1', status: 'IN_REVIEW' }, false), true)
  })
})

describe('canManagerReviewOwnTask: status gate — mirrors pmt_can_review_task()\'s IN_REVIEW requirement (Test E)', () => {
  test('a task that is not IN_REVIEW can never be reviewed, regardless of assignment or other-manager existence', () => {
    const mgr = identity({ id: 'mgr1', role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    for (const status of ['TODO', 'IN_PROGRESS', 'CHANGES_REQUIRED', 'APPROVED'] as const) {
      assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'member4', status }, true), false)
      assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'member4', status }, false), false)
      assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'mgr1', status }, false), false)
    }
  })

  test('once IN_REVIEW, the normal self-review rules resume', () => {
    const mgr = identity({ id: 'mgr1', role: 'MANAGER', dept: 'Design', status: 'ACTIVE' })
    assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'member4', status: 'IN_REVIEW' }, false), true)
    assert.equal(canManagerReviewOwnTask(mgr, { assigneeId: 'mgr1', status: 'IN_REVIEW' }, true), false)
  })
})
