import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { cascadeCompletion } from '../stages'
import type { WorkflowDeliverable, WorkflowStage } from '../types'

function stage(overrides: Partial<WorkflowStage>): WorkflowStage {
  return { id: 's1', deliverableId: 'd1', dept: 'Content', order: 1, status: 'ACTIVE', reworkPending: false, ...overrides }
}
function deliverable(overrides: Partial<WorkflowDeliverable>): WorkflowDeliverable {
  return { id: 'd1', campaignId: 'camp1', status: 'IN_PROGRESS', clientRevision: 0, ...overrides }
}

describe('stages: cascadeCompletion — mid-pipeline (Test B: next stage activates)', () => {
  test('completing a non-final stage activates the next one, deliverable stays IN_PROGRESS', () => {
    const stages = [stage({ id: 's1', order: 1 }), stage({ id: 's2', order: 2, status: 'PENDING' }), stage({ id: 's3', order: 3, status: 'PENDING' })]
    const result = cascadeCompletion(stages, 's1', [])
    assert.equal(result.completedStageId, 's1')
    assert.equal(result.nextStageId, 's2')
    assert.equal(result.newDeliverableStatus, 'IN_PROGRESS')
    assert.equal(result.campaignCompletes, false)
  })

  test('does not activate a stage further down the pipeline than the immediate next one', () => {
    const stages = [stage({ id: 's1', order: 1 }), stage({ id: 's2', order: 2 }), stage({ id: 's3', order: 3 })]
    const result = cascadeCompletion(stages, 's1', [])
    assert.notEqual(result.nextStageId, 's3')
  })
})

describe('stages: cascadeCompletion — final stage (Test B: deliverable completes)', () => {
  test('completing the final stage completes the deliverable, no next stage', () => {
    const stages = [stage({ id: 's1', order: 1 }), stage({ id: 's2', order: 2 })]
    const result = cascadeCompletion(stages, 's2', [])
    assert.equal(result.nextStageId, null)
    assert.equal(result.newDeliverableStatus, 'COMPLETED')
  })

  test('Test G: campaign completes ONLY when every other deliverable is already COMPLETED', () => {
    const stages = [stage({ id: 's1', order: 1 })]
    const otherStillInProgress = [deliverable({ id: 'd2', status: 'IN_PROGRESS' })]
    assert.equal(cascadeCompletion(stages, 's1', otherStillInProgress).campaignCompletes, false)

    const otherCompleted = [deliverable({ id: 'd2', status: 'COMPLETED' })]
    assert.equal(cascadeCompletion(stages, 's1', otherCompleted).campaignCompletes, true)
  })

  test('Test A: a deliverable with no siblings (single-deliverable campaign) completes the campaign alone', () => {
    const stages = [stage({ id: 's1', order: 1 })]
    assert.equal(cascadeCompletion(stages, 's1', []).campaignCompletes, true)
  })

  test('Test A: Deliverable A completing must not depend on or affect Deliverable B\'s own stages', () => {
    // Deliverable A's cascade only ever receives Deliverable B's DELIVERABLE-level
    // status (for the campaign-completion check) — never B's stages, confirming
    // A's stage cascade cannot reach into B's pipeline at all by construction.
    const aStages = [stage({ id: 'a-s1', deliverableId: 'dA', order: 1 })]
    const bStillInProgress = [deliverable({ id: 'dB', status: 'IN_PROGRESS' })]
    const result = cascadeCompletion(aStages, 'a-s1', bStillInProgress)
    assert.equal(result.newDeliverableStatus, 'COMPLETED') // A completes regardless of B
    assert.equal(result.campaignCompletes, false) // but campaign does not, because of B
  })
})
