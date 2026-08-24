-- Fix found by integration testing of Phase 6's pmt_record_client_changes():
--
-- The original pmt_client_decisions_insert / pmt_deliverable_feedback_insert
-- policies (0003) required the inserted row's client_revision to equal the
-- deliverable's CURRENT client_revision. That's correct for an APPROVED
-- decision (the revision doesn't change), but wrong for a CHANGES_REQUESTED
-- decision — the legacy submitClientChanges() increments clientRevision
-- FIRST, then records the decision/feedback with the NEW value:
--
--   deliv.clientRevision = (deliv.clientRevision || 0) + 1;
--   DB.clientDecisionHistory.push({ ..., clientRevision: deliv.clientRevision, ... });
--
-- pmt_record_client_changes() ports this ordering (insert decision +
-- feedback with the new revision, THEN update pmt_deliverables.client_revision),
-- so at INSERT time the deliverable's stored value is still the OLD one —
-- the old check rejected every Client Changes recording. Fixed by branching
-- on `decision` (client_decisions) / always expecting +1 (deliverable_feedback,
-- which per this schema is only ever written alongside a Client Changes event).

begin;

drop policy if exists pmt_client_decisions_insert on pmt_client_decisions;
create policy pmt_client_decisions_insert on pmt_client_decisions for insert
  with check (
    recorded_by = pmt_current_pmt_id()
    and (
      (decision = 'APPROVED' and client_revision = (select client_revision from pmt_deliverables d where d.id = pmt_client_decisions.deliverable_id))
      or (decision = 'CHANGES_REQUESTED' and client_revision = (select client_revision from pmt_deliverables d where d.id = pmt_client_decisions.deliverable_id) + 1)
    )
    and exists (
      select 1 from pmt_stages s
      where s.deliverable_id = pmt_client_decisions.deliverable_id
      and s.status = 'CLIENT_DECISION'
      and (pmt_is_admin() or pmt_is_manager_of(s.dept))
    )
  );

drop policy if exists pmt_deliverable_feedback_insert on pmt_deliverable_feedback;
create policy pmt_deliverable_feedback_insert on pmt_deliverable_feedback for insert
  with check (
    author_id = pmt_current_pmt_id()
    and client_revision = (select client_revision from pmt_deliverables d where d.id = pmt_deliverable_feedback.deliverable_id) + 1
    and exists (
      select 1 from pmt_stages s
      where s.deliverable_id = pmt_deliverable_feedback.deliverable_id
      and s.status = 'CLIENT_DECISION'
      and (pmt_is_admin() or pmt_is_manager_of(s.dept))
    )
  );

commit;
