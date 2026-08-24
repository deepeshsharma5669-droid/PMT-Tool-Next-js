/**
 * Port of the legacy `deliverableHasProductionHistory()`
 * (public/pmt-legacy.html, ~line 284):
 *
 *   function deliverableHasProductionHistory(deliverableId) {
 *     const deliv = getDeliverable(deliverableId);
 *     if (!deliv) return false;
 *     if (deliv.clientRevision > 0) return true;
 *     if ((deliv.feedbackHistory || []).length > 0) return true;
 *     const stageIds = DB.stages.filter(s => s.deliverableId === deliverableId).map(s => s.id);
 *     const tasks = DB.tasks.filter(t => stageIds.includes(t.stageId));
 *     return tasks.some(t => t.status !== 'TODO' || (t.submissions && t.submissions.length > 0));
 *   }
 *
 * This gates whether a Deliverable's Type may still be changed
 * (rebuilding its stage pipeline) — once real work has started, changing
 * type would silently discard history, which is explicitly disallowed.
 */
export function deliverableHasProductionHistory(
  clientRevision: number,
  feedbackEntryCount: number,
  anyTaskStartedOrHasSubmissions: boolean
): boolean {
  if (clientRevision > 0) return true
  if (feedbackEntryCount > 0) return true
  return anyTaskStartedOrHasSubmissions
}
