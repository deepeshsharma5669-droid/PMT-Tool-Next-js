import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  isNavigationItemActive,
  MY_REVIEWS_HREF,
  MY_TASKS_HREF,
  navigationFor,
  type NavItem,
} from '../../../components/shell/navigation'

function item(label: string): NavItem {
  const match = navigationFor('MANAGER').flatMap(group => group.items).find(entry => entry.label === label)
  assert.ok(match, `Missing ${label} navigation item`)
  return match
}

test('Manager sidebar reuses the canonical filtered Work destinations', () => {
  assert.equal(item('My Tasks').href, MY_TASKS_HREF)
  assert.equal(item('Reviews').href, MY_REVIEWS_HREF)
  assert.equal(MY_TASKS_HREF, '/work?assignee=me&status=OPEN')
  assert.equal(MY_REVIEWS_HREF, '/work?reviewer=me&status=IN_REVIEW')
})

test('My Tasks is the only active Work navigation item for assigned open work', () => {
  const search = new URLSearchParams('assignee=me&status=OPEN')
  assert.equal(isNavigationItemActive(item('My Tasks'), '/work', search), true)
  assert.equal(isNavigationItemActive(item('Reviews'), '/work', search), false)
  assert.equal(isNavigationItemActive(item('Work'), '/work', search), false)
})

test('Reviews is the only active Work navigation item for assigned reviews', () => {
  const search = new URLSearchParams('reviewer=me&status=IN_REVIEW')
  assert.equal(isNavigationItemActive(item('My Tasks'), '/work', search), false)
  assert.equal(isNavigationItemActive(item('Reviews'), '/work', search), true)
  assert.equal(isNavigationItemActive(item('Work'), '/work', search), false)
})

test('normal and generally filtered Work views keep Work active', () => {
  for (const query of ['', 'kind=stages&status=ACTIVE', 'assignee=someone-else']) {
    const search = new URLSearchParams(query)
    assert.equal(isNavigationItemActive(item('Work'), '/work', search), true)
    assert.equal(isNavigationItemActive(item('My Tasks'), '/work', search), false)
    assert.equal(isNavigationItemActive(item('Reviews'), '/work', search), false)
  }
})
