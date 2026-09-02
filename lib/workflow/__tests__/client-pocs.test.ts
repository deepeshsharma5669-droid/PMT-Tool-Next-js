import { test } from 'node:test'
import assert from 'node:assert/strict'
import { prepareClientPocs, type NewClientPoc } from '../../clients/poc-input'

const poc = (name: string, is_primary = false): NewClientPoc =>
  ({ name, designation: '', email: '', phone: '', whatsapp: '', is_primary })

test('Client creation permits zero POCs', () => assert.deepEqual(prepareClientPocs([]), []))
test('One POC becomes primary', () => assert.equal(prepareClientPocs([poc('Alice')])[0].is_primary, true))
test('Multiple POCs default to first, without mutating input', () => {
  const input = [poc('Alice'), poc('Bob')]
  assert.deepEqual(prepareClientPocs(input).map(p => p.is_primary), [true, false])
  assert.equal(input[0].is_primary, false)
})
test('Explicit primary selection is preserved', () =>
  assert.deepEqual(prepareClientPocs([poc('Alice'), poc('Bob', true)]).map(p => p.is_primary), [false, true]))
test('Multiple primaries are rejected', () =>
  assert.throws(() => prepareClientPocs([poc('Alice', true), poc('Bob', true)]), /only one/))
test('Blank optional POC rows must be removed, not silently dropped', () =>
  assert.throws(() => prepareClientPocs([poc(' ')]), /requires a name/))
test('POC transport strips unrelated lifecycle/ownership fields', () => {
  const result = prepareClientPocs([{ ...poc(' Alice '), status: 'INACTIVE', client_id: 'other' } as NewClientPoc])
  assert.equal(result[0].name, 'Alice')
  assert.equal('status' in result[0], false)
  assert.equal('client_id' in result[0], false)
})
