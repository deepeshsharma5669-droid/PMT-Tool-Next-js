import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { isActive, isAdmin, isManagerOfDept, canManageDept, isTaskOwner } from '../permissions'
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
