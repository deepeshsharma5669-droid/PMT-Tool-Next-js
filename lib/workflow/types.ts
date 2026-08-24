/**
 * Minimal shapes needed by the pure workflow-logic functions in this
 * directory. Deliberately narrower than the full DB row shape — these
 * functions only need the fields they actually decide on, which keeps
 * them trivial to unit test with plain fixture objects (no DB, no Auth
 * session required).
 */

export type Role = 'ADMIN' | 'MANAGER' | 'MEMBER'

export type TaskStatus = 'TODO' | 'IN_PROGRESS' | 'IN_REVIEW' | 'CHANGES_REQUIRED' | 'APPROVED'
export type StageStatus = 'PENDING' | 'ACTIVE' | 'CLIENT_DECISION' | 'COMPLETED'
export type DeliverableStatus = 'IN_PROGRESS' | 'CLIENT_REVIEW' | 'CHANGES_REQUESTED' | 'COMPLETED'
export type CampaignStatus = 'ACTIVE' | 'ARCHIVED' | 'COMPLETED'
export type DeliverableType = 'Static Poster' | 'Instagram Carousel' | 'Instagram Reel' | 'Presentation'

export type WorkflowTask = {
  id: string
  stageId: string
  status: TaskStatus
  isClientChange: boolean
  clientRevision: number | null
  order: number
  assigneeId: string
}

export type WorkflowStage = {
  id: string
  deliverableId: string
  dept: string
  order: number
  status: StageStatus
  reworkPending: boolean
}

export type WorkflowDeliverable = {
  id: string
  campaignId: string
  status: DeliverableStatus
  clientRevision: number
}

export type WorkflowCampaign = {
  id: string
  status: CampaignStatus
}

export type Identity = {
  id: string
  role: Role
  dept: string | null
  status: 'PENDING' | 'ACTIVE' | 'INACTIVE'
}
