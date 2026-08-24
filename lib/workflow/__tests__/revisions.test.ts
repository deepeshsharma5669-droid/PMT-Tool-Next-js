import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { revisionLabel, isValidRevisionIncrement } from '../revisions'

describe('revisions: labeling', () => {
  test('client_revision 0 is always labeled "Initial Production", never "Revision 0"', () => {
    assert.equal(revisionLabel(0), 'Initial Production')
  })
  test('client_revision > 0 is labeled "Revision N"', () => {
    assert.equal(revisionLabel(1), 'Revision 1')
    assert.equal(revisionLabel(2), 'Revision 2')
  })
})

describe('revisions: increment validation — Test C/F (0->1, 1->2, never arbitrary)', () => {
  test('Test C: 0 -> 1 is a valid first Client Change', () => {
    assert.equal(isValidRevisionIncrement(0, 1), true)
  })
  test('Test F: 1 -> 2 is a valid second Client Change', () => {
    assert.equal(isValidRevisionIncrement(1, 2), true)
  })
  test('an arbitrary jump is rejected', () => {
    assert.equal(isValidRevisionIncrement(0, 5), false)
    assert.equal(isValidRevisionIncrement(1, 1), false)
    assert.equal(isValidRevisionIncrement(2, 1), false)
  })
})
