/**
 * Ported verbatim from the legacy WORKFLOW_TEMPLATES constant
 * (public/pmt-legacy.html, ~line 190). Determines the stage pipeline a new
 * Deliverable of a given type gets, and what it rebuilds to on a type
 * change (before production history exists).
 */
import type { DeliverableType } from './types'

export type StageTemplateEntry = { name: string; dept: string }

export const WORKFLOW_TEMPLATES: Record<DeliverableType, StageTemplateEntry[]> = {
  'Static Poster': [
    { name: 'Content Strategy', dept: 'Content' },
    { name: 'Visual Design', dept: 'Design' },
  ],
  'Instagram Carousel': [
    { name: 'Copywriting', dept: 'Content' },
    { name: 'Layout Design', dept: 'Design' },
  ],
  'Instagram Reel': [
    { name: 'Scripting', dept: 'Content' },
    { name: 'Storyboarding', dept: 'Design' },
    { name: 'Animation', dept: 'Animation' },
  ],
  Presentation: [
    { name: 'Content Drafting', dept: 'Content' },
    { name: 'Slide Design', dept: 'Design' },
  ],
}

/** DB.type || 'Static Poster' fallback used throughout the legacy loader. */
export function stageTemplateFor(type: string): StageTemplateEntry[] {
  return WORKFLOW_TEMPLATES[type as DeliverableType] ?? WORKFLOW_TEMPLATES['Static Poster']
}
