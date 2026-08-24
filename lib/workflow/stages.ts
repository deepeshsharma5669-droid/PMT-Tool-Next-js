/**
 * Port of the legacy `cascadeCompletion()` (public/pmt-legacy.html, ~line
 * 332). Runs after a Client Decision (Gate 2) approves the current stage.
 *
 * Original:
 *   function cascadeCompletion(stageId) {
 *     const stage = getStage(stageId);
 *     const deliv = getDeliverable(stage.deliverableId);
 *     const camp = getCampaign(deliv.campaignId);
 *     const delivStages = DB.stages.filter(s => s.deliverableId === deliv.id).sort((a,b)=>a.order - b.order);
 *     const currentIndex = delivStages.findIndex(s => s.id === stageId);
 *     stage.status = 'COMPLETED';
 *     if (currentIndex < delivStages.length - 1) {
 *       const nextStage = delivStages[currentIndex+1];
 *       nextStage.status = 'ACTIVE';
 *       deliv.status = 'IN_PROGRESS';
 *     } else {
 *       deliv.status = 'COMPLETED';
 *       const campDelivs = DB.deliverables.filter(d => d.campaignId === camp.id);
 *       if (campDelivs.every(d => d.status === 'COMPLETED')) {
 *         camp.status = 'COMPLETED';
 *       }
 *     }
 *   }
 *
 * Deliverables are independent: this only ever looks at the OTHER
 * deliverables' current status to decide campaign completion — it never
 * activates or blocks anything belonging to a different deliverable.
 */
import type { WorkflowDeliverable, WorkflowStage } from './types'

export type CascadeResult = {
  completedStageId: string
  nextStageId: string | null
  newDeliverableStatus: 'IN_PROGRESS' | 'COMPLETED'
  campaignCompletes: boolean
}

export function cascadeCompletion(
  deliverableStages: WorkflowStage[],
  currentStageId: string,
  otherCampaignDeliverables: WorkflowDeliverable[]
): CascadeResult {
  const sorted = [...deliverableStages].sort((a, b) => a.order - b.order)
  const idx = sorted.findIndex((s) => s.id === currentStageId)
  if (idx === -1) {
    throw new Error(`Stage ${currentStageId} not found among the provided deliverable's stages.`)
  }

  const isLast = idx === sorted.length - 1

  if (!isLast) {
    return {
      completedStageId: currentStageId,
      nextStageId: sorted[idx + 1].id,
      newDeliverableStatus: 'IN_PROGRESS',
      campaignCompletes: false,
    }
  }

  const campaignCompletes = otherCampaignDeliverables.every((d) => d.status === 'COMPLETED')

  return {
    completedStageId: currentStageId,
    nextStageId: null,
    newDeliverableStatus: 'COMPLETED',
    campaignCompletes,
  }
}
