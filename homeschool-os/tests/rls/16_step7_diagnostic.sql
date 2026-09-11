-- =============================================================================
-- STEP 7 phase 5 - the adaptive diagnostic
-- =============================================================================
-- Every block is rolled back. Rows are marked P5.
--
-- The tests that matter most are 13 (an unreviewed diagnostic guess cannot feed
-- itself back as established evidence), 15-18 (standards, grade and age cannot
-- change the route), and 23 (a hard afternoon with fractions is not a fact about
-- reading).
-- =============================================================================

\set CARLA '11111111-1111-4111-8111-000000000001'
\set PEDRO '11111111-1111-4111-8111-000000000002'
\set DIEGO '11111111-1111-4111-8111-000000000003'
\set LUCAS '44444444-4444-4444-8444-00000000000d'
\set SOFIA '44444444-4444-4444-8444-00000000000f'

-- Make a skill established the honest way: two usable observations a person
-- recorded, on two occasions, from two sources.
create or replace function t.p5_establish(p_student uuid, p_code text, p_actor uuid)
returns uuid language plpgsql as $$
declare v_ss uuid; v_sk uuid; v_org uuid;
begin
  select id into v_sk from public.skills where code = p_code;
  select primary_organization_id into v_org from public.students where id = p_student;
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, created_by)
  values (p_student, v_sk, v_org, 'manual','human_entered','parent','unknown', p_actor)
  returning id into v_ss;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id, organization_id,
           occurred_on, evidence_note, skill_state, source_type, evidence_source,
           record_provenance, created_by)
  values (v_ss, p_student, v_sk, v_org, current_date - 40,'P5','developing','manual','parent','human_entered', p_actor),
         (v_ss, p_student, v_sk, v_org, current_date - 30,'P5','developing','manual','tutor','human_entered', p_actor);
  perform t.login(p_actor);
  perform public.recompute_student_skill(p_student, v_sk);
  perform t.logout();
  return v_ss;
end $$;

-- Run a scripted session and return its route as one comparable string.
create or replace function t.p5_run(p_student uuid, p_root_code text, p_actor uuid, p_outcomes text[])
returns text language plpgsql as $$
declare j jsonb; si uuid; i int; v_sess uuid; v_root uuid; v_route text;
begin
  select id into v_root from public.skills where code = p_root_code;
  perform t.login(p_actor);
  j := public.start_diagnostic_session(p_student, v_root);
  v_sess := (j->>'session')::uuid;
  si := (j->>'session_item')::uuid;
  for i in 1..coalesce(array_length(p_outcomes, 1), 0) loop
    exit when si is null;
    j := public.record_diagnostic_observation(si, p_outcomes[i], 'P5');
    si := (j->>'session_item')::uuid;
  end loop;
  -- A parent who walks away leaves a session open, and the schema allows only
  -- one open session per child per branch. Scripted runs close theirs, so two
  -- runs of the same script are independent rather than the second one being
  -- refused by the first.
  if (select s.status from public.diagnostic_sessions s where s.id = v_sess) = 'active' then
    perform public.stop_diagnostic_session(v_sess, 'P5 scripted run complete');
  end if;

  select string_agg(k.code || '/' || si2.reason_code || '/' || coalesce(o.outcome::text, '-'),
                    ' | ' order by si2.sequence)
    into v_route
    from public.diagnostic_session_items si2
    join public.skills k on k.id = si2.skill_id
    left join public.diagnostic_observations o on o.session_item_id = si2.id
   where si2.session_id = v_sess;
  return coalesce(v_route, '(no items)') || '  [stop=' ||
         coalesce((select s.stop_reason::text from public.diagnostic_sessions s where s.id = v_sess), '-') || ']';
end $$;

grant execute on function t.p5_establish(uuid, text, uuid) to authenticated;
grant execute on function t.p5_run(uuid, text, uuid, text[]) to authenticated;

-- =============================================================================
-- 1-4. Where it starts, and where it goes
-- =============================================================================

begin;
do $$
declare v_route text;
begin
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated']);
  perform t.assert_eq(v_route,
    'NST.FR.1/explore_next_skill/demonstrated | NST.FR.1/uncertainty_probe/demonstrated | NST.FR.2/explore_next_skill/-  [stop=parent_stopped]',
    '1a. no prior evidence enters at the root, and two demonstrations move to the next connected skill');
end $$;
rollback;

begin;
do $$
declare v_route text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', array['demonstrated']);
  perform t.assert(v_route like 'NST.FR.3/%',
    '2a. with the first two skills already characterized, the session opens at the third');
  perform t.assert(v_route not like '%NST.FR.1%' and v_route not like '%NST.FR.2%',
    '2b. and never asks about the two it already has evidence for');
end $$;
rollback;

begin;
do $$
declare v_route text; v_ss uuid;
begin
  perform t.logout();
  v_ss := t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
     (select id from public.skills where code='NST.FR.1'), 'secure', 'P5 she is solid on this');
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', array['demonstrated']);
  perform t.assert(v_route not like '%NST.FR.1%',
    '3a. a skill a parent confirmed secure is not retested');
  perform t.assert(v_route like 'NST.FR.2/%',
    '3b. and the session opens at the next one instead');
end $$;
rollback;

-- =============================================================================
-- 5-7. Unsuccessful observations, the floor, and the single probe
-- =============================================================================

begin;
do $$
declare v_route text; v_state text;
begin
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', array['not_demonstrated']);
  select coalesce(ss.skill_state::text, '(none)') into v_state
    from public.student_skills ss
   where ss.student_id = '44444444-4444-4444-8444-00000000000d'
     and ss.skill_id = (select id from public.skills where code='NST.FR.1');
  perform t.assert_eq(coalesce(v_state,'(none)'), '(none)',
    '5a. one unsuccessful observation writes nothing at all to the profile');
  perform t.assert(v_route like '%NST.FR.1/uncertainty_probe/-%',
    '5b. and the session simply tries another way into the same skill');
end $$;
rollback;

begin;
do $$
declare v_route text;
begin
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated']);
  perform t.assert(v_route like '%[stop=frustration_floor]',
    '6a. two consecutive unsuccessful observations end the branch');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items si
       join public.skills k on k.id = si.skill_id
      where k.code = 'NST.FR.1' and si.student_id = '44444444-4444-4444-8444-00000000000d'), 2,
    '6b. after exactly two items - there is no downward staircase');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills
      where student_id = '44444444-4444-4444-8444-00000000000d'
        and skill_id = (select id from public.skills where code='NST.FR.1')), 0,
    '6c. and the floor changes nothing about the child');
end $$;
rollback;

begin;
do $$
declare v_route text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated','not_demonstrated']);
  perform t.assert(v_route like '%NST.FR.2/prerequisite_probe/%',
    '7a. the floor spends one probe on the nearest prerequisite it was taking on trust');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items
      where reason_code = 'prerequisite_probe'
        and student_id = '44444444-4444-4444-8444-00000000000d'), 1,
    '7b. exactly one, never a staircase');
  perform t.assert(v_route like '%[stop=frustration_floor]', '7c. and then the branch ends');
end $$;
rollback;

-- =============================================================================
-- 7A-7G. The prerequisite probe predicate, in full
-- =============================================================================
-- Approved 2026-09-11. After the floor, at most one probe, targeting a DIRECT
-- prerequisite of the floored skill that was not observed this session and is
-- not human-confirmed secure. Ties break on skill code. Nothing eligible means
-- no probe at all.

-- A. the prerequisite is established from the profile and unseen today
begin;
do $$
declare v_route text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated','demonstrated']);
  perform t.assert(v_route like '%NST.FR.2/prerequisite_probe/demonstrated%',
    '7A. a direct prerequisite taken on trust, unseen today, gets exactly one probe');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items where reason_code='prerequisite_probe'),
    1, '7A2. exactly one');
end $$;
rollback;

-- B. the prerequisite was demonstrated during this very session
begin;
do $$
declare v_route text;
begin
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['demonstrated','demonstrated','not_demonstrated','not_demonstrated']);
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items where reason_code='prerequisite_probe'),
    0, '7B. a prerequisite she demonstrated twenty minutes ago is not asked again');
  perform t.assert(v_route like '%[stop=frustration_floor]', '7B2. the branch simply ends');
end $$;
rollback;

-- C. the prerequisite is human-confirmed secure
begin;
do $$
declare v_route text; v_before text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
     (select id from public.skills where code='NST.FR.2'), 'secure', 'P5 she is solid here');
  perform t.logout();
  select ss.skill_state::text into v_before from public.student_skills ss
   where ss.student_id='44444444-4444-4444-8444-00000000000d'
     and ss.skill_id=(select id from public.skills where code='NST.FR.2');

  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated']);
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items where reason_code='prerequisite_probe'),
    0, '7C. a prerequisite a parent confirmed secure is not re-tested because the next skill went badly');
  perform t.assert(v_route not like '%NST.FR.2%', '7C2. it is not asked about at all');

  -- G, on the same fixture: her judgement is exactly where she left it
  perform t.assert_eq(
    (select ss.skill_state::text from public.student_skills ss
      where ss.student_id='44444444-4444-4444-8444-00000000000d'
        and ss.skill_id=(select id from public.skills where code='NST.FR.2')),
    v_before, '7G. and the secure state is untouched by the failure downstream');
  perform t.assert_eq(v_before, 'secure', '7G2. which is to say: still secure');
end $$;
rollback;

-- D. two equally-near prerequisites, one deterministic choice
begin;
do $$
declare v_route text; a text; b text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.3','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.4','11111111-1111-4111-8111-000000000001');
  -- NST.FR.5 has two direct prerequisites, FR.3 and FR.4, and both are eligible
  a := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                '11111111-1111-4111-8111-000000000001',
                array['not_demonstrated','not_demonstrated','demonstrated']);
  perform t.assert(a like '%NST.FR.5/explore_next_skill%', '7D. the session opens at the only unestablished skill');
  perform t.assert(a like '%NST.FR.3/prerequisite_probe/%',
    '7D2. and the tie between two equally-near prerequisites breaks on skill code');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items where reason_code='prerequisite_probe'),
    1, '7D3. one probe, not two');
  b := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                '11111111-1111-4111-8111-000000000001',
                array['not_demonstrated','not_demonstrated','demonstrated']);
  perform t.assert_eq(a, b, '7D4. and the same tie breaks the same way every time');
end $$;
rollback;

-- E. the probe itself does not demonstrate the skill
begin;
do $$
declare v_route text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated','not_demonstrated','not_demonstrated']);
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items where reason_code='prerequisite_probe'),
    1, '7E. a probe that does not go well does not produce a second, deeper probe');
  perform t.assert(v_route like '%[stop=frustration_floor]', '7E2. the branch ends there');
  perform t.assert_eq(
    (select ss.skill_state::text from public.student_skills ss
      where ss.student_id='44444444-4444-4444-8444-00000000000d'
        and ss.skill_id=(select id from public.skills where code='NST.FR.2')),
    'developing', '7E3. and the probed skill keeps the state it had');
end $$;
rollback;

-- F. nothing is eligible, because the floored skill has no prerequisites at all
begin;
do $$
declare v_route text;
begin
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated']);
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items where reason_code='prerequisite_probe'),
    0, '7F. a skill with no prerequisites offers nothing to probe');
  perform t.assert(v_route like '%[stop=frustration_floor]', '7F2. so the branch ends immediately');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items), 2,
    '7F3. after exactly the two items that reached the floor');
end $$;
rollback;

-- =============================================================================
-- 8, 9, 24. Skip and not-today are not failures
-- =============================================================================

begin;
do $$
declare v_route text; j jsonb; si uuid; v_sess uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid; si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si, 'skipped', 'P5');
  perform t.assert_eq((j->'session_state'->>'consecutive_not_demonstrated'), '0',
    '8a. a skip does not touch the unsuccessful counter');
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si, 'not_today', 'P5');
  perform t.assert_eq((j->'session_state'->>'consecutive_not_demonstrated'), '0',
    '9a. nor does "not today"');
  perform t.assert_eq((j->'session_state'->>'floored'), 'false',
    '24a. two of them in a row cannot reach the frustration floor');
  perform t.assert(not ((j->>'next')::jsonb ? 'stop_reason'),
    '24b. and the session carries on rather than ending');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills
      where student_id = '44444444-4444-4444-8444-00000000000d'
        and skill_id = (select id from public.skills where code='NST.FR.1')), 0,
    '24c. neither writes anything about the child');
end $$;
rollback;

-- =============================================================================
-- 10. Stopping early keeps what was already seen
-- =============================================================================

begin;
do $$
declare j jsonb; si uuid; v_sess uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid; si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si, 'demonstrated', 'P5 she got it');
  j := public.stop_diagnostic_session(v_sess, 'P5 bedtime');
  perform t.assert_eq(j->>'observations_preserved', '1',
    '10a. stopping preserves the observation already gathered');
  perform t.assert_eq(j->>'stop_reason', 'parent_stopped', '10b. recorded as her decision');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_observations where session_id = v_sess), 1,
    '10c. and it is still there afterwards');
end $$;
rollback;

-- =============================================================================
-- 11. A conflicting observation is preserved and regresses nothing
-- =============================================================================

begin;
do $$
declare v_route text; v_before text; v_after text;
begin
  perform t.logout();
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.1','11111111-1111-4111-8111-000000000001');
  perform t.p5_establish('44444444-4444-4444-8444-00000000000d','NST.FR.2','11111111-1111-4111-8111-000000000001');
  select ss.skill_state::text || '/' || ss.computed_state::text into v_before
    from public.student_skills ss
   where ss.student_id='44444444-4444-4444-8444-00000000000d'
     and ss.skill_id=(select id from public.skills where code='NST.FR.2');

  -- the probe lands on FR.2 and the child does not demonstrate it today
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated','not_demonstrated']);

  select ss.skill_state::text || '/' || ss.computed_state::text into v_after
    from public.student_skills ss
   where ss.student_id='44444444-4444-4444-8444-00000000000d'
     and ss.skill_id=(select id from public.skills where code='NST.FR.2');
  perform t.assert_eq(v_after, v_before,
    '11a. an observation contradicting an established skill regresses nothing');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_observations o
       join public.skills k on k.id = o.skill_id
      where k.code = 'NST.FR.2' and o.outcome = 'not_demonstrated'), 1,
    '11b. while the contradicting observation is kept in full');
end $$;
rollback;

-- =============================================================================
-- 12-13. Unreviewed proposals, and the loop that must not exist
-- =============================================================================

begin;
do $$
declare v_ss uuid; v_sk uuid; v_org uuid; v_route text;
begin
  perform t.logout();
  select id into v_sk from public.skills where code='NST.FR.1';
  select primary_organization_id into v_org from public.students
   where id='44444444-4444-4444-8444-00000000000d';
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, created_by)
  values ('44444444-4444-4444-8444-00000000000d', v_sk, v_org,'manual','human_entered','unknown','unknown',
          '11111111-1111-4111-8111-000000000001') returning id into v_ss;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id, organization_id,
           occurred_on, evidence_note, skill_state, source_type, evidence_source,
           record_provenance, created_by)
  values (v_ss,'44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date - 5,'P5 machine',
          'unknown','ai_suggestion','diagnostic_session','ai_proposed_unreviewed',
          '11111111-1111-4111-8111-000000000001'),
         (v_ss,'44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date - 4,'P5 machine',
          'unknown','ai_suggestion','diagnostic_session','ai_proposed_unreviewed',
          '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.recompute_student_skill('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();

  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', array['demonstrated']);
  perform t.assert(v_route like 'NST.FR.1/%',
    '12a. two unreviewed machine proposals do not establish a skill, so it is still explored');
end $$;
rollback;

begin;
do $$
declare j jsonb; si uuid; v_sess uuid; v_events_before int; v_events_after int;
begin
  perform t.logout();
  select count(*)::int into v_events_before from public.student_skill_events;
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid; si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si, 'demonstrated','P5');
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si, 'demonstrated','P5');
  select count(*)::int into v_events_after from public.student_skill_events;

  perform t.assert_eq(v_events_after, v_events_before,
    '13a. THE LOOP: two demonstrated observations wrote not one evidence row');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills
      where student_id='44444444-4444-4444-8444-00000000000d'
        and skill_id=(select id from public.skills where code='NST.FR.1')), 0,
    '13b. and no profile row, so the routing cannot read its own guess back');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_observations
      where session_id = v_sess and review_status = 'pending'), 2,
    '13c. they are proposals awaiting a person, and nothing more');
  perform t.assert(
    not app.diagnostic_established('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1')),
    '13d. the profile still establishes nothing about the skill it just explored');
end $$;
rollback;

-- =============================================================================
-- 14-18. The route is a function of evidence, and of nothing else
-- =============================================================================

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  a := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  b := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.assert_eq(a, b, '14a. the same child, evidence and responses produce the same route');
end $$;
rollback;

begin;
do $$
declare a text; b text; c text; d text; v_map uuid;
begin
  perform t.logout();
  a := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.logout();
  insert into public.skill_standards (skill_id, standard_id, relation, created_by)
  select (select id from public.skills where code='NST.FR.1'), s.id, 'exact',
         '11111111-1111-4111-8111-000000000001' from public.standards s limit 1
  returning id into v_map;
  b := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.logout();
  delete from public.skill_standards where id = v_map;
  c := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.logout();
  alter table public.standards       rename to standards_hidden_p5;
  alter table public.skill_standards rename to skill_standards_hidden_p5;
  d := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);

  perform t.assert_eq(a, b, '16a. adding a benchmark mapping does not change the route');
  perform t.assert_eq(b, c, '16b. nor does removing it');
  perform t.assert_eq(c, d, '15a. nor does the catalogue not being there at all');
end $$;
rollback;

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  update public.students set grade_level = '1' where id='44444444-4444-4444-8444-00000000000d';
  a := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.logout();
  update public.students set grade_level = '5' where id='44444444-4444-4444-8444-00000000000d';
  b := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.assert_eq(a, b,
    '17a. the same child in first grade and in fifth grade is asked exactly the same things');
end $$;
rollback;

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  update public.students set date_of_birth = current_date - interval '6 years'
   where id='44444444-4444-4444-8444-00000000000d';
  a := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.logout();
  update public.students set date_of_birth = current_date - interval '12 years'
   where id='44444444-4444-4444-8444-00000000000d';
  b := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
       '11111111-1111-4111-8111-000000000001', array['demonstrated','demonstrated','not_demonstrated']);
  perform t.assert_eq(a, b, '18a. and a six-year-old and a twelve-year-old get the same route');
end $$;
rollback;

-- =============================================================================
-- 19. One family cannot reach another
-- =============================================================================

begin;
do $$
declare j jsonb; v_sess uuid; ok boolean;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  perform t.logout();

  perform t.login('11111111-1111-4111-8111-000000000003');   -- Diego, another family
  ok := false;
  begin perform public.explain_diagnostic_session(v_sess); exception when others then ok := true; end;
  perform t.assert(ok, '19a. another family''s parent cannot read the session');
  ok := false;
  begin perform public.stop_diagnostic_session(v_sess,'P5'); exception when others then ok := true; end;
  perform t.assert(ok, '19b. nor stop it');
  ok := false;
  begin perform public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
          (select id from public.skills where code='NST.FR.1')); exception when others then ok := true; end;
  perform t.assert(ok, '19c. nor start one for a child who is not his');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_sessions where id = v_sess), 0,
    '19d. and he cannot see that it exists');

  -- a view-only guardian may watch, not drive
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000002');
  perform t.assert(public.explain_diagnostic_session(v_sess) ? 'route',
    '19e. a view-only guardian may read the route');
  ok := false;
  begin perform public.stop_diagnostic_session(v_sess,'P5'); exception when others then ok := true; end;
  perform t.assert(ok, '19f. but may not stop the session');
end $$;
rollback;

-- =============================================================================
-- 20. Pause, resume, and the rule version
-- =============================================================================

begin;
do $$
declare j jsonb; v_sess uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  perform t.assert_eq(j->>'rule_version', app.diagnostic_rule_version(),
    '20a. the session records the rules it is being routed under');

  j := public.pause_diagnostic_session(v_sess);
  perform t.assert_eq(j->>'status','paused','20b. it pauses');
  j := public.resume_diagnostic_session(v_sess);
  perform t.assert_eq(j->>'resumed','true','20c. and resumes under the same rules');
  perform t.assert_eq(j->>'rule_version', app.diagnostic_rule_version(), '20d. unchanged');

  -- the engine moves on while a session is paused
  perform public.pause_diagnostic_session(v_sess);
  perform t.logout();
  create or replace function app.diagnostic_rule_version()
  returns text language sql immutable set search_path = '' as $v$ select '2099-01-01.9'::text; $v$;
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.resume_diagnostic_session(v_sess);
  perform t.assert_eq(j->>'resumed','false',
    '20e. a paused session does not silently resume under new rules');
  perform t.assert_eq(j->>'reason','rule_version_changed','20f. and says exactly why');
  perform t.assert_eq(j->>'session_rule_version','2026-09-11.1',
    '20g. still carrying the version it was routed under');
  perform t.assert_eq((select s.status::text from public.diagnostic_sessions s where s.id=v_sess),
    'paused', '20h. and is left exactly as it was, for a person to decide about');
end $$;
rollback;

-- =============================================================================
-- 21-22. No number, and no automatic secure
-- =============================================================================

select t.assert_eq(
  (select count(*)::int from information_schema.columns
    where table_schema='public' and table_name like 'diagnostic%'
      and (column_name ~ '(score|percent|percentile|mastery|grade_level|grade_equivalent|rank|ability)'
           or data_type in ('numeric','real','double precision'))),
  0, '21a. no diagnostic table holds a score, a percentage or an ability');

select t.assert_eq(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('app','public') and p.proname like '%diagnostic%'
      and p.prosrc ~* '(percentile|grade_equivalent|placement|ability_score)'),
  0, '21b. and nothing in the diagnostic path computes one');

begin;
do $$
declare j jsonb; si uuid; v_sess uuid; v_obs uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid; si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'demonstrated','P5');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;

  j := public.confirm_diagnostic_observation(v_obs, 'developing', 'P5 I saw her do it');
  perform t.assert_eq(j->>'computed_state','emerging',
    '22a. a confirmed observation becomes evidence and is held to the one-item ceiling');
  perform t.assert(j->>'computed_state' <> 'secure',
    '22b. and can never arrive at secure on its own');
  perform t.assert_eq(
    (select count(*)::int from public.student_skill_events e
      where e.evidence_source = 'diagnostic_session'
        and e.record_provenance = 'human_confirmed_system_observation'), 1,
    '22c. recorded as a diagnostic observation a person confirmed');
  perform t.assert_eq(
    (select o.review_status::text from public.diagnostic_observations o where o.id = v_obs),
    'confirmed', '22d. and the proposal is marked reviewed');
end $$;
rollback;

-- =============================================================================
-- 23. A hard afternoon with fractions is not a fact about reading
-- =============================================================================

begin;
do $$
declare v_route text;
begin
  perform t.logout();
  v_route := t.p5_run('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001',
                      array['not_demonstrated','not_demonstrated']);
  perform t.assert(v_route like '%[stop=frustration_floor]', '23a. the fractions branch floored');
  perform t.assert(v_route not like '%READ%',
    '23b. and never left the branch it was exploring');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code like 'READ.%'), 0,
    '23c. reading is untouched - there is no general ability to contaminate');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items si join public.skills k on k.id=si.skill_id
      where k.code like 'READ.%'), 0,
    '23d. and no reading item was presented');
end $$;
rollback;

-- =============================================================================
-- The guards are alive
-- =============================================================================

begin;
do $$
declare v_err text;
begin
  create or replace function app.diagnostic_established(p_student uuid, p_skill uuid)
  returns boolean language sql stable set search_path = '' as $bad$
    select (select st.grade_level from public.students st where st.id = p_student) is not null;
  $bad$;
  begin perform app.assert_schema_invariants(); v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  perform t.assert_eq(v_err,'REFUSED','G1. routing on grade level fails the invariants');
end $$;
rollback;

begin;
do $$
declare v_err text;
begin
  create or replace function app.diagnostic_branch(p_root uuid)
  returns table (skill_id uuid, depth integer, code text)
  language sql stable set search_path = '' as $bad$
    select s.id, 0, 'x'::text from public.standards s limit 1;
  $bad$;
  begin perform app.assert_schema_invariants(); v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  perform t.assert_eq(v_err,'REFUSED','G2. routing on the standards catalogue fails them');
end $$;
rollback;

begin;
do $$
declare v_err text;
begin
  create or replace function app.diagnostic_next(p_session uuid)
  returns jsonb language plpgsql set search_path = '' as $bad$
  begin
    update public.student_skills set skill_state = 'developing' where id = p_session;
    return '{}'::jsonb;
  end $bad$;
  begin perform app.assert_schema_invariants(); v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  perform t.assert_eq(v_err,'REFUSED','G3. routing that writes to the profile fails them');
end $$;
rollback;

begin;
do $$
declare v_err text;
begin
  alter type app.diagnostic_outcome add value 'skipped_counts_as_failure';
  begin perform app.assert_schema_invariants(); v_err := 'NO ERROR';
  exception when others then v_err := 'REFUSED'; end;
  perform t.assert_eq(v_err,'REFUSED',
    'G4. a fifth outcome - one that could make a skip into a failure - fails them');
end $$;
rollback;

-- =============================================================================
-- STEP 6 and the earlier phases, untouched
-- =============================================================================

select t.assert_eq((select count(*)::int from public.standards), 184,
  'Z1. the published catalogue is unchanged');
select t.assert_eq((select count(*)::int from public.skill_standards), 0,
  'Z2. no skill acquired a mapping');
select t.assert_eq((select count(*)::int from public.skill_prerequisites
                     where source_type in ('import','ai_suggestion')), 0,
  'Z3. no prerequisite was created');
select t.assert_eq((select count(*)::int from public.diagnostic_items where is_seed), 19,
  'Z4. nineteen seed items across the slice');

-- =============================================================================
-- 25. Provenance: a deterministic observation is not an AI proposal
-- =============================================================================
-- The engine in 0093 is arithmetic over the prerequisite graph and the child's
-- own profile. No model is consulted and none can be. Labelling its evidence
-- `human_confirmed_ai_proposal` told a parent - and any evaluator reading her
-- portfolio - that a model had proposed something about her child, which is
-- false in the one column somebody would read to find out.
--
-- The four meanings, kept apart:
--   human_entered                       a person originated it.
--   human_confirmed_ai_proposal         a model proposed it, a person said yes.
--   human_confirmed_system_observation  Nestra observed it deterministically,
--                                       a person said yes.
--   system_computed                     derived, with no confirmation behind it.

select t.assert_eq(
  (select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
     from pg_enum e join pg_type ty on ty.oid = e.enumtypid
     join pg_namespace n on n.oid = ty.typnamespace
    where n.nspname = 'app' and ty.typname = 'record_provenance'),
  'human_entered, human_confirmed_ai_proposal, human_confirmed_system_observation, '
  || 'ai_proposed_unreviewed, document_extraction, provider_import, system_computed, unknown',
  '25a. the new label sits beside the one it is distinguished from');

select t.assert_eq(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app','public')
      and p.proname in ('confirm_diagnostic_observation','reject_diagnostic_observation',
                        'record_diagnostic_observation','start_diagnostic_session',
                        'diagnostic_present','diagnostic_finish')
      and p.prosrc ~ '\mhuman_confirmed_ai_proposal\M'),
  0, '25b. no diagnostic function so much as mentions the AI-proposal label');

begin;
do $$
declare j jsonb; si uuid; v_sess uuid; v_obs uuid; e record; v jsonb;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid; si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'demonstrated','P5');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;

  -- Before any human looks at it, the observation is not evidence at all.
  perform t.assert_eq(
    (select count(*)::int from public.student_skill_events e2
      where e2.evidence_source = 'diagnostic_session'), 0,
    '25c. an unreviewed observation has written no evidence');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id = ss.skill_id
      where ss.student_id = '44444444-4444-4444-8444-00000000000d'
        and k.code like 'NST.FR.%'), 0,
    '25d. and no profile row - recording an observation changes nothing about the child');

  j := public.confirm_diagnostic_observation(v_obs, 'developing', 'P5 I watched her');

  select e2.record_provenance::text as prov, e2.evidence_source::text as src,
         e2.ai_suggestion_id as sug
    into e
    from public.student_skill_events e2
   where e2.id = (select o.promoted_event_id from public.diagnostic_observations o
                   where o.id = v_obs);

  perform t.assert_eq(e.prov, 'human_confirmed_system_observation',
    '25e. a confirmed diagnostic observation is a confirmed SYSTEM observation');
  perform t.assert_eq(e.src, 'diagnostic_session',
    '25f. and the evidence source is still the diagnostic session');
  perform t.assert(e.sug is null,
    '25g. it names no AI suggestion, because there was never one to name');

  -- It is evidence a person stands behind, and must still be counted as such.
  v := app.compute_skill_state('44444444-4444-4444-8444-00000000000d',
                               (select id from public.skills where code='NST.FR.1'));
  perform t.assert_eq((v->>'usable_evidence_count')::int, 1,
    '25h. the confirmed observation is usable evidence');
  perform t.assert_eq((v->'sufficiency_inputs'->>'human_entered_or_confirmed')::int, 1,
    '25i. and counts as an observation a person stands behind, as it did before');
  perform t.assert_eq(v->>'rule_version', '2026-09-09.2',
    '25j. under the unchanged profile rule version');
  perform t.assert(v->>'computed_state' <> 'secure',
    '25k. and still cannot arrive at secure');
end $$;
rollback;

-- An observation the parent rejected never becomes evidence under any label.
begin;
do $$
declare j jsonb; si uuid; v_obs uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'demonstrated','P5');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;
  perform public.reject_diagnostic_observation(v_obs, 'P5 that was me helping');
  perform t.assert_eq(
    (select count(*)::int from public.student_skill_events e
      where e.evidence_source = 'diagnostic_session'), 0,
    '25l. a rejected observation writes no evidence of any provenance');
end $$;
rollback;

-- The old label is refused for diagnostic evidence, not merely unwritten.
begin;
do $$
declare v_ss uuid; v_sk uuid; v_org uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.1';
  select primary_organization_id into v_org from public.students
   where id = '44444444-4444-4444-8444-00000000000d';
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, created_by)
  values ('44444444-4444-4444-8444-00000000000d', v_sk, v_org, 'observation',
          'human_entered', 'diagnostic_session', 'unknown',
          '11111111-1111-4111-8111-000000000001')
  returning id into v_ss;

  begin
    insert into public.student_skill_events (student_skill_id, student_id, skill_id,
             organization_id, occurred_on, evidence_note, skill_state, source_type,
             evidence_source, record_provenance, created_by)
    values (v_ss, '44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date,
            'P5', 'developing', 'observation', 'diagnostic_session',
            'human_confirmed_ai_proposal', '11111111-1111-4111-8111-000000000001');
    perform t.assert(false,
      '25m. diagnostic evidence was accepted as a confirmed AI proposal');
  exception when check_violation then
    perform t.assert(true,
      '25m. diagnostic evidence naming no suggestion cannot claim a model proposed it');
  end;

  -- Evidence from anywhere else is untouched by this rule: a genuine confirmed
  -- AI proposal is still a genuine confirmed AI proposal.
  insert into public.student_skill_events (student_skill_id, student_id, skill_id,
           organization_id, occurred_on, evidence_note, skill_state, source_type,
           evidence_source, record_provenance, created_by)
  values (v_ss, '44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date,
          'P5 elsewhere', 'developing', 'observation', 'portfolio_artifact',
          'human_confirmed_ai_proposal', '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(
    (select count(*)::int from public.student_skill_events e
      where e.evidence_note = 'P5 elsewhere'
        and e.record_provenance = 'human_confirmed_ai_proposal'), 1,
    '25n. confirmed AI proposals from elsewhere are unaffected');
end $$;
rollback;

-- The invariant refuses a confirm path that goes back to the old label. This is
-- the test that would have caught the original mistake.
begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.confirm_diagnostic_observation(
      p_observation uuid, p_skill_state text default null, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      -- 'human_confirmed_ai_proposal'
      return jsonb_build_object('observation', p_observation);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false,
      '25o. the invariants accepted a confirm path that calls its evidence an AI proposal');
  exception when others then
    perform t.assert(sqlerrm like '%false provenance%',
      '25o. the invariants refuse a confirm path that calls its evidence an AI proposal');
  end;
end $$;
rollback;

-- And refuses the loss of the constraint behind it.
begin;
do $$
begin
  perform t.logout();
  alter table public.student_skill_events
    drop constraint sse_diagnostic_evidence_is_not_an_ai_proposal_ck;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, '25p. the invariants accepted the constraint being dropped');
  exception when others then
    perform t.assert(sqlerrm like '%recorded as an AI proposal%',
      '25p. the invariants refuse the loss of the constraint behind it');
  end;
end $$;
rollback;
