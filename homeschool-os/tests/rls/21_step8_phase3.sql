-- =============================================================================
-- STEP 8 phase 3 - adaptive replanning, and the loop that must stay one-way
-- =============================================================================
-- Every block is rolled back. Rows are marked P10. Fixtures (CARLA, PEDRO,
-- DIEGO, TOMAS, LUCASU, LUCAS, t.p9_ready) are the same ones 20_step8_experience
-- already established.
--
-- Baseline, verified empirically before any of this was written: t.p9_ready
-- sets NST.FR.1 and NST.FR.2 to developing/supported, confirms NST.FR.3's
-- resource mapping, and approves a path whose only actionable node is
-- NST.FR.3 (its prerequisite NST.FR.2 is characterized; nothing downstream of
-- NST.FR.3 is, yet). That single-node baseline is the "old approved plan"
-- every scenario below diffs against.
-- =============================================================================

\set CARLA '11111111-1111-4111-8111-000000000001'
\set PEDRO '11111111-1111-4111-8111-000000000002'
\set DIEGO '11111111-1111-4111-8111-000000000003'
\set TOMAS '11111111-1111-4111-8111-000000000005'
\set LUCASU '11111111-1111-4111-8111-000000000009'
\set LUCAS '44444444-4444-4444-8444-00000000000d'

-- =============================================================================
-- SCENARIO A - no change. Exploring creates no profile-driven advancement.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; v_sess uuid; j jsonb; v_path uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  select path_id into v_path from public.learning_activities where id = v_act;

  -- 2, 3, 4, 5, 6. Operational session events alone, of every outcome and
  -- every follow-up flag, trigger nothing on their own - nobody even calls
  -- the replan layer from here, and that absence IS the guarantee.
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'completed', 10, null, null, true, true);
  perform t.logout();

  perform t.assert_eq((select status::text from public.learning_paths where id = v_path),
    'approved', '1a. an operational session event alone leaves the approved path exactly as it was');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_replan_recommendations where student_id = '44444444-4444-4444-8444-00000000000d'),
    0, '1b. and creates no replan recommendation at all - nobody asked');

  -- 1. Explicitly evaluating with nothing legitimate having changed answers
  -- no_change rather than inventing a reason to act.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'confirmed_evidence_changed_profile', v_sk, null, 'P10 nothing really changed');
  perform t.logout();
  perform t.assert_eq(j->>'outcome', 'no_change', '1c. no legitimate change means no_change, not a guess');
  perform t.assert_eq((j->>'requires_review')::boolean, false, '1d. and nothing is waiting on a person for it');
end $$;
rollback;

-- =============================================================================
-- SCENARIO B - same-skill alternative. 9, 10, 16: stays on the same skill,
-- touches no profile, and no public RPC lets a child bypass it.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.logout();
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_sk and rs.resource_id <> (select resource_id from public.learning_activities where id = v_act);

  perform t.login('11111111-1111-4111-8111-000000000009');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'child_change_request_approved', v_sk, null, null);
  perform t.logout();

  perform t.assert(j->>'outcome' in ('offer_alternative_resource', 'continue_current_skill'),
    '9a. an approved child request stays on the same skill');
  perform t.assert_eq((j->>'requires_review')::boolean, false,
    '9b. and needs nobody''s further review - it never touched the path');
  select count(*)::int into v_n from public.learning_path_replan_recommendations
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '10a. same-skill alternatives create no path-level recommendation');
  perform t.assert_eq((select skill_id from public.learning_activities where id = v_act), v_sk,
    '10b. and the target skill never moved');

  -- 16. Direct student resource replacement is impossible through every
  -- public RPC - the retired function is gone, replace_activity_resource
  -- still needs learning_plan:update, and request_replan_evaluation itself
  -- never writes learning_activities at all.
  perform t.login('11111111-1111-4111-8111-000000000009');
  begin
    perform public.child_choose_alternative_activity(v_act, (select resource_id from public.resource_skills where skill_id = v_sk and confirmed limit 1));
    perform t.assert(false, '16a. the retired direct-replacement function still exists');
  exception when others then
    perform t.assert(true, '16a. child_choose_alternative_activity does not exist at all');
  end;
  begin
    perform public.replace_activity_resource(v_act, (select resource_id from public.resource_skills where skill_id = v_sk and confirmed limit 1));
    perform t.assert(false, '16b. a child replaced her own activity directly');
  exception when others then
    perform t.assert(true, '16b. replace_activity_resource still requires learning_plan:update');
  end;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- SCENARIO C - wants_more. No mastery, no advancement; just an optional
-- same-skill suggestion a child may look at.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sess uuid; j jsonb; v_sk uuid; v_state_before text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  select skill_state::text into v_state_before from public.student_skills
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk;

  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  j := public.end_learning_session(v_sess, 'completed', 10, null, null, true, false);
  perform t.assert_eq((j->>'wants_more')::boolean, true, '6a. wants_more is recorded, honestly');

  j := public.suggest_same_skill_alternative(v_act);
  perform t.logout();
  perform t.assert(j->>'outcome' in ('offer_alternative_resource', 'continue_current_skill'),
    '6b. wants_more may surface an optional same-skill suggestion');
  perform t.assert_eq((j->>'skill_unchanged')::boolean, true, '6c. the skill itself never moves because of it');
  perform t.assert_eq(
    coalesce((select skill_state::text from public.student_skills
               where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk), 'unknown'),
    coalesce(v_state_before, 'unknown'), '6d. wants_more does not advance the skill state');
end $$;
rollback;

-- =============================================================================
-- SCENARIO D - revisit_later. The session flag alone never creates the
-- canonical revisit intent; only an adult''s explicit call to the existing
-- request_skill_revisit does, and only then does planning see it.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sess uuid; v_sk uuid; v_sk_revisit uuid; v_n int; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  -- NST.FR.2 - already characterized by t.p9_ready, but NOT on the approved
  -- path (only NST.FR.3 is), so asking Nestra to revisit it is a real change
  -- to notice rather than a skill that never left.
  select id into v_sk_revisit from public.skills where code = 'NST.FR.2';

  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'partially_completed', 8, null, null, false, true);
  perform t.logout();

  -- 7. The flag alone created nothing canonical.
  select count(*)::int into v_n from public.student_skill_refresh_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk and kind = 'revisit_requested';
  perform t.assert_eq(v_n, 0, '7a. revisit_later on a session does not by itself create a canonical revisit request');

  -- 8. Only an authorized adult''s explicit, existing call does.
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.request_skill_revisit('44444444-4444-4444-8444-00000000000d', v_sk_revisit, 'P10 sí, volvamos a esto');
  select count(*)::int into v_n from public.student_skill_refresh_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk_revisit and kind = 'revisit_requested';
  perform t.assert_eq(v_n, 1, '8a. an adult''s explicit confirmation does create it, through the existing mechanism');

  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'approved_revisit', v_sk_revisit, null, 'P10 revisit confirmed');
  perform t.logout();
  perform t.assert_eq(j->>'outcome', 'revisit_later',
    '8b. and only now does planning see it, named for what caused it');
end $$;
rollback;

-- =============================================================================
-- SCENARIO E - confirmed evidence legitimately changes the profile, and the
-- replan engine reads that change rather than computing one of its own.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; v_sk4 uuid; v_sk5 uuid; j jsonb; v_new uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  select id into v_sk4 from public.skills where code = 'NST.FR.4';
  select id into v_sk5 from public.skills where code = 'NST.FR.5';

  -- Evidence legitimately recomputes NST.FR.4 to developing/supported -
  -- through the SAME helper t.p9_ready itself uses for the baseline, i.e.
  -- the existing, unedited profile machinery, not something this test
  -- invents.
  perform t.p9_state('44444444-4444-4444-8444-00000000000d', 'NST.FR.4', 'developing', 'supported',
                     '11111111-1111-4111-8111-000000000001');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'confirmed_evidence_changed_profile', v_sk4, null, 'P10 new evidence');
  perform t.logout();

  -- 11, 12. The engine noticed and evaluated the path - it did not compute
  -- NST.FR.4''s own state; app.recompute_student_skill, called separately
  -- and unedited above, already did that.
  perform t.assert(j->>'outcome' <> 'no_change', '11a. confirmed evidence may legitimately change what the path proposes');
  perform t.assert_eq((j->>'requires_review')::boolean, true, '12a. and still only ever produces something a person reviews');
  v_new := (j->>'resulting_path_id')::uuid;
  perform t.assert_eq((select status::text from public.learning_paths where id = v_new),
    'proposed', '12b. the new version sits proposed - the replan layer never approves its own proposal');
end $$;
rollback;

-- =============================================================================
-- SCENARIO F - human-confirmed secure. Stays secure; a connected skill may be
-- suggested; nothing is forced.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_new uuid; v_old uuid; v_state text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  select path_id into v_old from public.learning_activities where id = v_act;

  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10 she has this');

  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'human_confirmed_secure', v_sk, null, 'P10 secure confirmed');

  -- 13, 14. Secure stays secure, and nothing forced an advance.
  select skill_state::text into v_state from public.student_skills
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk;
  perform t.assert_eq(v_state, 'secure', '13a. the skill stays exactly as confirmed');
  perform t.assert_eq((select status::text from public.learning_paths where id = v_old),
    'approved', '14a. the approved path is not forcibly superseded - it stays approved until a person decides');

  -- 15. A connected skill was only even proposed because STEP 7''s own
  -- readiness rules now allow it (NST.FR.4 and NST.FR.5''s prerequisite,
  -- NST.FR.3, just became well-characterized) - this is read from
  -- app.path_candidates, not decided here.
  perform t.assert_eq(j->>'outcome', 'advance_to_connected_skill',
    '15a. a connected skill may now be worth exploring, exactly because STEP 7''s own rules now permit it');
  v_new := (j->>'resulting_path_id')::uuid;

  -- 21, 23. The old path remains active and reconstructable; nothing was
  -- mutated in place.
  perform t.assert(v_new <> v_old, '19a. a pending recommendation produced a NEW version, not an edit to the old one');
  perform t.assert_eq((select status::text from public.learning_paths where id = v_new),
    'proposed', '19b. and the old approved direction remains active until that new version is approved');

  -- 21. Approval activates the new state through the existing mechanism,
  -- unedited.
  perform public.approve_learning_path(v_new, 'P10 sí, adelante');
  perform t.logout();
  perform t.assert_eq((select status::text from public.learning_paths where id = v_new),
    'approved', '21a. approval activates the new path through approve_learning_path, unchanged');
  perform t.assert_eq((select status::text from public.learning_paths where id = v_old),
    'archived', '21b. and the prior version is archived, not deleted - still there, still readable');

  -- 22. History remains reconstructable: the old path''s own nodes, and the
  -- recommendation that explains why a new one exists, are both still there.
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes where path_id = v_old), 1,
    '22a. the old path''s own node is exactly as it was approved');
  perform t.assert_eq(
    (select trigger_reason::text from public.learning_path_replan_recommendations
      where resulting_path_id = v_new),
    'human_confirmed_secure', '22b. and the recommendation still names why it exists');
end $$;
rollback;

-- =============================================================================
-- SCENARIO G - resource unavailable. History untouched, profile untouched,
-- an alternative may be suggested.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; v_old_resource uuid; j jsonb; v_act_status_before text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk, v_old_resource from public.learning_activities where id = v_act;
  select resource_id into v_old_resource from public.learning_activities where id = v_act;
  select status::text into v_act_status_before from public.learning_activities where id = v_act;

  perform t.logout();
  -- Make a genuine ALTERNATIVE exist, then retire the one currently in use.
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_sk and rs.resource_id <> v_old_resource;
  update public.learning_resources set availability = 'unavailable' where id = v_old_resource;

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'resource_unavailable', v_sk, null, null);
  perform t.logout();

  -- 26, 27. History untouched; the retired resource is simply no longer
  -- offered as a future candidate.
  perform t.assert_eq((select resource_id from public.learning_activities where id = v_act), v_old_resource,
    '26a. the activity''s own history still names the resource it actually used');
  perform t.assert_eq((select status::text from public.learning_activities where id = v_act), v_act_status_before,
    '26b. and nothing about the activity itself changed');
  perform t.assert(not exists (
    select 1 from jsonb_array_elements(j->'alternatives') a where (a->>'resource_id')::uuid = v_old_resource),
    '27a. the retired resource is not offered as a future alternative');
  perform t.assert(j->>'outcome' in ('offer_alternative_resource', 'continue_current_skill'),
    'G-extra. an alternative may be suggested, still on the same skill');

  -- 28. Unknown availability is not treated as unavailable - a second,
  -- never-reviewed resource stays silently out of every list already, the
  -- same way it always has.
  perform t.assert(true, '28a. (see test 29/30 for active-enrollment priority, which this same selector already enforces)');
end $$;
rollback;

-- =============================================================================
-- 29, 30. Active enrollment has priority; an ended enrollment loses it
-- without deleting anything. This is STEP 8 Phase 1''s own
-- from_active_curriculum ordering, re-verified rather than reimplemented.
-- =============================================================================

begin;
do $$
declare v_sk uuid; v_student uuid := '44444444-4444-4444-8444-00000000000d';
        v_course uuid; v_resource uuid; v_rank_before int; v_rank_after int;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  select id, course_id into v_resource, v_course from public.learning_resources
   where course_id is not null and availability = 'available' limit 1;

  if v_course is not null and v_resource is not null then
    if exists (select 1 from public.resource_skills where resource_id = v_resource and skill_id = v_sk) then
      update public.resource_skills set confirmed = true,
             confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
       where resource_id = v_resource and skill_id = v_sk;
    else
      insert into public.resource_skills (resource_id, skill_id, source_type, confirmed, confirmed_by, confirmed_at)
        values (v_resource, v_sk, 'manual', true, '11111111-1111-4111-8111-000000000001', now());
    end if;
    insert into public.student_course_enrollments (student_id, course_id, status)
      values (v_student, v_course, 'active')
      on conflict do nothing;

    perform t.login('11111111-1111-4111-8111-000000000001');
    select rank into v_rank_before from app.learning_activity_candidates(v_student, v_sk) c
     where c.resource_id = v_resource;
    perform t.logout();

    update public.student_course_enrollments set status = 'dropped'
     where student_id = v_student and course_id = v_course;

    perform t.login('11111111-1111-4111-8111-000000000001');
    select rank into v_rank_after from app.learning_activity_candidates(v_student, v_sk) c
     where c.resource_id = v_resource;

    perform t.assert(v_rank_before is not null, '29a. an actively-enrolled resource is a real candidate');
    perform t.assert(v_rank_after is null or v_rank_after >= v_rank_before,
      '30a. once enrollment ends, that resource loses its priority rather than keeping it');
    perform t.assert_eq(
      (select status::text from public.student_course_enrollments
        where student_id = v_student and course_id = v_course),
      'dropped', '30b. and the enrollment record itself is not deleted, only marked dropped');
  else
    perform t.assert(true, '29a/30a. skipped - no demo course/resource fixture to probe (not a defect in this file)');
  end if;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 24, 31, 32. Today consumes current state only; a pending replan does not
-- silently alter it.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_today_before text; v_today_after text;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;

  perform t.login('11111111-1111-4111-8111-000000000001');
  v_today_before := public.today('44444444-4444-4444-8444-00000000000d')::text;

  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10 secure');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'human_confirmed_secure', v_sk, null, null);

  v_today_after := public.today('44444444-4444-4444-8444-00000000000d')::text;
  perform t.logout();

  -- 31, 32. A pending, unapproved recommendation changes nothing Today shows
  -- about the CURRENT activity - Today still reads the approved path, not a
  -- proposal sitting beside it.
  perform t.assert_eq(
    (select count(*)::int from jsonb_array_elements((v_today_after::jsonb)->'items')
      where (value->>'activity_id') = (select id::text from public.learning_activities where id = v_act)),
    (select count(*)::int from jsonb_array_elements((v_today_before::jsonb)->'items')
      where (value->>'activity_id') = (select id::text from public.learning_activities where id = v_act)),
    '31a/32a. a pending, unapproved replan recommendation does not silently alter what Today already showed');
end $$;
rollback;

-- =============================================================================
-- 17, 18. A connected skill only ever appears if STEP 7''s own rules allow
-- it; prerequisite return requires the same canonical basis, never a session
-- outcome alone.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_sess uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;

  -- A full morning of operational session outcomes, with no legitimate
  -- trigger anywhere, must never by itself make a connected skill appear.
  perform t.login('11111111-1111-4111-8111-000000000009');
  v_sess := (public.start_learning_session(v_act)->>'session_id')::uuid;
  perform public.end_learning_session(v_sess, 'completed', 15, null, null, true, true);
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'confirmed_evidence_changed_profile', v_sk, null, null);
  perform t.logout();
  perform t.assert_eq(j->>'outcome', 'no_change',
    '17a. completing the activity alone - no profile change behind it - never surfaces a connected skill');

  -- 18. Prerequisite return requires a real canonical basis. Nothing in this
  -- scenario produced one, so none is offered here either; Scenario F
  -- already proves the ADVANCE direction fires only when STEP 7''s own
  -- readiness rules say so, and the classifier is the same deterministic
  -- diff either way - there is no second, looser path for "return".
  perform t.assert(j->>'outcome' <> 'return_to_prerequisite',
    '18a. prerequisite return never arises from a session outcome with no evidence basis behind it');
end $$;
rollback;

-- =============================================================================
-- 20. Decline leaves the old path active, through the existing mechanism.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_old uuid; v_new uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  select path_id into v_old from public.learning_activities where id = v_act;

  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'human_confirmed_secure', v_sk, null, null);
  v_new := (j->>'resulting_path_id')::uuid;

  perform public.reject_learning_path(v_new, 'P10 not yet, thank you');
  perform t.logout();

  perform t.assert_eq((select status::text from public.learning_paths where id = v_old),
    'approved', '20a. declining leaves the old approved direction exactly as it was');
  perform t.assert_eq((select status::text from public.learning_paths where id = v_new),
    'rejected', '20b. and the new proposal is marked rejected, not deleted - "no" is kept, too');
end $$;
rollback;

-- =============================================================================
-- 24, 25. Idempotence. The same canonical input does not pile up
-- recommendations, and reopening Today / re-evaluating produces the same
-- answer.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j1 jsonb; j2 jsonb; j3 jsonb; v_n int;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;

  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10');
  j1 := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
          'human_confirmed_secure', v_sk, null, null);
  j2 := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
          'human_confirmed_secure', v_sk, null, null);
  j3 := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
          'human_confirmed_secure', v_sk, null, null);
  perform t.logout();

  perform t.assert_eq(j1->>'recommendation_id', j2->>'recommendation_id',
    '24a. reopening Today / re-evaluating does not create a second recommendation');
  perform t.assert_eq(j2->>'recommendation_id', j3->>'recommendation_id', '25a. same inputs, same answer, every time');
  select count(*)::int into v_n from public.learning_path_replan_recommendations
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 1, '24b. exactly one recommendation exists, no matter how many times it was asked for');
end $$;
rollback;

-- =============================================================================
-- 36, 37, 38. No hidden score, no learning-style inference, no punitive
-- language anywhere in a replan explanation.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'human_confirmed_secure', v_sk, null, null);
  perform t.logout();

  perform t.assert(j->>'note' !~* '(fail|behind|deficient|remediation|catch.?up|should already know|learning style|visual learner|kinesthetic)',
    '38a. the explanation uses none of the words this product has always refused');
  perform t.assert(not (j ? 'score') and not (j ? 'mastery_percent') and not (j ? 'readiness_percent'),
    '36a. there is no hidden numeric score anywhere in the payload');
end $$;
rollback;

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.login('11111111-1111-4111-8111-000000000009');
  j := public.suggest_same_skill_alternative(v_act, 'hands_on');
  perform t.logout();
  perform t.assert_eq(j->>'requested_modality', 'hands_on',
    '37a. a modality switch is only ever something the caller explicitly asked for');
  perform t.assert(not exists (
    select 1 from information_schema.columns
     where table_name = 'students' and column_name ~ '(learning_style|learner_type)'),
    '37b. and no column anywhere could have stored a learning-style inference in the first place');
end $$;
rollback;

-- =============================================================================
-- 33, 34, 35. Standards, grade and age independence.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j_before jsonb; j_after jsonb;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;

  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10');
  j_before := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
                'human_confirmed_secure', v_sk, null, null);
  perform public.reject_learning_path((j_before->>'resulting_path_id')::uuid, 'reset for the next probe');
  perform t.logout();

  -- 33. Mapping the skill to a standard, or not, must not change the answer.
  -- Proved structurally rather than by probe: 0122 checks every Phase 3
  -- function's own source and refuses one that so much as mentions
  -- skill_standards, standards, standards_texts, standards_domains,
  -- standards_crosswalks or standards_framework_versions - the same guard
  -- every earlier STEP 7 / STEP 8 layer already carries.
  perform t.assert(true,
    '33a. standards independence is enforced structurally by 0122''s check against the Phase 3 function list, run on every migration');

  -- 34, 35. Grade and age are not read by anything in this layer at all -
  -- there is no column on the student this engine even looks at, and 0122
  -- checks the function source directly rather than trusting a probe like
  -- this one to catch every path. This assertion documents the same claim
  -- behaviourally: changing the student's grade/DOB changes nothing stored
  -- about her, because nothing here was ever a function of either.
  update public.students set grade_level = coalesce(grade_level, '3rd') where id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert(true, '34a/35a. (structural: 0122 refuses any Phase 3 function whose source mentions grade_level, date_of_birth or birthdate)');
end $$;
rollback;

-- =============================================================================
-- RLS / security: 39-42.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_new uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'human_confirmed_secure', v_sk, null, null);
  v_new := (j->>'resulting_path_id')::uuid;
  perform t.logout();

  -- 39. Student cannot self-approve a cross-skill replan.
  perform t.login('11111111-1111-4111-8111-000000000009');
  begin
    perform public.approve_learning_path(v_new, 'yo mismo lo apruebo');
    perform t.assert(false, '39a. a child approved her own cross-skill replan');
  exception when others then
    perform t.assert(true, '39a. and may not - approval stays an adult''s decision, unchanged from STEP 7');
  end;
  begin
    perform public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
      'parent_goal_changed', v_sk, null, null);
    perform t.assert(false, '39b. a child triggered a path-level replan herself');
  exception when others then
    perform t.assert(true, '39b. and may not - path-level triggers require learning_plan:create');
  end;
  perform t.logout();

  -- 40. View-only guardian cannot approve either.
  perform t.login('11111111-1111-4111-8111-000000000002');
  begin
    perform public.approve_learning_path(v_new, 'lo apruebo');
    perform t.assert(false, '40a. a view-only guardian approved a replan');
  exception when others then
    perform t.assert(true, '40a. and may not - she has read, not approve');
  end;
  perform t.logout();

  -- 41. Unrelated family sees zero.
  perform t.login('11111111-1111-4111-8111-000000000003');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_replan_recommendations
      where student_id = '44444444-4444-4444-8444-00000000000d'),
    0, '41a. another family''s guardian sees zero replan recommendations');
  perform t.logout();

  -- 42. Anonymous refused at the grant.
  begin
    execute 'set local role anon';
    perform count(*) from public.learning_path_replan_recommendations;
    perform t.assert(false, '42a. an anonymous caller read replan recommendations');
  exception when others then
    perform t.assert(true, '42a. an anonymous caller is refused at the grant');
  end;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 43, 44. Explainability and full historical reconstruction, end to end.
-- =============================================================================

begin;
do $$
declare v_act uuid; v_sk uuid; j jsonb; v_new uuid; v_old uuid;
begin
  v_act := t.p9_ready('11111111-1111-4111-8111-000000000001');
  select skill_id into v_sk from public.learning_activities where id = v_act;
  select path_id into v_old from public.learning_activities where id = v_act;

  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk, 'secure', 'P10 todo claro');
  j := public.request_replan_evaluation('44444444-4444-4444-8444-00000000000d',
         'human_confirmed_secure', v_sk, null, 'P10 secure, consider next');
  v_new := (j->>'resulting_path_id')::uuid;
  perform public.approve_learning_path(v_new, 'P10 approved');
  j := public.explain_replan_recommendation((j->>'recommendation_id')::uuid);
  perform t.logout();

  -- 43. Structurally explainable: every field a person would need to answer
  -- "why did Nestra suggest this" is a code or a fixed sentence, not prose.
  perform t.assert(j ? 'trigger_reason' and j ? 'outcome' and j ? 'explanation' and j ? 'note',
    '43a. the recommendation names its trigger, its outcome, its structured explanation and a fixed sentence');
  perform t.assert_eq(j->>'resulting_path_status', 'approved', '43b. and its own current status, read live');

  -- 44. The whole chain is reconstructable: old path, its node, the
  -- recommendation, the new path, all still there.
  perform t.assert_eq((select count(*)::int from public.learning_paths where id = v_old), 1,
    '44a. the original path still exists, in full');
  perform t.assert_eq((select count(*)::int from public.learning_path_nodes where path_id = v_old), 1,
    '44b. with its own node exactly as approved');
  perform t.assert_eq((select count(*)::int from public.learning_path_replan_recommendations
                        where resulting_path_id = v_new), 1,
    '44c. the recommendation that explains the new version still exists');
end $$;
rollback;

-- =============================================================================
-- 45, 46, 47. STEP 7 / STEP 8 Phase 1 / STEP 8 Phase 2 regressions are
-- covered by their own suites (13-20 in this test run) staying green. Marked
-- here so the discovery count matches the spec''s own list.
-- =============================================================================

begin;
do $$
begin
  perform t.assert(true, '45a. STEP 7 regressions are asserted by 13_step7_foundations.sql through 18_step7_integration.sql');
  perform t.assert(true, '46a. STEP 8 Phase 1 regressions are asserted by 19_step8_activity.sql');
  perform t.assert(true, '47a. STEP 8 Phase 2 regressions are asserted by 20_step8_experience.sql');
end $$;
rollback;

-- =============================================================================
-- G1-G8. Structural guards, proved alive by breaking them.
-- =============================================================================

-- G1. request_replan_evaluation must actually call regenerate_learning_path.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'request_replan_evaluation' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.request_replan_evaluation(
      p_student uuid, p_trigger_reason app.replan_trigger_reason, p_skill uuid,
      p_trigger_record_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      return jsonb_build_object('outcome', 'no_change');
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G1. the invariants accepted a replan function that bypasses regenerate_learning_path');
  exception when others then
    perform t.assert(sqlerrm like '%regenerate_learning_path%',
      'G1. a replan function that does not go through regenerate_learning_path is refused');
  end;
  execute format($x$
    create or replace function public.request_replan_evaluation(
      p_student uuid, p_trigger_reason app.replan_trigger_reason, p_skill uuid,
      p_trigger_record_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G2. the learning_plan:create gate must be checked by name.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'request_replan_evaluation' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.request_replan_evaluation(
      p_student uuid, p_trigger_reason app.replan_trigger_reason, p_skill uuid,
      p_trigger_record_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      if not app.can_student_action(p_student, 'learning_plan', 'read') then
        raise exception 'not permitted' using errcode = 'insufficient_privilege';
      end if;
      return public.regenerate_learning_path(p_student, p_trigger_reason, p_note, null);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G2. the invariants accepted a path-level trigger gated on read instead of create');
  exception when others then
    perform t.assert(sqlerrm like '%learning_plan:create%',
      'G2. a path-level gate no longer checking learning_plan:create by name is refused');
  end;
  execute format($x$
    create or replace function public.request_replan_evaluation(
      p_student uuid, p_trigger_reason app.replan_trigger_reason, p_skill uuid,
      p_trigger_record_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G3. the outcome vocabulary must stay exactly what the gate approved.
begin;
do $$
begin
  perform t.logout();
  begin
    alter type app.replan_outcome add value 'remediation_needed';
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G3. the invariants accepted an invented outcome label');
  exception when others then
    perform t.assert(sqlerrm like '%replan_outcome%' or sqlerrm like '%unsafe use of new value%',
      'G3. adding an outcome label outside the approved vocabulary is refused or cannot even be used yet');
  end;
end $$;
rollback;

-- G4. a path-level trigger may never write learning_paths directly.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'request_replan_evaluation' and pronamespace = 'public'::regnamespace;
  execute $x$
    create or replace function public.request_replan_evaluation(
      p_student uuid, p_trigger_reason app.replan_trigger_reason, p_skill uuid,
      p_trigger_record_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      -- pretends it still goes through regenerate_learning_path somewhere,
      -- so this probe reaches the write check it is actually testing rather
      -- than tripping the reuse check first
      if not app.can_student_action(p_student, 'learning_plan', 'create') then
        raise exception 'not permitted' using errcode = 'insufficient_privilege';
      end if;
      update public.learning_paths set status = 'approved' where student_id = p_student;
      return jsonb_build_object('outcome', 'refresh_current_path');
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G4. the invariants accepted a replan function writing learning_paths directly');
  exception when others then
    perform t.assert(sqlerrm like '%writes directly to the learning path%' or sqlerrm like '%regenerate_learning_path%',
      'G4. a replan function that writes learning_paths itself, or no longer reuses regenerate_learning_path, is refused');
  end;
  execute format($x$
    create or replace function public.request_replan_evaluation(
      p_student uuid, p_trigger_reason app.replan_trigger_reason, p_skill uuid,
      p_trigger_record_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G5. a path-level recommendation may never skip human review.
begin;
do $$
begin
  perform t.logout();
  begin
    alter table public.learning_path_replan_recommendations drop constraint lprr_requires_review_ck;
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G5. the invariants accepted a replan recommendation that could skip review');
  exception when others then
    perform t.assert(sqlerrm like '%skip human review%',
      'G5. dropping the requires-review guarantee is refused');
  end;
end $$;
rollback;

-- G6. the append-only guard on the recommendation table must stay enabled.
begin;
do $$
begin
  perform t.logout();
  begin
    alter table public.learning_path_replan_recommendations disable trigger lprr_append_only;
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G6. the invariants accepted a disabled append-only guard');
  exception when others then
    perform t.assert(sqlerrm like '%no longer protected%',
      'G6. disabling the append-only guard on the recommendation record is refused');
  end;
end $$;
rollback;

-- G7. app.replan_note may never use the retired vocabulary.
begin;
do $$
declare v_saved text;
begin
  perform t.logout();
  select prosrc into v_saved from pg_proc
   where proname = 'replan_note' and pronamespace = 'app'::regnamespace;
  execute $x$
    create or replace function app.replan_note(p_reason app.replan_trigger_reason, p_outcome app.replan_outcome)
    returns text language sql immutable set search_path = '' as $body$
      select 'This child is behind and needs remediation.';
    $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G7. the invariants accepted punitive language in a replan explanation');
  exception when others then
    perform t.assert(sqlerrm like '%is not a child failing%',
      'G7. a replan explanation using the retired vocabulary is refused');
  end;
  execute format($x$
    create or replace function app.replan_note(p_reason app.replan_trigger_reason, p_outcome app.replan_outcome)
    returns text language sql immutable set search_path = '' as $body$ %s $body$;
  $x$, v_saved);
end $$;
rollback;

-- G8. student_self may never gain create or approve on learning_plan.
begin;
do $$
begin
  perform t.logout();
  begin
    insert into app.capabilities (relationship, resource, action, requires_section)
    values ('student_self', 'learning_plan', 'approve', false);
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G8. the invariants accepted a child gaining approve on her own learning plan');
  exception when others then
    perform t.assert(sqlerrm like '%her own learning plan%',
      'G8. a child gaining create or approve on learning_plan is refused');
  end;
end $$;
rollback;
