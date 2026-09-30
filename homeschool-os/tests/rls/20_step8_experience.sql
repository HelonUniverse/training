-- =============================================================================
-- STEP 8 phase 2 - the learning experience, and what happened
-- =============================================================================
-- Every block is rolled back. Rows are marked P9.
--
-- The tests that matter most are 13-21 (nothing a child DOES becomes a claim
-- about her), 22-24 (the evidence bridge is a question a person answers, and
-- accepting it still does not move the profile), 11-12 (a morning that happened
-- stays on the record), and G1-G12, which prove the guards are alive by
-- breaking them one at a time.
-- =============================================================================

\set CARLA '11111111-1111-4111-8111-000000000001'
\set PEDRO '11111111-1111-4111-8111-000000000002'
\set DIEGO '11111111-1111-4111-8111-000000000003'
\set TOMAS '11111111-1111-4111-8111-000000000005'
\set LUCASU '11111111-1111-4111-8111-000000000009'
\set LUCAS '44444444-4444-4444-8444-00000000000d'

-- --- helpers -----------------------------------------------------------------

create or replace function t.p9_state(p_student uuid, p_code text, p_state text,
                                      p_suff text, p_actor uuid)
returns void language plpgsql as $$
declare v_sk uuid; v_org uuid;
begin
  select id into v_sk from public.skills where code = p_code;
  select primary_organization_id into v_org from public.students where id = p_student;
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, evidence_sufficiency,
           usable_evidence_count, created_by)
  values (p_student, v_sk, v_org, 'manual', 'human_entered', 'parent',
          p_state::app.skill_state, p_suff::app.evidence_sufficiency, 2, p_actor);
end $$;

create or replace function t.p9_confirm(p_code text, p_actor uuid)
returns void language plpgsql as $$
begin
  update public.resource_skills rs
     set confirmed = true, confirmed_by = p_actor, confirmed_at = now()
   where rs.skill_id = (select id from public.skills where code = p_code);
end $$;

-- An approved path for Lucas, opening at NST.FR.3, with material confirmed and
-- an activity already selected. This is the state every execution test starts
-- from, built through the real Phase 6 and Phase 1 calls rather than by
-- inserting rows.
create or replace function t.p9_ready(p_actor uuid)
returns uuid language plpgsql as $$
declare v_path uuid; v_node uuid; j jsonb;
begin
  perform t.logout();
  perform t.p9_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported', p_actor);
  perform t.p9_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported', p_actor);
  perform t.p9_confirm('NST.FR.3', p_actor);
  perform t.login(p_actor);
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.1'), 4, 'P9');
  v_path := (j->>'path')::uuid;
  perform public.approve_learning_path(v_path, 'P9 yes');
  select n.id into v_node from public.learning_path_nodes n
    join public.skills k on k.id = n.skill_id
   where n.path_id = v_path and k.code = 'NST.FR.3' and n.status <> 'removed';
  j := public.select_activity_for_node(v_node);
  perform t.logout();
  return (j->>'activity_id')::uuid;
end $$;

-- A stored document, through the machinery that already exists.
create or replace function t.p9_document(p_student uuid, p_actor uuid, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid; v_fam uuid;
begin
  select family_id into v_fam from public.students where id = p_student;
  insert into public.documents (student_id, family_id, uploaded_by, storage_path,
           original_filename, mime_type, byte_size, sha256, title, scan_status)
  values (p_student, v_fam, p_actor, 'p9/' || p_name, p_name, 'image/jpeg',
          1024, encode(sha256(p_name::bytea), 'hex'), p_name, 'clean')
  returning id into v_id;
  return v_id;
end $$;

grant execute on function t.p9_state(uuid, text, text, text, uuid) to authenticated;
grant execute on function t.p9_confirm(text, uuid) to authenticated;
grant execute on function t.p9_ready(uuid) to authenticated;
grant execute on function t.p9_document(uuid, uuid, text) to authenticated;

-- =============================================================================
-- 1-4. Today is derived, and it derives the right things
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.logout();

  perform t.assert((j->>'count')::int >= 1, '1a. an approved path with a selected activity puts something in Today');
  perform t.assert_eq(j->'items'->0->>'why', 'approved_learning_path',
    '1b. and it says the reason is the path she approved');
  perform t.assert_eq(j->'items'->0->>'activity_id', v_act::text,
    '1c. which is the activity Phase 1 selected');
  perform t.assert_eq((j->>'is_a_checklist')::boolean, false,
    '2a. Today says of itself that it is not a checklist');
  perform t.assert_eq((j->>'anything_overdue')::boolean, false,
    '2b. and that nothing in it is overdue');
  perform t.assert_eq((j->>'membership_is_evidence')::boolean, false,
    '2c. and that being in it is not evidence');

  -- 3. No second plan. Today holds nothing of its own until a person decides
  -- something, and even then it holds only the decision.
  select count(*)::int into v_n from public.today_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0,
    '3a. Today needed no rows of its own to exist: it is a reading of the record');

  -- 4. A goal target is not presented as the next thing to do.
  select count(*)::int into v_n
    from app.today_items('44444444-4444-4444-8444-00000000000d') t
    join public.learning_path_nodes n on n.id =
         (select a.path_node_id from public.learning_activities a where a.id = t.activity_id)
   where n.node_kind = 'goal_target';
  perform t.assert_eq(v_n, 0, '4a. no goal target is shown as something to do today');
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_own uuid; j jsonb; v_first text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  -- Her own activity, with no resource at all.
  v_own := (public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'),
        'P9 measuring cups in the kitchen', 'manipulative', 'hands_on', 'en',
        'Use the 1/2 and 1/4 cups.', 'Fill them and see.', 15)->>'activity_id')::uuid;
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq((j->>'count')::int, 2, '5a. her own activity is in Today too');

  -- Pinning moves it to the front, and that is a person deciding, not a rule.
  perform public.pin_for_today(v_own, 'P9 do this one first');
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq(j->'items'->0->>'activity_id', v_own::text,
    '5b. pinning it puts it first');
  perform t.assert_eq((j->'items'->0->>'pinned')::boolean, true, '5c. and says so');

  -- Hiding takes it off for today and leaves it entirely alone otherwise.
  perform public.hide_for_today(v_own, 'P9 not this one today');
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq((j->>'count')::int, 1, '6a. hiding it takes it off today');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_own),
    'selected', '6b. and does not touch the activity itself');

  -- Tomorrow it is back, because a decision about today was about today.
  j := public.today('44444444-4444-4444-8444-00000000000d', current_date + 1);
  perform t.assert_eq((j->>'count')::int, 2,
    '6c. and tomorrow it is back, because hiding was about today');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 7-12. A morning: start, pause, come back, finish
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_sess uuid; v_sess2 uuid; v_n int; v_status text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');

  j := public.start_learning_session(v_act, 'P9 Tuesday');
  v_sess := (j->>'session_id')::uuid;
  perform t.assert_eq(j->>'status', 'in_progress', '7a. a session starts');
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '7b. and creates no evidence');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'started', '7c. the activity follows it into started');

  -- Opening the screen again does not start a second one.
  j := public.start_learning_session(v_act);
  perform t.assert_eq((j->>'session_id')::uuid, v_sess,
    '8a. opening it again continues the same occasion rather than starting a second');
  perform t.assert_eq((j->>'already_open')::boolean, true, '8b. and says so');

  -- The baby wakes up.
  j := public.pause_learning_session(v_sess, 'P9 the baby woke up');
  perform t.assert_eq((j->>'paused')::boolean, true, '9a. it can be set down');

  -- Thursday.
  j := public.start_learning_session(v_act);
  perform t.assert_eq((j->>'resumed')::boolean, true, '9b. and picked back up two days later');
  perform t.assert_eq((j->>'session_id')::uuid, v_sess, '9c. as the same occasion');

  j := public.end_learning_session(v_sess, 'completed', 25, 'P9 she got it');
  perform t.assert_eq((j->>'ended')::boolean, true, '10a. and finished');
  perform t.assert_eq((j->>'outcome'), 'completed', '10b. with an outcome');
  perform t.assert_eq((j->>'mastery_implied')::boolean, false,
    '10c. which implies nothing at all about mastery');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'completed', '10d. and the activity is completed too');

  -- 11. That morning is on the record and stays there.
  j := public.end_learning_session(v_sess, 'stopped');
  perform t.assert_eq((j->>'ended')::boolean, false,
    '11a. the same occasion cannot be ended twice');
  perform t.assert_eq(j->>'reason', 'this_occasion_is_already_on_the_record',
    '11b. and says why');
  perform t.assert_eq((select outcome::text from public.learning_activity_sessions where id = v_sess),
    'completed', '11c. and the outcome it was given stands');

  -- 12. She does it again next week. That is a NEW occasion.
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  update public.learning_activities set status = 'archived', closed_at = now()
   where id = v_act;
  perform t.logout();
  select count(*)::int into v_n from public.learning_activity_sessions where activity_id = v_act;
  perform t.assert_eq(v_n, 1, '12a. one occasion is recorded, not one overwritten twice');
  select status::text into v_status from public.learning_activity_sessions where id = v_sess;
  perform t.assert_eq(v_status, 'ended', '12b. and it is still ended');
end $$;
rollback;

-- =============================================================================
-- 13-18. Nothing a child does becomes a claim about her
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_sess uuid; v_doc uuid; v_art uuid;
        v_ev0 int; v_ev int; v_st0 text; v_st text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');

  select count(*)::int into v_ev0 from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  select string_agg(k.code || '=' || s.skill_state::text, ',' order by k.code) into v_st0
    from public.student_skills s join public.skills k on k.id = s.skill_id
   where s.student_id = '44444444-4444-4444-8444-00000000000d';

  perform t.login('11111111-1111-4111-8111-000000000001');
  -- being in Today
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq((j->>'membership_is_evidence')::boolean, false, '13a. Today membership is not evidence');
  -- opening the material
  j := public.open_activity_resource(v_act);
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '14a. opening a resource creates no evidence');
  perform t.assert_eq((j->>'mastery_implied')::boolean, false, '14b. and implies no mastery');
  -- starting
  j := public.start_learning_session(v_act);
  v_sess := (j->>'session_id')::uuid;
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '15a. starting creates no evidence');
  -- a note
  j := public.add_session_note(v_sess, 'P9 she liked the paper strips');
  perform t.assert_eq((j->>'mastery_implied')::boolean, false, '16a. a note is not mastery');
  -- an artifact
  perform t.logout();
  v_doc := t.p9_document('44444444-4444-4444-8444-00000000000d',
                         '11111111-1111-4111-8111-000000000001', 'p9-worksheet.jpg');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.attach_activity_artifact(v_act, v_doc, null, v_sess, 'P9 the page she did');
  v_art := (j->>'artifact_id')::uuid;
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '17a. attaching a photo creates no evidence');
  perform t.assert_eq((j->>'mastery_implied')::boolean, false, '17b. and is not mastery');
  -- finishing
  j := public.end_learning_session(v_sess, 'completed', 30);
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '18a. finishing creates no evidence');
  perform t.assert_eq((j->>'skill_state_changed')::boolean, false, '18b. and moves no state');
  perform t.logout();

  select count(*)::int into v_ev from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_ev, v_ev0,
    '18c. after all of it, not one piece of evidence was added');
  select string_agg(k.code || '=' || s.skill_state::text, ',' order by k.code) into v_st
    from public.student_skills s join public.skills k on k.id = s.skill_id
   where s.student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_st, v_st0, '18d. and every skill state is exactly what it was');
end $$;
rollback;

-- =============================================================================
-- 19-24. The evidence offer is a question, and answering it does not move the profile
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_sess uuid; v_doc uuid; v_art uuid; v_prop uuid;
        v_ev uuid; v_le0 int; v_le int; v_sse0 int; v_sse int; v_st0 text; v_st text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  v_doc := t.p9_document('44444444-4444-4444-8444-00000000000d',
                         '11111111-1111-4111-8111-000000000001', 'p9-evidence.jpg');
  select count(*)::int into v_le0 from public.learning_evidence
   where student_id = '44444444-4444-4444-8444-00000000000d';
  select count(*)::int into v_sse0 from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  select string_agg(k.code || '=' || s.skill_state::text, ',' order by k.code) into v_st0
    from public.student_skills s join public.skills k on k.id = s.skill_id
   where s.student_id = '44444444-4444-4444-8444-00000000000d';

  perform t.login('11111111-1111-4111-8111-000000000001');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  v_art := (public.attach_activity_artifact(v_act, v_doc, null, v_sess)->>'artifact_id')::uuid;
  perform public.end_learning_session(v_sess, 'completed', 20);

  -- 19. Finishing did NOT create an offer on its own. Nestra asks only when a
  -- person asks it to; a screen that offers is still a screen, not a record.
  perform t.assert_eq(
    (select count(*)::int from public.learning_evidence_proposals where activity_id = v_act), 0,
    '19a. completing an activity does not create an evidence proposal by itself');

  j := public.offer_activity_evidence(v_act, null, v_sess, v_art, 'P9 worth keeping?');
  v_prop := (j->>'proposal_id')::uuid;
  perform t.assert_eq((j->>'is_a_question_not_a_record')::boolean, true,
    '20a. an offer says of itself that it is a question');
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '20b. and creates no evidence');
  select count(*)::int into v_le from public.learning_evidence
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_le, v_le0, '20c. nothing was written to the evidence record');

  -- 21. Asking twice does not stack up questions.
  j := public.offer_activity_evidence(v_act, null, v_sess, v_art);
  perform t.assert_eq((j->>'offered')::boolean, false, '21a. asking again does not ask again');
  perform t.assert_eq(j->>'reason', 'already_asked', '21b. and says so');

  -- 22. A person says yes. Evidence is recorded - through the STEP 5 function.
  j := public.accept_evidence_proposal(v_prop, 'demonstrates', 'P9 she showed me');
  v_ev := (j->>'learning_evidence_id')::uuid;
  perform t.assert_eq((j->>'accepted')::boolean, true, '22a. a person may accept the offer');
  perform t.assert(v_ev is not null, '22b. and evidence is recorded');
  perform t.assert_eq((j->>'evidence_recorded')::boolean, true, '22c. the payload says evidence was recorded');
  perform t.assert_eq((j->>'profile_updated')::boolean, false, '22d. and that the profile was not');
  perform t.assert_eq((j->>'mastery_implied')::boolean, false, '22e. and that nothing is implied about mastery');
  perform t.assert_eq(
    (select source_type::text from public.learning_evidence where id = v_ev), 'parent',
    '22f. the evidence row was made by the existing STEP 5 path, as a parent record');
  perform t.assert(
    (select confirmed_by from public.learning_evidence where id = v_ev) is not null,
    '22g. and names the person who confirmed it');
  perform t.logout();

  -- 23. THE LINE. Evidence exists; the profile has not moved.
  select count(*)::int into v_sse from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_sse, v_sse0,
    '23a. accepting evidence wrote nothing to student_skill_events');
  select string_agg(k.code || '=' || s.skill_state::text, ',' order by k.code) into v_st
    from public.student_skills s join public.skills k on k.id = s.skill_id
   where s.student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_st, v_st0, '23b. and every skill state is unchanged');

  -- 24. An answer is given once.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.accept_evidence_proposal(v_prop);
  perform t.assert_eq((j->>'accepted')::boolean, false, '24a. an answered offer is not answered again');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare v_act uuid; j jsonb; v_prop uuid; v_le0 int; v_le int; v_sse0 int; v_sse int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select count(*)::int into v_le0 from public.learning_evidence
   where student_id = '44444444-4444-4444-8444-00000000000d';
  select count(*)::int into v_sse0 from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';

  perform t.login('11111111-1111-4111-8111-000000000001');
  v_prop := (public.offer_activity_evidence(v_act)->>'proposal_id')::uuid;
  j := public.decline_evidence_proposal(v_prop, 'P9 that was just practice');
  perform t.logout();

  perform t.assert_eq((j->>'declined')::boolean, true, '25a. "that was just practice" is an answer');
  select count(*)::int into v_le from public.learning_evidence
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_le, v_le0, '25b. and a declined offer writes no evidence');
  select count(*)::int into v_sse from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_sse, v_sse0, '25c. and touches no profile');
  perform t.assert(
    (select learning_evidence_id from public.learning_evidence_proposals where id = v_prop) is null,
    '25d. and points at no evidence, because none was created');
  perform t.assert_eq(
    (select decline_note from public.learning_evidence_proposals where id = v_prop),
    'P9 that was just practice',
    '25e. and her reason is kept, so she is not asked the same thing forever');
end $$;
rollback;

-- =============================================================================
-- 26-28. Choosing something different is an explicit act
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_new uuid; v_before text; v_after text; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');

  -- Reloading the screen. Nothing moves.
  v_before := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform public.today('44444444-4444-4444-8444-00000000000d');
  perform public.today('44444444-4444-4444-8444-00000000000d');
  v_after := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform t.assert_eq(v_after, v_before,
    '26a. opening Today three times does not quietly change what is in it');
  perform t.assert_eq(
    (select count(*)::int from public.learning_activities
      where student_id = '44444444-4444-4444-8444-00000000000d' and status = 'replaced'), 0,
    '26b. and replaces nothing');

  -- She chooses something different. That is a call she makes.
  j := public.replace_activity_resource(v_act, 'dddddddd-0000-4000-8000-000000000005',
                                        null, 'P9 she would rather watch it');
  v_new := (j->>'activity_id')::uuid;
  perform t.logout();

  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'replaced', '27a. the first one is set aside');
  perform t.assert_eq((select replaces_activity_id from public.learning_activities where id = v_new),
    v_act, '27b. and the new one names what it replaced');
  perform t.assert_eq(
    (select skill_id from public.learning_activities where id = v_new),
    (select skill_id from public.learning_activities where id = v_act),
    '27c. the target skill did not move');
  perform t.assert_eq(
    (select replacement_note from public.learning_activities where id = v_act),
    'P9 she would rather watch it', '27d. and her reason is kept');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.logout();
  perform t.assert_eq((j->>'count')::int, 1, '28a. Today shows the replacement, not both');
  perform t.assert_eq(j->'items'->0->>'activity_id', v_new::text, '28b. and it is the new one');
end $$;
rollback;

-- =============================================================================
-- 29-31. A whole learning experience with nothing to open
-- =============================================================================

begin;
do $$
declare v_own uuid; j jsonb; v_sess uuid; v_doc uuid; v_prop uuid; v_sse0 int; v_sse int;
begin
  perform t.logout();
  select count(*)::int into v_sse0 from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.login('11111111-1111-4111-8111-000000000001');
  v_own := (public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'),
        'P9 find three things in the kitchen and compare them',
        'manipulative', 'hands_on', 'en',
        'Cups, a jug and a spoon.', 'Which is half of which?', 20)->>'activity_id')::uuid;

  perform t.assert(
    (select resource_id from public.learning_activities where id = v_own) is null,
    '29a. it has no resource at all');
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq((j->>'count')::int, 1, '29b. and it appears in Today anyway');
  perform t.assert_eq(j->'items'->0->'launch'->>'launch_kind', 'no_digital_resource',
    '29c. and says plainly that there is nothing to open');
  perform t.assert_eq(j->'items'->0->>'instructions', 'Which is half of which?',
    '29d. carrying the instructions a person wrote instead');

  -- and the entire experience runs
  v_sess := (public.start_learning_session(v_own)->>'session_id')::uuid;
  perform public.pause_learning_session(v_sess, 'P9 lunch');
  perform public.start_learning_session(v_own);
  perform public.add_session_note(v_sess, 'P9 she used the measuring jug');
  perform t.logout();
  v_doc := t.p9_document('44444444-4444-4444-8444-00000000000d',
                         '11111111-1111-4111-8111-000000000001', 'p9-kitchen.jpg');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.attach_activity_artifact(v_own, v_doc, null, v_sess, 'P9 the cups lined up');
  j := public.end_learning_session(v_sess, 'completed', 20, 'P9 we had fun');
  perform t.assert_eq((j->>'ended')::boolean, true,
    '30a. a kitchen activity starts, pauses, resumes, takes a note, takes a photo and finishes');
  v_prop := (public.offer_activity_evidence(v_own)->>'proposal_id')::uuid;
  perform t.assert(v_prop is not null, '30b. and can be offered as evidence like any other');
  perform t.logout();

  select count(*)::int into v_sse from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_sse, v_sse0,
    '31a. and none of it wrote anything to the profile');
end $$;
rollback;

-- =============================================================================
-- 32-34. Duration is reported, never invented
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_sess uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  -- A session that has been open since first thing this morning, ended with no
  -- reported time. Inserted with its real start rather than back-dated, because
  -- the guard rightly refuses moving when an occasion happened - which is
  -- itself worth knowing, and is asserted in G10.
  perform t.logout();
  insert into public.learning_activity_sessions (activity_id, student_id, started_at, initiated_by)
  values (v_act, '44444444-4444-4444-8444-00000000000d', now() - interval '14 hours',
          '11111111-1111-4111-8111-000000000001')
  returning id into v_sess;
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.end_learning_session(v_sess, 'completed');
  perform t.logout();
  perform t.assert(
    (select duration_minutes from public.learning_activity_sessions where id = v_sess) is null,
    '32a. a session left open for fourteen hours does not record fourteen hours');
  perform t.assert_eq((j->>'duration_was_measured')::boolean, false,
    '32b. and says plainly that nobody measured it');
  perform t.assert(j->>'duration_minutes' is null, '32c. rather than guessing a number');
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'explored', 12);
  perform t.logout();
  perform t.assert_eq(
    (select duration_minutes from public.learning_activity_sessions where id = v_sess), 12,
    '33a. a reported duration is kept exactly');
  perform t.assert_eq(
    (select outcome::text from public.learning_activity_sessions where id = v_sess), 'explored',
    '33b. and exploring for twelve minutes is an outcome, not a shortfall');
  -- exploring did NOT complete the activity, because it did not.
  perform t.assert(
    (select status::text from public.learning_activities where id = v_act) <> 'completed',
    '34a. exploring does not mark the activity completed, because it was not');
end $$;
rollback;

-- =============================================================================
-- 35-38. Standards, grade and age decide nothing about a morning
-- =============================================================================

begin;
do $$
declare v_act uuid; a text; b text; c text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  a := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform t.logout();

  alter table public.standards       rename to standards_hidden_p9;
  alter table public.skill_standards rename to skill_standards_hidden_p9;
  perform t.login('11111111-1111-4111-8111-000000000001');
  b := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform t.logout();
  perform t.assert_eq(b, a,
    '35a. with the standards catalogue renamed away, Today is identical');
  alter table public.standards_hidden_p9       rename to standards;
  alter table public.skill_standards_hidden_p9 rename to skill_standards;

  update public.students set grade_level = '1' where id = '44444444-4444-4444-8444-00000000000d';
  perform t.login('11111111-1111-4111-8111-000000000001');
  b := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform t.logout();
  perform t.assert_eq(b, a, '36a. moving her from grade 5 to grade 1 changes nothing');

  update public.students set grade_level = '12', date_of_birth = date '2004-01-01'
   where id = '44444444-4444-4444-8444-00000000000d';
  perform t.login('11111111-1111-4111-8111-000000000001');
  c := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform t.logout();
  perform t.assert_eq(c, a, '37a. and making her twenty-two changes nothing either');

  -- deterministic
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(public.today('44444444-4444-4444-8444-00000000000d')::text,
                      public.today('44444444-4444-4444-8444-00000000000d')::text,
    '38a. and the same question twice gives the same Today');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 39-41. Language: the child's, the material's, and the difference
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_es uuid; v_bi uuid; v_unk uuid;
begin
  perform t.logout();
  perform t.p9_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  v_es  := (public.choose_activity_resource('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code = 'NST.FR.3'),
             'dddddddd-0000-4000-8000-000000000004')->>'activity_id')::uuid;
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq(j->'items'->0->>'language', 'es',
    '39a. a Spanish resource produces a Spanish activity card');

  perform public.hide_for_today(v_es);
  v_bi := (public.choose_activity_resource('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code = 'NST.FR.3'),
             'dddddddd-0000-4000-8000-000000000005')->>'activity_id')::uuid;
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq(j->'items'->0->>'language', 'bilingual',
    '40a. and a bilingual one says bilingual');

  perform public.hide_for_today(v_bi);
  v_unk := (public.choose_activity_resource('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code = 'NST.FR.3'),
             'dddddddd-0000-4000-8000-000000000006')->>'activity_id')::uuid;
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert_eq(j->'items'->0->>'language', 'unknown',
    '41a. and material whose language nobody recorded is never labelled English or Spanish');
  perform t.logout();

  -- language-neutral material is a real answer, not a missing one
  perform t.assert_eq(
    (select language::text from public.learning_resources
      where id = 'dddddddd-0000-4000-8000-000000000001'), 'language_neutral',
    '41b. and a set of paper strips has no language, which is different from unknown');
end $$;
rollback;

-- =============================================================================
-- 42-44. How material is actually opened
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb;
begin
  perform t.logout();
  perform t.p9_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  update public.learning_resources
     set external_url = 'https://example.invalid/demo-page'
   where id = 'dddddddd-0000-4000-8000-000000000005';
  perform t.login('11111111-1111-4111-8111-000000000001');
  v_act := (public.choose_activity_resource('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code = 'NST.FR.3'),
             'dddddddd-0000-4000-8000-000000000005')->>'activity_id')::uuid;
  j := public.open_activity_resource(v_act);
  perform t.logout();

  perform t.assert_eq(j->>'launch_kind', 'external_link',
    '42a. a link to somebody else''s page is called a link to somebody else''s page');
  perform t.assert(j->>'note' like '%not part of Nestra%',
    '42b. and says so in words a family reads');
  perform t.assert_eq((j->>'openable_now')::boolean, true, '42c. and whether it opens today');
  perform t.assert(j->>'license_note' is not null, '42d. and what Nestra may do with it');
  perform t.assert_eq((j->>'evidence_created')::boolean, false,
    '43a. opening it records nothing about the child');

  -- nothing anywhere claims an integration
  perform t.assert_eq(
    (select count(*)::int from public.learning_resources where integration_mode = 'integrated'), 0,
    '44a. nothing in the catalogue claims a live integration, because there is not one');
end $$;
rollback;

-- =============================================================================
-- 45-50. Who may do what
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_sess uuid; v_n int; v_prop uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');

  -- A CHILD may run her own morning.
  perform t.login('11111111-1111-4111-8111-000000000009');
  j := public.today('44444444-4444-4444-8444-00000000000d');
  perform t.assert((j->>'count')::int >= 1, '45a. a child can see her own Today');
  j := public.start_learning_session(v_act, 'P9 me');
  v_sess := (j->>'session_id')::uuid;
  perform t.assert(v_sess is not null, '45b. and start something');
  perform public.add_session_note(v_sess, 'P9 the strips helped');
  j := public.end_learning_session(v_sess, 'completed', 15);
  perform t.assert_eq((j->>'ended')::boolean, true, '45c. and say she has finished');

  -- and may NOT choose her own curriculum, or decide what counts as evidence
  -- about herself.
  begin
    perform public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.3'), 'P9 child invented');
    perform t.assert(false, '46a. a child created her own activity');
  exception when others then
    perform t.assert(true, '46a. a child may not choose her own curriculum');
  end;
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000001');
  v_prop := (public.offer_activity_evidence(v_act)->>'proposal_id')::uuid;
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000009');
  begin
    perform public.accept_evidence_proposal(v_prop);
    perform t.assert(false, '46b. a child decided what counts as evidence about herself');
  exception when others then
    perform t.assert(true, '46b. and may not decide what counts as evidence about herself');
  end;
  perform t.logout();

  -- AN ASSIGNED TEACHER may run the week and may not make that decision either.
  perform t.login('11111111-1111-4111-8111-000000000005');
  select count(*)::int into v_n from public.learning_activity_sessions where id = v_sess;
  perform t.assert_eq(v_n, 1, '47a. an assigned teacher can see the session');
  begin
    perform public.accept_evidence_proposal(v_prop);
    perform t.assert(false, '47b. an assigned teacher decided what enters the evidence record');
  exception when others then
    perform t.assert(true, '47b. and may not decide what enters the family''s evidence record');
  end;
  perform t.logout();

  -- A VIEW-ONLY GUARDIAN reads and does not act.
  perform t.login('11111111-1111-4111-8111-000000000002');
  select count(*)::int into v_n from public.learning_activity_sessions where id = v_sess;
  perform t.assert_eq(v_n, 1, '48a. a view-only guardian can read the session');
  begin
    perform public.start_learning_session(v_act);
    perform t.assert(false, '48b. a view-only guardian started something');
  exception when others then
    perform t.assert(true, '48b. and may not start anything');
  end;
  begin
    perform public.pin_for_today(v_act);
    perform t.assert(false, '48c. a view-only guardian pinned something');
  exception when others then
    perform t.assert(true, '48c. nor decide what today looks like');
  end;
  perform t.logout();

  -- ANOTHER FAMILY sees nothing at all.
  perform t.login('11111111-1111-4111-8111-000000000003');
  select count(*)::int into v_n from public.learning_activity_sessions
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '49a. another family''s guardian sees no sessions');
  select count(*)::int into v_n from public.today_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '49b. nor Today decisions');
  select count(*)::int into v_n from public.learning_activity_artifacts
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '49c. nor artifacts');
  select count(*)::int into v_n from public.learning_evidence_proposals
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '49d. nor evidence offers');
  begin
    perform public.today('44444444-4444-4444-8444-00000000000d');
    perform t.assert(false, '49e. another family''s guardian read that child''s Today');
  exception when others then
    perform t.assert(true, '49e. and cannot ask for that child''s Today at all');
  end;
  perform t.logout();

  -- ANONYMOUS gets nothing, at the grant rather than at the policy.
  begin
    execute 'set local role anon';
    select count(*)::int into v_n from public.learning_activity_sessions;
    perform t.assert(false, '50a. an anonymous caller read sessions');
  exception when others then
    perform t.assert(true, '50a. an anonymous caller is refused at the grant');
  end;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 51-52. The whole story, reconstructable
-- =============================================================================

begin;
do $$
declare v_act uuid; j jsonb; v_sess uuid; v_doc uuid; v_art uuid; v_prop uuid;
        v_kinds text; v_hist_kinds text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  v_doc := t.p9_document('44444444-4444-4444-8444-00000000000d',
                         '11111111-1111-4111-8111-000000000001', 'p9-story.jpg');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.open_activity_resource(v_act);
  v_sess := (public.start_learning_session(v_act, 'P9 Tuesday')->>'session_id')::uuid;
  perform public.pause_learning_session(v_sess, 'P9 the baby');
  perform public.start_learning_session(v_act);
  v_art := (public.attach_activity_artifact(v_act, v_doc, null, v_sess)->>'artifact_id')::uuid;
  perform public.end_learning_session(v_sess, 'completed', 25, 'P9 done');
  v_prop := (public.offer_activity_evidence(v_act, null, v_sess, v_art)->>'proposal_id')::uuid;
  perform public.accept_evidence_proposal(v_prop, 'demonstrates', 'P9 she showed me');
  j := public.activity_history(v_act);
  perform t.logout();

  perform t.assert_eq(jsonb_array_length(j->'sessions'), 1, '51a. one occasion is on the record');
  perform t.assert_eq(j->'sessions'->0->>'outcome', 'completed', '51b. with how it ended');
  perform t.assert_eq((j->'sessions'->0->>'duration_was_measured')::boolean, true,
    '51c. and whether anybody actually measured the time');
  perform t.assert_eq(jsonb_array_length(j->'artifacts'), 1, '51d. the photo is there');
  perform t.assert_eq(j->'evidence_proposals'->0->>'status', 'accepted',
    '51e. the offer and its answer are there');
  perform t.assert(j->'evidence_proposals'->0->>'learning_evidence_id' is not null,
    '51f. pointing at the evidence a person created');
  perform t.assert_eq(j->'activity'->>'origin', 'deterministic_system_selection',
    '51g. and why the activity was chosen in the first place');

  -- ORDER BY SEQ. Everything in this block happens inside one transaction, so
  -- every row shares a created_at unless the log has a real append order - which
  -- is exactly the defect this assertion found.
  select string_agg(e.kind::text, ',' order by e.seq) into v_kinds
    from public.learning_activity_events e where e.activity_id = v_act;
  perform t.assert_eq(v_kinds,
    'selected,resource_opened,session_started,session_paused,session_resumed,artifact_added,session_ended,completed,evidence_offered,evidence_accepted',
    '52a. the whole morning reads back in order, with nothing overwritten');

  -- 52a PROVES THE RAW TABLE ORDERS CORRECTLY. This proves activity_history()
  -- ITSELF reads it that way - not a second function that happens to be
  -- correct while the one the app actually calls has silently reverted to the
  -- pre-fix ordering. That exact regression happened once already: a later
  -- migration file re-defined activity_history without `seq`, clobbering the
  -- fix, and nothing failed until this assertion was added to check the
  -- function's own output rather than only the table underneath it.
  select string_agg(elem->>'kind', ',' order by ord) into v_hist_kinds
    from jsonb_array_elements(j->'events') with ordinality as t(elem, ord);
  perform t.assert_eq(v_hist_kinds, v_kinds,
    '52a2. and activity_history() itself returns that same order - not a stale, unordered copy');

  perform t.assert_eq((j->>'evidence_created_by_doing_any_of_this')::boolean, false,
    '52b. and the history says plainly that none of the doing created evidence');
  perform t.assert_eq((j->>'skill_state_changed_by_doing_any_of_this')::boolean, false,
    '52c. and that none of it moved a state');
end $$;
rollback;

-- =============================================================================
-- 53. Secure stays secure, and no hidden numbers anywhere
-- =============================================================================

begin;
do $$
declare v_sk uuid; v_act uuid; j jsonb; v_sess uuid; v_state text; v_n int;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p9_state('44444444-4444-4444-8444-00000000000d','NST.FR.3','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p9_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
                                          'secure', 'P9 she has this');
  v_act := (public.choose_activity_resource('44444444-4444-4444-8444-00000000000d', v_sk,
             'dddddddd-0000-4000-8000-000000000005', null, 'P9 one more look')->>'activity_id')::uuid;
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'completed', 10);
  perform t.logout();

  select s.skill_state::text into v_state from public.student_skills s
   where s.student_id = '44444444-4444-4444-8444-00000000000d' and s.skill_id = v_sk;
  perform t.assert_eq(v_state, 'secure',
    '53a. working through a confirmed-secure skill again leaves it secure');
  select count(*)::int into v_n from public.student_skill_refresh_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '53b. and creates no refresh requirement');
end $$;
rollback;

select t.assert_eq(
  (select count(*)::int from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name in ('today_decisions','learning_activity_sessions',
                           'learning_activity_artifacts','learning_evidence_proposals')
      and c.column_name ~ '(score|percent|mastery|grade_level|rank|ability)'),
  0, '54a. no hidden score or mastery number anywhere in the experience layer');

select t.assert_eq(
  (select count(*)::int from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name in ('students','profiles','student_skills',
                           'learning_activity_sessions','today_decisions')
      and c.column_name ~ '(learning_style|learner_type|modality)'),
  0, '54b. and no column anywhere says a child IS a kind of learner');

select t.assert_eq(
  (select count(*)::int from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name in ('today_decisions','learning_activity_sessions',
                           'learning_activity_artifacts','learning_evidence_proposals',
                           'learning_activity_change_requests')
      -- `late(?!r)` rather than bare `late`, because learning_activity_sessions
      -- legitimately has `revisit_later` - a wish about NEXT time, nothing to
      -- do with a deadline - and a bare substring match flagged it. Same fix
      -- as the one `\mability\M` already needed for `availability` elsewhere
      -- in this suite: a real word inside another word is not an instance of
      -- the concept being banned.
      and c.column_name ~ '(due|overdue|late(?!r)|failed|missed)'),
  0, '54c. and nothing in it can be late');

-- =============================================================================
-- G1-G12. The guards, proved alive by breaking them
-- =============================================================================
-- Each block writes the exact violation the invariant exists to catch, checks
-- that app.assert_schema_invariants() refuses it, and rolls the damage back.
-- Every match pattern comes ONLY from the invariant's own message, so a guard
-- that has gone dead fails the test instead of passing by accident.

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.explain_today_item(p_activity uuid, p_on date default current_date)
    returns jsonb language plpgsql stable security invoker set search_path = '' as $body$
    begin
      return (select to_jsonb(s.code) from public.standards s limit 1);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G1. the invariants accepted a Today function reading the standards catalogue');
  exception when others then
    perform t.assert(sqlerrm like '%measuring cups%',
      'G1. a Today function that reads the standards catalogue is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.explain_today_item(p_activity uuid, p_on date default current_date)
    returns jsonb language plpgsql stable security invoker set search_path = '' as $body$
    begin
      return (select to_jsonb(st.date_of_birth) from public.students st limit 1);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G2. the invariants accepted a Today function reading a birthday');
  exception when others then
    perform t.assert(sqlerrm like '%at nine and at fourteen%',
      'G2. a Today function that routes on grade or age is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.add_session_note(p_session uuid, p_child_note text default null,
                                                       p_educator_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      insert into public.student_skill_events (student_skill_id) values (null);
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G3. the invariants accepted a session note writing evidence');
  exception when others then
    perform t.assert(sqlerrm like '%the gap between them is a person%',
      'G3. an experience function that writes to the profile is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.explain_today_item(p_activity uuid, p_on date default current_date)
    returns jsonb language plpgsql stable security invoker set search_path = '' as $body$
    declare v app.skill_state;
    begin
      select s.skill_state into v from public.student_skills s limit 1;
      return to_jsonb(v);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G4. the invariants accepted Today reading a computed state');
  exception when others then
    perform t.assert(sqlerrm like '%a fact about a morning%',
      'G4. an experience function that names a child''s computed state is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.pin_for_today(p_activity uuid, p_note text default null,
                                                    p_on date default current_date)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      update public.learning_path_nodes set position = position + 1 where false;
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G5. the invariants accepted Today editing the learning path');
  exception when others then
    perform t.assert(sqlerrm like '%Today reads the plan%',
      'G5. an experience function that rewrites the learning path is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  -- The loop that must not exist: evidence naming the morning it came out of.
  alter table public.student_skill_events
    add column session_id uuid references public.learning_activity_sessions(id);
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G6. the invariants accepted evidence pointing at a session');
  exception when others then
    perform t.assert(sqlerrm like '%not a reason to believe anything about a child%',
      'G6. evidence that points back at a session is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  alter table public.student_skills
    add column today_decision_id uuid references public.today_decisions(id);
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G7. the invariants accepted the profile pointing at a Today decision');
  exception when others then
    perform t.assert(sqlerrm like '%Being in Today%',
      'G7. a profile column that points at Today membership is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  -- The single most damaging change in the phase: writing evidence here instead
  -- of going through the function that holds the confirmation rules.
  execute $x$
    create or replace function public.accept_evidence_proposal(
      p_proposal uuid, p_relation text default 'demonstrates', p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      insert into public.learning_evidence (student_id, skill_id, source_type)
      values (null, null, 'parent');
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G8. the invariants accepted the bridge writing evidence directly');
  exception when others then
    perform t.assert(sqlerrm like '%not a second copy of it%'
                  or sqlerrm like '%where the confirmation rules live%',
      'G8. an evidence bridge that bypasses confirm_skill_evidence is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.end_learning_session(
      p_session uuid, p_outcome app.learning_session_outcome default 'completed',
      p_minutes integer default null, p_child_note text default null,
      p_educator_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      update public.learning_activity_sessions
         set duration_minutes = (extract(epoch from (now() - started_at)) / 60)::int
       where id = p_session;
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G9. the invariants accepted a duration computed from the clock');
  exception when others then
    perform t.assert(sqlerrm like '%null means nobody knows%',
      'G9. computing a session duration from the clock is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  drop trigger las_occasions_are_not_rewritten on public.learning_activity_sessions;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G10. the invariants accepted the session guard being removed');
  exception when others then
    perform t.assert(sqlerrm like '%experience guards are missing%',
      'G10. removing the guard that keeps an occasion from being rewritten is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  alter table public.learning_activity_sessions add column due_on date;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G11. the invariants accepted a due date on a session');
  exception when others then
    perform t.assert(sqlerrm like '%a morning is not a deadline%',
      'G11. a due date on a session is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  -- A child choosing her own curriculum, or deciding what counts as evidence
  -- about herself. Both are her mother's.
  insert into app.capabilities (relationship, resource, action, requires_section)
  values ('student_self', 'learning_activity', 'approve', false);
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G12. the invariants accepted a child approving evidence about herself');
  exception when others then
    perform t.assert(sqlerrm like '%not hers to make%',
      'G12. a child deciding what counts as evidence about herself is refused');
  end;
end $$;
rollback;

-- =============================================================================
-- N1-N6. The same refusals, at the row rather than in a review
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sess uuid; v_prop uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'explored', 10);
  perform t.logout();

  begin
    update public.learning_activity_sessions set outcome = 'completed' where id = v_sess;
    perform t.assert(false, 'N1. an ended session''s outcome was rewritten');
  exception when others then
    perform t.assert(sqlerrm like '%already on the record%',
      'N1. how a morning went is not rewritten a week later');
  end;
  begin
    update public.learning_activity_sessions set status = 'in_progress' where id = v_sess;
    perform t.assert(false, 'N2. an ended session was reopened');
  exception when others then
    perform t.assert(true, 'N2. and an ended occasion is not reopened in place');
  end;
  begin
    -- `now()` is the transaction's start time, so it equals the value the row
    -- already has and would change nothing. Moving it by an hour is what the
    -- guard is actually for.
    update public.learning_activity_sessions set started_at = now() + interval '1 hour'
     where id = v_sess;
    perform t.assert(false, 'N3. when an occasion happened was moved');
  exception when others then
    perform t.assert(sqlerrm like '%not editable%',
      'N3. nor is when it happened');
  end;

  -- a session cannot be recorded as ended without saying how, or by whom
  begin
    insert into public.learning_activity_sessions (activity_id, student_id, initiated_by, status)
    values (v_act, '44444444-4444-4444-8444-00000000000d',
            '11111111-1111-4111-8111-000000000001', 'ended');
    perform t.assert(false, 'N4. a session was recorded as ended with no outcome and no actor');
  exception when others then
    perform t.assert(sqlerrm like '%las_ended_session_is_complete_ck%',
      'N4. an ended occasion has to say how it ended and who ended it');
  end;

  -- an unanswered offer cannot claim evidence, and an accepted one must name it
  perform t.login('11111111-1111-4111-8111-000000000001');
  v_prop := (public.offer_activity_evidence(v_act)->>'proposal_id')::uuid;
  perform t.logout();
  begin
    update public.learning_evidence_proposals
       set status = 'accepted', decided_by = '11111111-1111-4111-8111-000000000001',
           decided_at = now()
     where id = v_prop;
    perform t.assert(false, 'N5. a proposal was accepted without any evidence behind it');
  exception when others then
    perform t.assert(sqlerrm like '%lep_only_acceptance_produces_evidence_ck%',
      'N5. an accepted offer has to name the evidence a person actually created');
  end;

  -- and an artifact that points at nothing is not an artifact
  begin
    insert into public.learning_activity_artifacts (activity_id, student_id, added_by)
    values (v_act, '44444444-4444-4444-8444-00000000000d',
            '11111111-1111-4111-8111-000000000001');
    perform t.assert(false, 'N6. an artifact pointing at nothing was accepted');
  exception when others then
    perform t.assert(sqlerrm like '%laa_points_at_something_ck%',
      'N6. an artifact has to point at a document or a portfolio item');
  end;
end $$;
rollback;

-- =============================================================================
-- 55-69. STEP 8 PHASE 2 CORRECTION - a request is not a replacement
-- =============================================================================
-- Resolved at the gate, then corrected: a child may ASK for something
-- different, restricted to what is already confirmed for the skill she is
-- already working on - but asking is all she can do herself.
-- CHILD REQUESTS -> ADULT REVIEWS -> ADULT APPROVES OR DECLINES -> ONLY
-- APPROVAL REPLACES. child_choose_alternative_activity, which let her replace
-- directly, is gone; these tests are against request_different_activity,
-- withdraw_activity_change_request, approve_activity_change_request and
-- decline_activity_change_request instead.

begin;
do $$
declare v_act uuid; j jsonb; v_sk uuid; v_req uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;

  -- A genuine ALTERNATIVE confirmed for the same skill, not just the one
  -- Phase 1 already picked.
  perform t.logout();
  update public.resource_skills rs
     set confirmed = true, confirmed_by = '11111111-1111-4111-8111-000000000001',
         confirmed_at = now()
   where rs.skill_id = v_sk and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);

  -- 1. THE CHILD can ask.
  perform t.login('11111111-1111-4111-8111-000000000009');
  j := public.request_different_activity(v_act,
        'dddddddd-0000-4000-8000-000000000005', 'P9 me gusta más el video');
  perform t.logout();

  perform t.assert_eq((j->>'requested')::boolean, true,
    '55a. a child may ask for a confirmed alternative for her own skill');
  v_req := (j->>'request_id')::uuid;
  perform t.assert_eq((select status::text from public.learning_activity_change_requests where id = v_req),
    'pending', '55b. and the request sits pending, waiting on an adult');

  -- 2 & 3. THE REQUEST CHANGES NOTHING about the activity or its resource.
  perform t.assert_eq((j->>'activity_unchanged')::boolean, true,
    '56a. the payload itself says the activity is unchanged');
  perform t.assert_eq((j->>'resource_unchanged')::boolean, true,
    '56b. and the resource is unchanged');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'selected', '56c. the original activity really is still exactly as it was');
  perform t.assert_eq(
    (select resource_id from public.learning_activities where id = v_act) is distinct from
    (select requested_resource_id from public.learning_activity_change_requests where id = v_req),
    true, '56d. the activity''s resource is still the original one, not the one she asked for');

  -- 4. THE CANDIDATE SELECTOR DOES NOT RERUN. Asking did not create, remove or
  -- touch any other activity on this student's path.
  perform t.assert_eq(
    (select count(*)::int from public.learning_activities
      where student_id = '44444444-4444-4444-8444-00000000000d' and status <> 'proposed'),
    1, '57a. asking created no new activity row and disturbed no other one');
  perform t.assert_eq((j->>'selector_rerun')::boolean, false,
    '57b. and the payload says so directly');

  perform t.assert_eq((j->>'evidence_created')::boolean, false,
    '67a. a request creates no evidence');
  perform t.assert_eq((j->>'skill_state_changed')::boolean, false,
    '68a. and moves no skill state');
end $$;
rollback;

-- 5. DUPLICATE PENDING REQUEST PREVENTED - repeated reload does not create two.
begin;
do $$
declare v_act uuid; j1 jsonb; j2 jsonb; v_sk uuid; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_sk and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);

  perform t.login('11111111-1111-4111-8111-000000000009');
  j1 := public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005');
  j2 := public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005');
  perform t.logout();

  perform t.assert_eq((j2->>'requested')::boolean, false,
    '58a. asking twice does not create a second pending request');
  perform t.assert_eq(j2->>'reason', 'already_waiting', '58b. with a reason a screen can render');
  perform t.assert_eq(j2->>'request_id', j1->>'request_id',
    '58c. and it hands back the very request already waiting');
  select count(*)::int into v_n from public.learning_activity_change_requests
   where activity_id = v_act and status = 'pending';
  perform t.assert_eq(v_n, 1, '58d. exactly one pending request exists at the database level too');
end $$;
rollback;

-- 6. A CHILD CAN WITHDRAW her own pending request.
begin;
do $$
declare v_act uuid; v_req uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = (select skill_id from public.learning_activities where id = v_act)
     and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);

  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005')->>'request_id')::uuid;
  j := public.withdraw_activity_change_request(v_req);
  perform t.logout();

  perform t.assert_eq((j->>'withdrawn')::boolean, true, '59a. a child may withdraw her own pending request');
  perform t.assert_eq((select status::text from public.learning_activity_change_requests where id = v_req),
    'withdrawn', '59b. and the row says so');
end $$;
rollback;

-- 7. A CHILD CANNOT APPROVE her own request.
begin;
do $$
declare v_act uuid; v_req uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = (select skill_id from public.learning_activities where id = v_act)
     and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);

  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005')->>'request_id')::uuid;
  begin
    perform public.approve_activity_change_request(v_req);
    perform t.assert(false, '60a. a child approved her own request');
  exception when others then
    perform t.assert(true, '60a. and may not - deciding it is not hers to make');
  end;
  begin
    perform public.decline_activity_change_request(v_req);
    perform t.assert(false, '60b. a child declined on behalf of an adult');
  exception when others then
    perform t.assert(true, '60b. nor may she decline on an adult''s behalf');
  end;
  perform t.logout();
end $$;
rollback;

-- 8. A VIEW-ONLY GUARDIAN cannot approve either.
begin;
do $$
declare v_act uuid; v_req uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = (select skill_id from public.learning_activities where id = v_act)
     and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005')->>'request_id')::uuid;
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000002');
  begin
    perform public.approve_activity_change_request(v_req);
    perform t.assert(false, '61a. a view-only guardian approved a change request');
  exception when others then
    perform t.assert(true, '61a. and may not - she has read, not approve');
  end;
  perform t.logout();
end $$;
rollback;

-- 9. AN UNRELATED FAMILY sees zero and cannot act.
begin;
do $$
declare v_act uuid; v_req uuid; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = (select skill_id from public.learning_activities where id = v_act)
     and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005')->>'request_id')::uuid;
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000003');
  select count(*)::int into v_n from public.learning_activity_change_requests
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '62a. another family''s guardian sees zero requests');
  begin
    perform public.approve_activity_change_request(v_req);
    perform t.assert(false, '62b. another family approved a request that is not theirs');
  exception when others then
    perform t.assert(true, '62b. and cannot act on it at all');
  end;
  perform t.logout();
end $$;
rollback;

-- 10, 12, 13, 14, 16 (no. 11 is the school authorization check just below):
-- A PARENT can approve, approval uses replace_activity_resource's own
-- lineage, and everything the design already guaranteed still holds.
begin;
do $$
declare v_act uuid; v_req uuid; j jsonb; v_new uuid; v_sk uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_sk and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);

  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005',
             'P9 me gusta más el video')->>'request_id')::uuid;
  perform t.logout();

  -- 10. A PARENT (guardian_full) can approve.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.approve_activity_change_request(v_req, 'P9 sí, adelante');
  perform t.logout();

  perform t.assert_eq((j->>'approved')::boolean, true, '63a. a parent may approve');
  v_new := (j->>'activity_id')::uuid;

  -- 13. USES THE EXISTING EXPLICIT-REPLACEMENT LINEAGE - the exact same shape
  -- replace_activity_resource has always produced for a parent acting
  -- directly.
  perform t.assert_eq((select status::text from public.learning_activity_change_requests where id = v_req),
    'approved', '64a. the request itself now says approved');
  perform t.assert_eq((select resulting_activity_id from public.learning_activity_change_requests where id = v_req),
    v_new, '64b. and names the activity it caused');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'replaced', '65a. the original is set aside, not deleted');
  perform t.assert_eq((select replaces_activity_id from public.learning_activities where id = v_new),
    v_act, '65b. the new one names what it replaced');
  perform t.assert_eq((select replaced_by_activity_id from public.learning_activities where id = v_act),
    v_new, '65c. and the old one names its replacement, both directions intact');
  perform t.assert_eq((select skill_id from public.learning_activities where id = v_new),
    v_sk, '65d. the target skill never moved');
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '67b. approval creates no evidence');
  perform t.assert_eq((j->>'skill_state_changed')::boolean, false, '68b. and moves no skill state');
end $$;
rollback;

-- 11. AN ASSIGNED EDUCATOR cannot approve - the existing capability model
-- never gave staff_assigned_write `approve` on learning_activity, and this
-- correction changes nothing about that.
begin;
do $$
declare v_act uuid; v_req uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = (select skill_id from public.learning_activities where id = v_act)
     and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005')->>'request_id')::uuid;
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000005');
  begin
    perform public.approve_activity_change_request(v_req);
    perform t.assert(false, '66a. an assigned educator approved a change request');
  exception when others then
    perform t.assert(true,
      '66a. and may not - the existing capability model never gave staff `approve` on learning_activity');
  end;
  perform t.logout();
end $$;
rollback;

-- 14, 15. DECLINE changes no learning profile and creates no negative record.
begin;
do $$
declare v_act uuid; v_req uuid; j jsonb; v_sk uuid; v_state text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
                                          'secure', 'P9 she has this');
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_sk and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_req := (public.request_different_activity(v_act, 'dddddddd-0000-4000-8000-000000000005')->>'request_id')::uuid;
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.decline_activity_change_request(v_req, 'P9 sigue con este por ahora');
  perform t.logout();

  perform t.assert_eq((j->>'declined')::boolean, true, '69a. an adult may decline');
  perform t.assert_eq((j->>'negative_record_created')::boolean, false,
    '69b. declining creates no negative record, in the payload');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'selected', '69c. the activity is exactly as it was before anyone asked');
  select skill_state::text into v_state from public.student_skills
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk;
  perform t.assert_eq(v_state, 'secure', '69d. and the skill profile did not move at all');
end $$;
rollback;

-- 16. DIRECT STUDENT RESOURCE REPLACEMENT IS IMPOSSIBLE THROUGH EVERY PUBLIC
-- RPC - the retired function is simply gone, the one remaining replacement
-- path still requires a capability a child never holds, and asking for a
-- resource confirmed for a different skill is still refused exactly as gate
-- item b always meant.
begin;
do $$
declare v_act uuid; v_other_sk uuid; v_other_resource uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select id into v_other_sk from public.skills where code = 'NST.FR.2';
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_other_sk;
  select resource_id into v_other_resource from public.resource_skills
   where skill_id = v_other_sk and confirmed limit 1;

  perform t.login('11111111-1111-4111-8111-000000000009');

  -- The retired function does not exist under any signature.
  begin
    perform public.child_choose_alternative_activity(v_act, 'dddddddd-0000-4000-8000-000000000005');
    perform t.assert(false, '70a. the retired direct-replacement function still exists');
  exception when others then
    perform t.assert(true, '70a. child_choose_alternative_activity no longer exists at all');
  end;

  -- The one real replacement mechanism still requires learning_plan:update,
  -- which a child never holds.
  begin
    perform public.replace_activity_resource(v_act, 'dddddddd-0000-4000-8000-000000000005');
    perform t.assert(false, '70b. a child replaced her own activity through replace_activity_resource');
  exception when others then
    perform t.assert(true, '70b. and may not - that still requires learning_plan:update');
  end;

  -- Asking for a resource confirmed for a DIFFERENT skill is refused, not
  -- silently widened.
  perform t.assert_eq(
    (public.request_different_activity(v_act, v_other_resource)->>'reason'),
    'not_one_of_the_confirmed_options_for_this_skill',
    '70c. a resource confirmed for a different skill is still refused when only asking too');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act),
    'selected', '70d. and nothing about her original activity changed');

  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 71-86. STEP 8 PHASE 2 CORRECTION - four outcomes, two separate wishes
-- =============================================================================
-- completed / partially_completed / explored / stopped describe what
-- happened. wants_more and revisit_later describe what somebody wants next,
-- independently of what happened, and neither may move anything about the
-- child.

-- 17-20. All four outcomes are valid and round-trip.
begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'completed');
  perform t.assert_eq(j->>'outcome', 'completed', '71a. completed is valid');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'partially_completed');
  perform t.assert_eq(j->>'outcome', 'partially_completed', '72a. partially_completed is valid');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'explored');
  perform t.assert_eq(j->>'outcome', 'explored', '73a. explored is valid');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'stopped');
  perform t.assert_eq(j->>'outcome', 'stopped', '74a. stopped is valid');
  perform t.logout();
end $$;
rollback;

-- 21, 22. Neither retired label is an outcome any more - the type itself
-- refuses them, at the SQL level, before any function body even runs.
begin;
do $$
begin
  begin
    perform 'child_wants_more'::app.learning_session_outcome;
    perform t.assert(false, '75a. child_wants_more is still castable as a session outcome');
  exception when others then
    perform t.assert(true, '75a. wants_more is not a session outcome - the label does not exist');
  end;
end $$;
rollback;

begin;
do $$
begin
  begin
    perform 'revisit_later'::app.learning_session_outcome;
    perform t.assert(false, '76a. revisit_later is still castable as a session outcome');
  exception when others then
    perform t.assert(true, '76a. revisit_later is not a session outcome - the label does not exist');
  end;
end $$;
rollback;

-- 23-26. The combinations the spec named explicitly, each keeping both
-- truths at once.
begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'completed', null, null, null, true, false);
  perform t.assert_eq(j->>'outcome', 'completed', '77a. completed + wants_more: the outcome is completed');
  perform t.assert_eq((j->>'wants_more')::boolean, true, '77b. and wants_more is kept, separately');
  perform t.assert_eq((j->>'revisit_later')::boolean, false, '77c. revisit_later stays false, not inferred');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'completed', null, null, null, false, true);
  perform t.assert_eq(j->>'outcome', 'completed', '78a. completed + revisit_later: the outcome is completed');
  perform t.assert_eq((j->>'revisit_later')::boolean, true, '78b. and revisit_later is kept, separately');
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'explored', null, null, null, true, false);
  perform t.assert_eq(j->>'outcome', 'explored', '79a. explored + wants_more: the outcome is explored');
  perform t.assert_eq((j->>'wants_more')::boolean, true, '79b. and wants_more is kept');
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'partially_completed', null, null, null, false, true);
  perform t.assert_eq(j->>'outcome', 'partially_completed',
    '80a. partially_completed + revisit_later: the outcome is partially_completed');
  perform t.assert_eq((j->>'revisit_later')::boolean, true, '80b. and revisit_later is kept');
end $$;
rollback;

-- 27. The flags are optional - ending without them defaults both to false and
-- raises nothing.
begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'completed');
  perform t.assert_eq((j->>'wants_more')::boolean, false, '81a. wants_more defaults false when not given');
  perform t.assert_eq((j->>'revisit_later')::boolean, false, '81b. revisit_later defaults false when not given');
end $$;
rollback;

-- 28-31. Neither the outcome nor either flag creates evidence, changes skill
-- state, or ever downgrades a skill already confirmed secure.
begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb; v_sk uuid; v_state text; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
                                          'secure', 'P9 she has this');
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'stopped', null, null, null, true, true);
  perform t.logout();

  perform t.assert_eq((j->>'evidence_created')::boolean, false, '82a. the outcome creates no evidence');
  select count(*)::int into v_n from public.learning_evidence_proposals where activity_id = v_act;
  perform t.assert_eq(v_n, 0, '83a. nor does either follow-up flag - no proposal exists to even answer');
  perform t.assert_eq((j->>'skill_state_changed')::boolean, false,
    '84a. the outcome and the flags together change no skill state');
  select skill_state::text into v_state from public.student_skills
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk;
  perform t.assert_eq(v_state, 'secure',
    '85a. a skill already confirmed secure stays secure through stopped + wants_more + revisit_later');
end $$;
rollback;

-- 32. History remains reconstructable, with both flags visible and in order.
begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'explored', 12, null, null, true, true);
  j := public.activity_history(v_act);
  perform t.logout();

  perform t.assert_eq((j->'sessions'->0->>'outcome'), 'explored',
    '86a. the reconstructed history shows the outcome');
  perform t.assert_eq((j->'sessions'->0->>'wants_more')::boolean, true,
    '86b. shows wants_more');
  perform t.assert_eq((j->'sessions'->0->>'revisit_later')::boolean, true,
    '86c. and shows revisit_later - the whole truth about the occasion, at once');
end $$;
rollback;

-- =============================================================================
-- G13-G17. The corrected guarantees, proved alive by breaking them
-- =============================================================================

-- G13. child_choose_alternative_activity must not come back under any name.
begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.child_choose_alternative_activity(
      p_activity uuid, p_resource uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      return jsonb_build_object('chosen', true);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G13. the invariants accepted the retired direct-replacement function coming back');
  exception when others then
    perform t.assert(sqlerrm like '%retired%',
      'G13. a redefinition of child_choose_alternative_activity is refused');
  end;
  execute 'drop function public.child_choose_alternative_activity(uuid, uuid, text)';
end $$;
rollback;

-- G14. approve_activity_change_request must actually call
-- replace_activity_resource, not reimplement replacement inline.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'approve_activity_change_request' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.approve_activity_change_request(p_request uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      -- Reimplemented inline, calling nothing that already existed for this.
      return jsonb_build_object('approved', true);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G14. the invariants accepted approval that bypasses replace_activity_resource');
  exception when others then
    perform t.assert(sqlerrm like '%replace_activity_resource%',
      'G14. approval that does not go through replace_activity_resource is refused');
  end;
  execute format($x$
    create or replace function public.approve_activity_change_request(p_request uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G15. request_different_activity must keep requiring a confirmed candidate.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'request_different_activity' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.request_different_activity(
      p_activity uuid, p_resource uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      -- No restriction at all.
      return jsonb_build_object('requested', true);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G15. the invariants accepted a request function with no restriction');
  exception when others then
    perform t.assert(sqlerrm like '%confirmed candidates%',
      'G15. removing the confirmed-candidates restriction from the request itself is refused');
  end;
  execute format($x$
    create or replace function public.request_different_activity(
      p_activity uuid, p_resource uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G16. neither child-facing function may write to learning_activities itself.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'withdraw_activity_change_request' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.withdraw_activity_change_request(
      p_request uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      update public.learning_activities set status = 'replaced' where id = (select activity_id from public.learning_activity_change_requests where id = p_request);
      return jsonb_build_object('withdrawn', true);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G16. the invariants accepted a child-facing function writing to learning_activities');
  exception when others then
    perform t.assert(sqlerrm like '%writes directly to learning_activities%',
      'G16. a request function that writes to learning_activities itself is refused');
  end;
  execute format($x$
    create or replace function public.withdraw_activity_change_request(
      p_request uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G17. deciding a request must check `approve` by name, not merely `update`.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'decline_activity_change_request' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.decline_activity_change_request(p_request uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    declare r public.learning_activity_change_requests;
    begin
      select * into r from public.learning_activity_change_requests x where x.id = p_request;
      if not found or not app.can_student_action(r.student_id, 'learning_activity', 'update') then
        raise exception 'not permitted' using errcode = 'insufficient_privilege';
      end if;
      update public.learning_activity_change_requests x set status = 'declined',
             decided_by = auth.uid(), decided_at = now() where x.id = p_request;
      return jsonb_build_object('declined', true);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G17. the invariants accepted a decision function gated on `update` instead of `approve`');
  exception when others then
    perform t.assert(sqlerrm like '%approve%',
      'G17. a decision function no longer checking `approve` by name is refused');
  end;
  execute format($x$
    create or replace function public.decline_activity_change_request(p_request uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;
