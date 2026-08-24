import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { allDeliverablesCompleted } from '../campaigns'
import type { WorkflowDeliverable } from '../types'

function d(id: string, status: WorkflowDeliverable['status']): WorkflowDeliverable {
  return { id, campaignId: 'camp1', status, clientRevision: 0 }
}

describe('campaigns: allDeliverablesCompleted — Test G', () => {
  test('Campaign != COMPLETED while any Deliverable is not COMPLETED', () => {
    assert.equal(allDeliverablesCompleted([d('A', 'COMPLETED'), d('B', 'IN_PROGRESS')]), false)
  })

  test('Campaign becomes eligible for COMPLETED only when every Deliverable is COMPLETED', () => {
    assert.equal(allDeliverablesCompleted([d('A', 'COMPLETED'), d('B', 'COMPLETED')]), true)
  })

  test('a campaign with zero deliverables is never "all completed" (vacuous truth explicitly rejected)', () => {
    assert.equal(allDeliverablesCompleted([]), false)
  })

  test('a single non-COMPLETED deliverable is enough to keep the whole campaign incomplete', () => {
    assert.equal(allDeliverablesCompleted([d('A', 'CLIENT_REVIEW')]), false)
  })
})
