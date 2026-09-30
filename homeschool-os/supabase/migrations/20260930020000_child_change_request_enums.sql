-- =============================================================================
-- 0115  STEP 8 PHASE 2 CORRECTION - the enums a request model needs
-- =============================================================================
-- THIS FILE EXISTS ONLY BECAUSE OF A POSTGRES RULE, not because the project
-- wants a separate migration here: a value added to an enum with `ADD VALUE`
-- cannot be used - not even by a later statement in the same migration - until
-- the transaction that added it has committed. 0109 already hit this and was
-- split the same way, for the same reason. So the new event kinds this
-- correction needs go in their own file, applied before anything that writes
-- one.
--
-- WHAT THIS CORRECTS: the deployed child_choose_alternative_activity let a
-- student replace her own activity directly. That was not the approved
-- workflow. The approved workflow is CHILD REQUESTS -> ADULT DECIDES -> ONLY
-- APPROVAL REPLACES, and 20260930020100 builds that. These are the four facts
-- its event log needs to be able to say happened.
-- =============================================================================

alter type app.learning_activity_event_kind add value if not exists 'change_requested';
alter type app.learning_activity_event_kind add value if not exists 'change_request_withdrawn';
alter type app.learning_activity_event_kind add value if not exists 'change_request_approved';
alter type app.learning_activity_event_kind add value if not exists 'change_request_declined';

-- The request's own lifecycle. Four states and nothing more: a request is
-- either waiting, granted, refused, or taken back by the child who made it.
create type app.activity_change_request_status as enum (
  'pending',
  'approved',
  'declined',
  'withdrawn');

comment on type app.activity_change_request_status is
  'The lifecycle of a child''s request to work on something different. '
  '`pending` is the only state a decision can still be made from; the other '
  'three are endings, and 20260930020100''s trigger refuses to move a request '
  'out of one.';
