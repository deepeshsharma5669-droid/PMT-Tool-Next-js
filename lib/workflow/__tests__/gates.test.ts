import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { getCurrentStageGateMode, relevantGateTasks, isGateOpen, recalculateStageGate } from '../gates'
import type { WorkflowTask } from '../types'

function task(overrides: Partial<WorkflowTask>): WorkflowTask {
  return {
    id: 't1',
    stageId: 's1',
    status: 'TODO',
    isClientChange: false,
    clientRevision: null,
    order: 1,
    assigneeId: 'u1',
    ...overrides,
  }
}

describe('gates: Initial Production (client_revision = 0) — Test B', () => {
  test('normal tasks are is_client_change=false, client_revision=null, and all count', () => {
    const tasks = [
      task({ id: 'a', status: 'APPROVED' }),
      task({ id: 'b', status: 'APPROVED' }),
    ]
    assert.equal(relevantGateTasks(tasks, 0).length, 2)
  })

  test('gate opens only when every task on the stage is approved', () => {
    const notAllApproved = [task({ id: 'a', status: 'APPROVED' }), task({ id: 'b', status: 'IN_REVIEW' })]
    assert.equal(isGateOpen(notAllApproved, 0), false)

    const allApproved = [task({ id: 'a', status: 'APPROVED' }), task({ id: 'b', status: 'APPROVED' })]
    assert.equal(isGateOpen(allApproved, 0), true)
  })

  test('empty task list never opens the gate', () => {
    assert.equal(isGateOpen([], 0), false)
  })

  test('recalculateStageGate flips to CLIENT_DECISION/CLIENT_REVIEW when the gate opens', () => {
    const tasks = [task({ id: 'a', status: 'APPROVED' })]
    const result = recalculateStageGate(tasks, 0, 'ACTIVE')
    assert.equal(result.opens, true)
    if (result.opens) {
      assert.equal(result.newStageStatus, 'CLIENT_DECISION')
      assert.equal(result.newDeliverableStatus, 'CLIENT_REVIEW')
      assert.equal(result.clearsReworkPending, true)
    }
  })

  test('an already-COMPLETED stage is never reopened, even if tasks look approved', () => {
    const tasks = [task({ id: 'a', status: 'APPROVED' })]
    assert.equal(recalculateStageGate(tasks, 0, 'COMPLETED').opens, false)
  })
})

describe('gates: Revision > 0 — Test E / Test F (only current-revision Change Tasks count)', () => {
  test('later Stage first activation after Revision 1 uses normal production tasks', () => {
    const tasks = [task({ id: 'normal', status: 'APPROVED' })]
    assert.equal(getCurrentStageGateMode(tasks, 1), 'NORMAL_PRODUCTION')
    assert.equal(isGateOpen(tasks, 1), true)
  })

  test('later Stage first activation after Revision 2 uses normal production tasks', () => {
    const tasks = [task({ id: 'a', status: 'APPROVED' }), task({ id: 'b', status: 'APPROVED' })]
    assert.equal(getCurrentStageGateMode(tasks, 2), 'NORMAL_PRODUCTION')
    assert.equal(isGateOpen(tasks, 2), true)
  })

  test('later Stage first activation after Revision 3 uses normal production tasks', () => {
    const tasks = [task({ id: 'normal', status: 'APPROVED' })]
    assert.equal(getCurrentStageGateMode(tasks, 3), 'NORMAL_PRODUCTION')
    assert.equal(isGateOpen(tasks, 3), true)
  })

  test('historical (older-revision) Change Tasks are excluded from the CURRENT revision gate', () => {
    const rev1Task = task({ id: 'r1', status: 'APPROVED', isClientChange: true, clientRevision: 1 })
    const rev2Task = task({ id: 'r2', status: 'TODO', isClientChange: true, clientRevision: 2 })
    const tasks = [rev1Task, rev2Task]

    // Revision 1 is now history — only revision 2 tasks should count for gate 2.
    const relevant = relevantGateTasks(tasks, 2)
    assert.equal(relevant.length, 1)
    assert.equal(relevant[0].id, 'r2')
    assert.equal(isGateOpen(tasks, 2), false) // r2 is still TODO
  })

  test('Test E: both Revision 1 Change Tasks approved -> Gate 2 opens, old production tasks do not affect it', () => {
    const productionTask = task({ id: 'prod', status: 'IN_PROGRESS', isClientChange: false, clientRevision: null })
    const changeTaskA = task({ id: 'ct1', status: 'APPROVED', isClientChange: true, clientRevision: 1 })
    const changeTaskB = task({ id: 'ct2', status: 'APPROVED', isClientChange: true, clientRevision: 1 })
    const tasks = [productionTask, changeTaskA, changeTaskB]

    assert.equal(isGateOpen(tasks, 1), true)
    assert.equal(getCurrentStageGateMode(tasks, 1), 'CLIENT_REWORK')
    const result = recalculateStageGate(tasks, 1, 'ACTIVE')
    assert.equal(result.opens, true)
  })

  test('Test F: Revision 2 gate ignores Revision 1 tasks even if they are also APPROVED', () => {
    const rev1Approved = task({ id: 'ct1', status: 'APPROVED', isClientChange: true, clientRevision: 1 })
    const rev2Pending = task({ id: 'ct3', status: 'IN_REVIEW', isClientChange: true, clientRevision: 2 })
    const tasks = [rev1Approved, rev2Pending]

    assert.equal(isGateOpen(tasks, 2), false) // rev2 task not approved yet
    const rev2Approved = [rev1Approved, task({ id: 'ct3', status: 'APPROVED', isClientChange: true, clientRevision: 2 })]
    assert.equal(isGateOpen(rev2Approved, 2), true)
  })

  test('mixed historical + current tasks count only current-revision Change Tasks', () => {
    const tasks = [
      task({ id: 'normal', status: 'APPROVED' }),
      task({ id: 'old', status: 'APPROVED', isClientChange: true, clientRevision: 1 }),
      task({ id: 'current', status: 'IN_REVIEW', isClientChange: true, clientRevision: 2 }),
    ]
    assert.equal(getCurrentStageGateMode(tasks, 2), 'CLIENT_REWORK')
    assert.deepEqual(relevantGateTasks(tasks, 2).map((item) => item.id), ['current'])
    assert.equal(isGateOpen(tasks, 2), false)
  })

  test('critical regression: Stage 2 normal tasks open after Stage 1 raised revision to 2', () => {
    const stage2Tasks = [
      task({ id: 'design-a', stageId: 'stage-2', status: 'APPROVED' }),
      task({ id: 'design-b', stageId: 'stage-2', status: 'APPROVED' }),
    ]
    assert.equal(getCurrentStageGateMode(stage2Tasks, 2), 'NORMAL_PRODUCTION')
    assert.deepEqual(recalculateStageGate(stage2Tasks, 2, 'ACTIVE'), {
      opens: true,
      newStageStatus: 'CLIENT_DECISION',
      newDeliverableStatus: 'CLIENT_REVIEW',
      clearsReworkPending: true,
    })
  })
})
