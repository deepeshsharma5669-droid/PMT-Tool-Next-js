/**
 * Corrected Stage-level gate abstraction.
 *
 * client_revision remains Deliverable-level, but gate mode is selected from
 * the tasks belonging to the current Stage. A later Stage therefore starts in
 * normal production even when an earlier Stage increased the Deliverable's
 * revision.
 */
import type { StageStatus, WorkflowTask } from './types'

export type StageGateMode = 'NORMAL_PRODUCTION' | 'CLIENT_REWORK'

export function getCurrentStageGateMode(
  stageTasks: WorkflowTask[],
  deliverableClientRevision: number
): StageGateMode {
  return stageTasks.some(
    (task) => task.isClientChange && task.clientRevision === deliverableClientRevision
  )
    ? 'CLIENT_REWORK'
    : 'NORMAL_PRODUCTION'
}

export function relevantGateTasks(
  stageTasks: WorkflowTask[],
  deliverableClientRevision: number
): WorkflowTask[] {
  if (getCurrentStageGateMode(stageTasks, deliverableClientRevision) === 'CLIENT_REWORK') {
    return stageTasks.filter(
      (task) => task.isClientChange && task.clientRevision === deliverableClientRevision
    )
  }
  return stageTasks.filter((task) => !task.isClientChange && task.clientRevision === null)
}

export function isGateOpen(stageTasks: WorkflowTask[], deliverableClientRevision: number): boolean {
  const relevant = relevantGateTasks(stageTasks, deliverableClientRevision)
  return relevant.length > 0 && relevant.every((task) => task.status === 'APPROVED')
}

export type GateResult =
  | { opens: false }
  | {
      opens: true
      newStageStatus: 'CLIENT_DECISION'
      newDeliverableStatus: 'CLIENT_REVIEW'
      clearsReworkPending: true
    }

export function recalculateStageGate(
  stageTasks: WorkflowTask[],
  deliverableClientRevision: number,
  currentStageStatus: StageStatus
): GateResult {
  if (currentStageStatus === 'COMPLETED' || !isGateOpen(stageTasks, deliverableClientRevision)) {
    return { opens: false }
  }
  return {
    opens: true,
    newStageStatus: 'CLIENT_DECISION',
    newDeliverableStatus: 'CLIENT_REVIEW',
    clearsReworkPending: true,
  }
}
