-- =============================================================================
-- Assertions on the 0081-0083 migration of synthetic legacy rows
-- =============================================================================
-- Runs AFTER 0081, 0082 and 0083 have been applied over the seeded rows.
--
-- The claim being tested is not "the migration ran". It is that the migration
-- did not silently invent knowledge about a child: no row came out asserting
-- more than its legacy value could establish, and every axis the legacy value
-- could not answer came out explicitly unknown rather than plausibly filled in.
-- =============================================================================

-- Taken before a single assertion runs. Several tests below deliberately mutate
-- rows to prove a constraint refuses something, and section 10 was comparing
-- against the wreckage they leave rather than against what the migration
-- produced. The snapshot is the migration's actual output.
create temporary table mig_profile_snapshot as
  select student_id, skill_id, notes, skill_state, computed_state,
         active_override_id, override_state
    from public.student_skills;

do $$
declare v_n int; v_state text; v_src text; v_prov text;
begin
  -- ---------------------------------------------------------------- states ---
  select skill_state::text into v_state from public.student_skills where notes = 'MIGTEST not_started';
  perform t.assert_eq(v_state, 'unknown',
    '1a. not_started became unknown - an absence of evidence is not a verdict');
  perform t.assert(v_state <> 'emerging',
    '1b. and specifically NOT emerging - nothing was shown');

  select skill_state::text into v_state from public.student_skills where notes = 'MIGTEST introduced';
  perform t.assert_eq(v_state, 'unknown',
    '1c. introduced became unknown - instruction happened, the child showed nothing');

  select skill_state::text into v_state from public.student_skills where notes = 'MIGTEST developing';
  perform t.assert_eq(v_state, 'developing', '1d. developing stayed developing');

  select skill_state::text into v_state from public.student_skills where notes = 'MIGTEST progressing';
  perform t.assert_eq(v_state, 'developing',
    '1e. progressing became developing - never mapped upward');

  select skill_state::text into v_state from public.student_skills where notes = 'MIGTEST proficient';
  perform t.assert_eq(v_state, 'developing',
    '1f. proficient became developing - only mastered carried a human-confirmation guarantee');

  select skill_state::text into v_state from public.student_skills where notes = 'MIGTEST mastered';
  perform t.assert_eq(v_state, 'secure', '1g. mastered became secure');

  -- THE ONE THAT MATTERS MOST. `emerging` means the child showed early signs.
  -- No legacy value meant that, so the migration must never produce it.
  select count(*)::int into v_n from public.student_skills
   where notes like 'MIGTEST%' and skill_state = 'emerging';
  perform t.assert_eq(v_n, 0, '1h. the migration invented `emerging` for nobody');

  -- ------------------------------------------------------------ confidence ---
  -- The legacy enum never carried evidence STRENGTH. assessment_confirmed looks
  -- like one and is not: it names a source. Reading it as a strength would put
  -- source authority back into the confidence axis.
  select count(*)::int into v_n from public.student_skills
   where notes like 'MIGTEST%' and evidence_confidence is not null;
  perform t.assert_eq(v_n, 0,
    '2a. no legacy row was given an evidence_confidence - the old enum could not establish one');

  select count(*)::int into v_n from public.student_skill_events
   where evidence_note like 'MIGTEST%' and evidence_confidence is not null;
  perform t.assert_eq(v_n, 0, '2b. and neither was any event');

  -- ---------------------------------------------------------------- source ---
  select evidence_source::text into v_src from public.student_skills where notes = 'MIGTEST introduced';
  perform t.assert_eq(v_src, 'parent', '3a. parent_reported established the source');
  select evidence_source::text into v_src from public.student_skills where notes = 'MIGTEST developing';
  perform t.assert_eq(v_src, 'student_self', '3b. self_reported established the source');
  select evidence_source::text into v_src from public.student_skills where notes = 'MIGTEST progressing';
  perform t.assert_eq(v_src, 'teacher', '3c. teacher_observed established the source');
  select evidence_source::text into v_src from public.student_skills where notes = 'MIGTEST proficient';
  perform t.assert_eq(v_src, 'assessment_instrument', '3d. assessment_confirmed established the source');
  select evidence_source::text into v_src from public.student_skills where notes = 'MIGTEST not_started';
  perform t.assert_eq(v_src, 'unknown',
    '3e. ai_suggested established NO source - it answers a different question');

  -- ------------------------------------------------------------ provenance ---
  select record_provenance::text into v_prov from public.student_skills where notes = 'MIGTEST not_started';
  perform t.assert_eq(v_prov, 'ai_proposed_unreviewed',
    '4a. ai_suggested with no human confirmation is an unreviewed proposal');
  select record_provenance::text into v_prov from public.student_skills where notes = 'MIGTEST ai_confirmed';
  perform t.assert_eq(v_prov, 'human_confirmed_ai_proposal',
    '4b. ai_generated plus a human confirmation is a confirmed proposal');
  select record_provenance::text into v_prov from public.student_skills where notes = 'MIGTEST progressing';
  perform t.assert_eq(v_prov, 'unknown',
    '4c. a row that said nothing about provenance came out unknown, not human_entered');

  -- ------------------------------------------------ nothing gained or lost ---
  -- The legacy seed only. `before_*.sql` files seed rows later, against a
  -- schema these migrations produced, and counting those here would make this
  -- assertion drift every time one is added.
  select count(*)::int into v_n from public.student_skills
   where notes like 'MIGTEST%' and notes not like 'MIGTEST % profile';
  perform t.assert_eq(v_n, 7, '5a. every seeded row survived the migration');
  select count(*)::int into v_n from public.student_skill_events
   where evidence_note like 'MIGTEST%' and evidence_note like 'MIGTEST event%';
  perform t.assert_eq(v_n, 2, '5b. and every seeded event');

  select skill_state::text into v_state from public.student_skill_events
   where evidence_note = 'MIGTEST event with no state';
  perform t.assert(v_state is null,
    '5c. an event that asserted no state still asserts none - it did not become unknown');

  -- ------------------------------------------- the unreviewed-AI structure ---
  -- The seeded unreviewed row is `unknown`, so it satisfies the new constraint.
  -- Prove the constraint actually bites by trying to give it a state.
  begin
    update public.student_skills set skill_state = 'developing' where notes = 'MIGTEST not_started';
    raise exception 'ASSERTION FAILED: 6a. an unreviewed AI proposal was given a state';
  exception when check_violation then null;
  end;

  -- And that a human-confirmed proposal may hold one.
  update public.student_skills set skill_state = 'developing' where notes = 'MIGTEST ai_confirmed';
  perform t.assert_eq(
    (select skill_state::text from public.student_skills where notes = 'MIGTEST ai_confirmed'),
    'developing', '6b. a human-confirmed proposal may carry a state');

  -- ------------------------------------------------ secure needs a human ----
  begin
    update public.student_skills
       set skill_state = 'secure', human_confirmed_by = null, human_confirmed_at = null
     where notes = 'MIGTEST developing';
    raise exception 'ASSERTION FAILED: 7a. secure was accepted with no human confirmation';
  exception when check_violation then null;
  end;

  -- A PARENT may reach secure. The old constraint required teacher_observed or
  -- assessment_confirmed, which in a homeschool meant a parent never could.
  update public.student_skills
     set skill_state = 'secure', evidence_source = 'parent',
         human_confirmed_by = '11111111-1111-4111-8111-000000000001', human_confirmed_at = now()
   where notes = 'MIGTEST introduced';
  perform t.assert_eq(
    (select skill_state::text from public.student_skills where notes = 'MIGTEST introduced'),
    'secure', '7b. a parent''s own confirmation can reach secure');
end $$;

-- ----------------------------------------------------- the retired surface ---
select t.assert_eq((select count(*)::int from information_schema.columns
                     where table_schema = 'public'
                       and table_name in ('student_skills', 'student_skill_events')
                       and column_name in ('score', 'mastery_level', 'confidence', 'delta')), 0,
  '8a. the retired columns are gone');

select t.assert_eq((select count(*)::int from pg_type t
                     join pg_namespace n on n.oid = t.typnamespace
                    where n.nspname = 'app'
                      and t.typname in ('mastery_level', 'confidence_level')), 0,
  '8b. the retired enums are gone');

select t.assert_eq((select count(*)::int from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_results'
                       and column_name = 'confidence'), 0,
  '8c. and the conflated column is gone from assessment_results too');

-- ------------------------------------------------- they cannot come back -----
do $$
declare v_err text;
begin
  alter table public.student_skills add column score numeric(5,2);
  begin
    perform app.assert_schema_invariants();
    v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  alter table public.student_skills drop column score;
  perform t.assert_eq(v_err, 'REFUSED', '9a. re-adding score fails the invariants');
end $$;

do $$
declare v_err text;
begin
  alter table public.student_skill_events add column percentage numeric(5,2);
  begin
    perform app.assert_schema_invariants();
    v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  alter table public.student_skill_events drop column percentage;
  perform t.assert_eq(v_err, 'REFUSED', '9b. and so does a synonym on the events table');
end $$;

do $$
declare v_err text;
begin
  -- refresh_suggested is an advisory signal. A state column that can hold it is
  -- a signal that will eventually downgrade a child.
  alter type app.skill_state add value 'refresh_suggested';
  begin
    perform app.assert_schema_invariants();
    v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  perform t.assert_eq(v_err, 'REFUSED',
    '9c. adding refresh_suggested to the state enum fails the invariants');
end $$;

-- =============================================================================
-- 10. Phase 3 carried every legacy state forward without reclassifying anybody
-- =============================================================================
-- The failure this guards against: a legacy row holds a state a person typed,
-- with no events underneath it, because the profile predates the idea that a
-- state comes from evidence. The first recompute finds nothing and computes
-- `unknown`. Without the carry-forward in 0084 that is a machine erasing a
-- parent's record on the strength of having no information.

select t.assert_eq(
  (select count(*)::int from mig_profile_snapshot where skill_state <> 'unknown'),
  (select count(*)::int from mig_profile_snapshot
    where skill_state <> 'unknown' and active_override_id is not null
      and override_state = skill_state),
  '10a. every legacy state that said something became a linked human decision');

select t.assert_eq(
  (select count(*)::int from public.student_skill_overrides
    where status = 'active' and carried_forward),
  (select count(*)::int from mig_profile_snapshot where skill_state <> 'unknown'),
  '10b. one carried decision per state, and none invented for a state nobody set');

select t.assert_eq(
  (select count(*)::int from mig_profile_snapshot where computed_state <> 'unknown'),
  0, '10c. while no computed state was invented for rows that have no evidence');

-- The point of the carry-forward, proved rather than asserted. Not every legacy
-- row is evidence-free - the seed gives one of them events, and that one
-- computes `emerging` on its own. What must hold for all of them is that the
-- computation never silently replaces what a person recorded with something
-- lower, and that at least one row would have lost its state outright.
do $$
declare r record; v jsonb; v_checked int := 0; v_would_have_lost int := 0;
begin
  for r in select student_id, skill_id, skill_state from mig_profile_snapshot
            where skill_state <> 'unknown' loop
    v := app.compute_skill_state(r.student_id, r.skill_id);
    perform t.assert(
      (v->>'computed_state')::app.skill_state <= r.skill_state,
      '10d. evidence never characterizes a carried row higher than the person did ('
        || r.skill_state::text || ' vs ' || (v->>'computed_state') || ')');
    if (v->>'computed_state') = 'unknown' then
      v_would_have_lost := v_would_have_lost + 1;
    end if;
    v_checked := v_checked + 1;
  end loop;
  perform t.assert(v_checked >= 4,
    '10e. and enough carried rows existed for that to mean something');
  perform t.assert(v_would_have_lost >= 1,
    '10f. at least one state would have been erased outright without the carry-forward');
end $$;

select t.assert_eq(
  (select count(*)::int from public.student_skill_overrides
    where carried_forward and decided_by is null),
  (select count(*)::int from public.student_skill_overrides o
    join public.student_skills ss on ss.id = o.student_skill_id
   where o.carried_forward
     and coalesce(ss.human_confirmed_by, ss.entered_by, ss.created_by, ss.updated_by) is null),
  '10g. rows that named nobody are carried anonymously rather than attributed to a guardian');

-- =============================================================================
-- 11. The 0096-0097 provenance correction, over the rows seeded before it ran
-- =============================================================================
-- Phase 5 routing is deterministic. Evidence that came out of it was being
-- labelled `human_confirmed_ai_proposal`, which told a parent - and any
-- evaluator reading her portfolio - that a model had proposed something about
-- her child when no model was ever consulted.

select t.assert_eq(
  (select record_provenance::text from public.student_skill_events
    where evidence_note = 'MIGTEST diagnostic mislabelled'),
  'human_confirmed_system_observation',
  '11a. diagnostic evidence a person confirmed is a confirmed SYSTEM observation');

select t.assert_eq(
  (select record_provenance::text from public.student_skill_events
    where evidence_note = 'MIGTEST portfolio ai confirmed'),
  'human_confirmed_ai_proposal',
  '11b. and a genuine confirmed AI proposal from elsewhere was left alone');

select t.assert_eq(
  (select evidence_source::text from public.student_skill_events
    where evidence_note = 'MIGTEST diagnostic mislabelled'),
  'diagnostic_session',
  '11c. the source is untouched - only the claim about who proposed it moved');

select t.assert_eq(
  (select skill_state::text from public.student_skill_events
    where evidence_note = 'MIGTEST diagnostic mislabelled'),
  'developing',
  '11d. and what the observation says about the child is untouched');

-- The relabelled row must still count toward the profile. If 0097 had changed
-- the label without teaching app.compute_skill_state about it, this evidence
-- would have stopped counting as human-origin and the child's sufficiency would
-- have quietly dropped.
do $$
declare v jsonb; r record;
begin
  select ss.student_id, ss.skill_id into r from public.student_skills ss
   where ss.notes = 'MIGTEST diagnostic profile';
  v := app.compute_skill_state(r.student_id, r.skill_id);
  perform t.assert_eq((v->>'usable_evidence_count')::int, 1,
    '11e. the relabelled observation is still usable evidence');
  perform t.assert_eq(
    (v->'sufficiency_inputs'->>'human_entered_or_confirmed')::int, 1,
    '11f. and still counts as an observation a person stands behind');
  perform t.assert_eq(v->>'rule_version', '2026-09-09.2',
    '11g. under the same rule version - nothing about the child was recomputed');
end $$;

-- The old label is unreachable for diagnostic evidence, not merely unwritten.
do $$
declare r record;
begin
  select ss.id, ss.student_id, ss.skill_id into r from public.student_skills ss
   where ss.notes = 'MIGTEST diagnostic profile';
  begin
    insert into public.student_skill_events
      (student_skill_id, student_id, skill_id, occurred_on, evidence_note, skill_state,
       source_type, evidence_source, record_provenance, created_by)
    values (r.id, r.student_id, r.skill_id, current_date, 'MIGTEST refused', 'developing',
            'observation', 'diagnostic_session', 'human_confirmed_ai_proposal',
            '11111111-1111-4111-8111-000000000001');
    raise exception
      'ASSERTION FAILED: 11h. diagnostic evidence was accepted as a confirmed AI proposal';
  exception when check_violation then null;
  end;
end $$;

select t.assert(true, '--- migration regression complete ---');
