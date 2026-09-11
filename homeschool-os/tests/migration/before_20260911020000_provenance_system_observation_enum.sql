-- =============================================================================
-- Rows for the 0096-0097 provenance regression, seeded just before they run
-- =============================================================================
-- These rows cannot come from the legacy seed: at 0080 there is no
-- `record_provenance`, no `evidence_source` and no diagnostic anything. They are
-- written here, against the post-0095 schema, to represent what a database
-- looks like if Phase 5 ran for a while before the provenance was corrected.
--
-- Both databases hold zero diagnostic evidence today, so without this file the
-- backfill in 0097 would touch nothing and the test would pass while proving
-- nothing at all. That is exactly how 0081's suspended-trigger bug survived
-- until somebody ran it over rows.
--
-- TWO ROWS, and the second is the control:
--
--   MIGTEST diagnostic mislabelled     came out of a diagnostic session and
--                                      claims a model proposed it. Must be
--                                      relabelled.
--   MIGTEST portfolio ai confirmed     a genuine confirmed AI proposal from
--                                      somewhere else entirely. Must be left
--                                      exactly as it is.
-- =============================================================================

\set LUCAS '44444444-4444-4444-8444-00000000000d'
\set CARLA '11111111-1111-4111-8111-000000000001'

insert into public.skills (id, subject_id, code, name, description)
values ('cccccccc-0000-4000-8000-000000000007', 'cccccccc-0000-4000-8000-0000000000ff',
        'MIGTEST.S7', 'MIGTEST skill 7', 'MIGTEST'),
       ('cccccccc-0000-4000-8000-000000000008', 'cccccccc-0000-4000-8000-0000000000ff',
        'MIGTEST.S8', 'MIGTEST skill 8', 'MIGTEST');

insert into public.student_skills
  (student_id, skill_id, source_type, record_provenance, evidence_source,
   skill_state, notes, created_by)
values (:'LUCAS', 'cccccccc-0000-4000-8000-000000000007', 'observation',
        'human_entered', 'diagnostic_session', 'unknown',
        'MIGTEST diagnostic profile', :'CARLA'),
       (:'LUCAS', 'cccccccc-0000-4000-8000-000000000008', 'observation',
        'human_entered', 'portfolio_artifact', 'unknown',
        'MIGTEST portfolio profile', :'CARLA');

insert into public.student_skill_events
  (student_skill_id, student_id, skill_id, occurred_on, evidence_note, skill_state,
   source_type, evidence_source, record_provenance, created_by)
select ss.id, ss.student_id, ss.skill_id, date '2026-09-01',
       'MIGTEST diagnostic mislabelled', 'developing', 'observation',
       'diagnostic_session', 'human_confirmed_ai_proposal', :'CARLA'
  from public.student_skills ss where ss.notes = 'MIGTEST diagnostic profile';

insert into public.student_skill_events
  (student_skill_id, student_id, skill_id, occurred_on, evidence_note, skill_state,
   source_type, evidence_source, record_provenance, created_by)
select ss.id, ss.student_id, ss.skill_id, date '2026-09-02',
       'MIGTEST portfolio ai confirmed', 'developing', 'observation',
       'portfolio_artifact', 'human_confirmed_ai_proposal', :'CARLA'
  from public.student_skills ss where ss.notes = 'MIGTEST portfolio profile';

do $seed$
declare v_n int;
begin
  select count(*) into v_n from public.student_skill_events
   where record_provenance = 'human_confirmed_ai_proposal'
     and evidence_note like 'MIGTEST%';
  if v_n <> 2 then
    raise exception 'the provenance regression seeded % rows, not 2', v_n;
  end if;
end $seed$;
