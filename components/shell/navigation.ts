import type { Role } from '@/lib/auth/types'
import type { IconName } from '@/components/ui/icon'

export const MY_TASKS_HREF = '/work?assignee=me&status=OPEN'
export const MY_REVIEWS_HREF = '/work?reviewer=me&status=IN_REVIEW'

export type NavItem = { label: string; href: string; icon: IconName; available?: boolean }
export type NavGroup = { label: string; items: NavItem[] }
type SearchParams = { get(name: string): string | null }

function isMyTasksView(search: SearchParams) {
  return search.get('assignee') === 'me' && search.get('status') === 'OPEN'
}

function isMyReviewsView(search: SearchParams) {
  return search.get('reviewer') === 'me' && search.get('status') === 'IN_REVIEW'
}

export function isNavigationItemActive(item: NavItem, pathname: string, search: SearchParams) {
  if (item.href === MY_TASKS_HREF) return pathname === '/work' && isMyTasksView(search)
  if (item.href === MY_REVIEWS_HREF) return pathname === '/work' && isMyReviewsView(search)
  if (item.href === '/work') {
    return pathname === '/work' && !isMyTasksView(search) && !isMyReviewsView(search)
  }

  const base = item.href.split(/[?#]/)[0]
  return pathname === base || (base !== '/dashboard' && pathname.startsWith(base + '/'))
}

export function navigationFor(role: Role): NavGroup[] {
  const main: NavItem[] = [
    { label: 'Dashboard', href: '/dashboard', icon: 'home', available: true },
    { label: 'Work', href: '/work', icon: 'check', available: true },
    { label: 'Projects', href: '/campaigns', icon: 'folder', available: true },
  ]

  if (role === 'ADMIN') {
    main.push({ label: 'Clients', href: '/clients', icon: 'briefcase', available: true })
  } else if (role === 'MANAGER') {
    main.push(
      { label: 'My Tasks', href: MY_TASKS_HREF, icon: 'clipboard', available: true },
      { label: 'Reviews', href: MY_REVIEWS_HREF, icon: 'check', available: true },
    )
  } else {
    main.push({ label: 'My Tasks', href: MY_TASKS_HREF, icon: 'clipboard', available: true })
  }

  const account: NavItem[] = [
    { label: 'Notifications', href: '/notifications', icon: 'bell', available: true },
    { label: 'Profile', href: '/profile', icon: 'user', available: true },
  ]
  if (role === 'ADMIN') {
    account.unshift(
      { label: 'Users', href: '/users', icon: 'users', available: true },
      { label: 'Activity & Audit', href: '/activity', icon: 'activity', available: true },
    )
  }

  return [{ label: 'Workspace', items: main }, { label: 'Manage', items: account }]
}
