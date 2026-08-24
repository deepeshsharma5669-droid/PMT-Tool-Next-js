/**
 * Port of the legacy `campaignAllDeliverablesCompleted()`
 * (public/pmt-legacy.html, ~line 3393):
 *
 *   function campaignAllDeliverablesCompleted(campaignId) {
 *     const delivs = DB.deliverables.filter(d => d.campaignId === campaignId);
 *     return delivs.length > 0 && delivs.every(d => d.status === 'COMPLETED');
 *   }
 *
 * This is the ONLY thing allowed to make a Campaign COMPLETED — never a
 * direct manual selection, per the legacy `openEditCampaignModal` guard
 * ("Campaign cannot be marked Completed until all Deliverables are
 * completed").
 */
import type { WorkflowDeliverable } from './types'

export function allDeliverablesCompleted(deliverables: WorkflowDeliverable[]): boolean {
  return deliverables.length > 0 && deliverables.every((d) => d.status === 'COMPLETED')
}
