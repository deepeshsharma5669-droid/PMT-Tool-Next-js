import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import {
  isValidMemberTransition,
  isValidManagerReviewTransition,
  reorderableTasks,
  recalculateTaskOrder,
  nextTaskOrder,
  nextChangeTaskOrder,
} from '../tasks'
import type { WorkflowTask } from '../types'

function task(overrides: Partial<WorkflowTask>): WorkflowTask {
  return { id: 't1', stageId: 's1', status: 'TODO', isClientChange: false, clientRevision: null, order: 1, assigneeId: 'u1', ...overrides }
}

describe('tasks: Member transitions — Test C (Member Start Work / Submit Review)', () => {
  test('TODO -> IN_PROGRESS is allowed (Start Task)', () => {
    assert.equal(isValidMemberTransition('TODO', 'IN_PROGRESS', false), true)
  })

  test('CHANGES_REQUIRED -> IN_PROGRESS is allowed (resume after rework request)', () => {
    assert.equal(isValidMemberTransition('CHANGES_REQUIRED', 'IN_PROGRESS', false), true)
  })

  test('IN_PROGRESS -> IN_REVIEW requires a real submission to exist', () => {
    assert.equal(isValidMemberTransition('IN_PROGRESS', 'IN_REVIEW', false), false)
    assert.equal(isValidMemberTransition('IN_PROGRESS', 'IN_REVIEW', true), true)
  })

  test('TODO -> IN_REVIEW is never allowed, even with a submission present', () => {
    assert.equal(isValidMemberTransition('TODO', 'IN_REVIEW', true), false)
  })

  test('Member may never set APPROVED', () => {
    assert.equal(isValidMemberTransition('IN_REVIEW', 'APPROVED', true), false)
    assert.equal(isValidMemberTransition('TODO', 'APPROVED', false), false)
  })

  test('Member may never set CHANGES_REQUIRED (that is a Manager-only outcome)', () => {
    assert.equal(isValidMemberTransition('IN_REVIEW', 'CHANGES_REQUIRED', true), false)
  })
})

describe('tasks: Manager review transitions — Test D/E (Manager Approve / Request Changes)', () => {
  test('IN_REVIEW -> APPROVED is allowed', () => {
    assert.equal(isValidManagerReviewTransition('IN_REVIEW', 'APPROVED'), true)
  })

  test('IN_REVIEW -> CHANGES_REQUIRED is allowed', () => {
    assert.equal(isValidManagerReviewTransition('IN_REVIEW', 'CHANGES_REQUIRED'), true)
  })

  test('Manager may only approve/request changes when task.status = IN_REVIEW', () => {
    assert.equal(isValidManagerReviewTransition('TODO', 'APPROVED'), false)
    assert.equal(isValidManagerReviewTransition('IN_PROGRESS', 'APPROVED'), false)
    assert.equal(isValidManagerReviewTransition('APPROVED', 'APPROVED'), false)
  })
})

describe('tasks: ordering — Test 2 (Task ordering)', () => {
  test('APPROVED and IN_REVIEW tasks are excluded from the reorderable set (locked/read-only)', () => {
    const stageTasks = [
      task({ id: 'a', status: 'TODO', order: 1 }),
      task({ id: 'b', status: 'APPROVED', order: 2 }),
      task({ id: 'c', status: 'IN_REVIEW', order: 3 }),
      task({ id: 'd', status: 'IN_PROGRESS', order: 4 }),
    ]
    const eligible = reorderableTasks(stageTasks).map((t) => t.id)
    assert.deepEqual(eligible, ['a', 'd'])
  })

  test('dragging a task to a new position renumbers only the reorderable set contiguously from 1', () => {
    const stageTasks = [
      task({ id: 'a', status: 'TODO', order: 1 }),
      task({ id: 'b', status: 'TODO', order: 2 }),
      task({ id: 'c', status: 'TODO', order: 3 }),
    ]
    // drag 'c' to where 'a' currently sits
    const result = recalculateTaskOrder(stageTasks, 'c', 'a')
    const byId = Object.fromEntries(result.map((r) => [r.id, r.order]))
    assert.equal(byId.c, 1)
    assert.equal(byId.a, 2)
    assert.equal(byId.b, 3)
  })

  test('reordering throws if either task is not in the reorderable set (e.g. already APPROVED)', () => {
    const stageTasks = [task({ id: 'a', status: 'APPROVED', order: 1 }), task({ id: 'b', status: 'TODO', order: 2 })]
    assert.throws(() => recalculateTaskOrder(stageTasks, 'a', 'b'))
  })

  test('nextTaskOrder: new normal task goes after the highest existing non-APPROVED order', () => {
    const stageTasks = [task({ id: 'a', status: 'TODO', order: 1 }), task({ id: 'b', status: 'APPROVED', order: 5 })]
    assert.equal(nextTaskOrder(stageTasks), 2) // APPROVED (order 5) is excluded from the max()
  })

  test('nextTaskOrder: empty stage starts at 1', () => {
    assert.equal(nextTaskOrder([]), 1)
  })

  test('nextChangeTaskOrder deliberately includes APPROVED tasks in its max() (differs from nextTaskOrder)', () => {
    const stageTasks = [task({ id: 'a', status: 'APPROVED', order: 5 })]
    assert.equal(nextChangeTaskOrder(stageTasks), 6)
  })
})
