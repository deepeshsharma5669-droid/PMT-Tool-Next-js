/**
 * Structured result shape for every Server Action in this directory — no
 * browser alert()/throw-to-the-UI. Every action catches whatever the
 * underlying RPC raised (a Postgres exception message, from `raise
 * exception '...'` in supabase/migrations/0005_workflow_functions.sql) and
 * returns it as `error` instead of letting it bubble as an unhandled
 * rejection.
 */
export type ActionResult<T> = { success: true; data: T } | { success: false; error: string }

export function ok<T>(data: T): ActionResult<T> {
  return { success: true, data }
}

export function fail<T>(error: unknown): ActionResult<T> {
  const message = error instanceof Error ? error.message : String(error)
  return { success: false, error: message }
}
