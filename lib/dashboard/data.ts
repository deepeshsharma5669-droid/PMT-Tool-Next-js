import type {PmtUser} from '@/lib/auth/types'
import {loadHierarchy} from '@/lib/hierarchy/data'
export type DashboardData=Awaited<ReturnType<typeof loadHierarchy>>
export async function loadDashboardData(_user:PmtUser):Promise<DashboardData>{return loadHierarchy()}
