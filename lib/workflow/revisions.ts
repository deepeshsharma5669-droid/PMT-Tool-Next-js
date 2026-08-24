/**
 * Client revision labeling and validation. Port of the legacy
 * `revisionLabel()` display convention used throughout (e.g. Client
 * Approval modal: `${revisionLabel(deliv.clientRevision)}`), where 0 is
 * always shown as "Initial Production", never "Revision 0".
 */
export function revisionLabel(clientRevision: number): string {
  return clientRevision === 0 ? 'Initial Production' : `Revision ${clientRevision}`
}

/** client_revision may only ever move to exactly old+1 — never arbitrary. */
export function isValidRevisionIncrement(oldRevision: number, newRevision: number): boolean {
  return newRevision === oldRevision + 1
}
