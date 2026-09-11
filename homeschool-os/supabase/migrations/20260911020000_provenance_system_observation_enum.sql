-- =============================================================================
-- 0096  A label for evidence a person confirmed that no model ever touched
-- =============================================================================
-- `confirm_diagnostic_observation` was writing its evidence as
-- `human_confirmed_ai_proposal`, and that is not what happened. The Phase 5
-- routing engine is arithmetic over rows: it picks the next skill from the
-- prerequisite graph and the child's own stored profile, and there is nowhere in
-- its path for a model to be reached - 0095 refuses the functions if their
-- source so much as mentions the standards catalogue, and nothing in 0093 calls
-- out to anything. So a diagnostic observation is a SYSTEM observation, made
-- deterministically, and the parent who reviews it is confirming Nestra's
-- arithmetic, not a model's guess.
--
-- The distinction is not pedantic. `record_provenance` is the column an
-- evaluator reads to answer "where did this come from?", and a portfolio that
-- says a child's fraction evidence was AI-generated is making a claim about this
-- family that is false. It is also the wrong way round for trust: the one part
-- of Nestra that provably never consults a model was the part labelled as
-- though it had.
--
--   human_entered
--     a person originated the record.
--   human_confirmed_ai_proposal
--     a model proposed it and a person confirmed it.
--   human_confirmed_system_observation           <- added here
--     Nestra observed it deterministically and a person confirmed it.
--   ai_proposed_unreviewed
--     a model proposed it and nobody has looked yet.
--   system_computed
--     derived by Nestra, with no human confirmation event behind it.
--
-- WHY THIS MIGRATION IS ALONE. PostgreSQL will add an enum value inside a
-- transaction but will not let the same transaction USE it. Everything that
-- reads or writes the new label therefore lives in 0097, which runs in its own
-- transaction afterwards. Splitting it is not tidiness; the combined version
-- fails with "unsafe use of new value of enum type".
-- =============================================================================

alter type app.record_provenance
  add value if not exists 'human_confirmed_system_observation'
  after 'human_confirmed_ai_proposal';

comment on type app.record_provenance is
  'Where a record came from. `human_confirmed_ai_proposal` and '
  '`human_confirmed_system_observation` are both a person saying yes, and they '
  'differ in what she said yes TO: a model''s proposal, or Nestra''s own '
  'deterministic observation. Do not collapse them - the column exists so a '
  'family can tell.';

select app.assert_schema_invariants();
