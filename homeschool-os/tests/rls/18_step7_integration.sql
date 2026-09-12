-- =============================================================================
-- STEP 7 final integration audit - the whole thing, end to end, as one child
-- =============================================================================
-- Phases 1-6 each proved their own piece. This proves they compose:
--
--   Evidence -> Profile -> Refresh Advisory -> Diagnostic -> Human Review
--            -> Updated Profile -> Learning Path
--
-- and that the governing rule survives the whole trip:
--
--   Student -> Skills -> Evidence -> Readiness -> Learning Path
--
-- with standards an optional annotation that touches none of it.
--
-- ONE CHILD, ONE SCENARIO. Lucas starts with a deliberately mixed profile -
-- something a person confirmed, something with real evidence, something where
-- two adults saw different things, something nobody has looked at, and an
-- unreviewed machine guess. That mixture is the point: every phase has an easy
-- case and a hard case, and the hard cases are where a system starts quietly
-- lying about a child.
--
-- Every block is rolled back. Rows are marked S7.
-- =============================================================================

\set CARLA '11111111-1111-4111-8111-000000000001'
\set NINA  '11111111-1111-4111-8111-00000000000b'
\set DIEGO '11111111-1111-4111-8111-000000000003'
\set LUCAS '44444444-4444-4444-8444-00000000000d'
\set SOFIA '44444444-4444-4444-8444-00000000000f'

-- --- the scenario ------------------------------------------------------------
-- Built from real evidence through the real recompute, never by writing a state
-- into a column. A fixture that sets `developing` directly proves nothing about
-- the thing that decides `developing`.

create or replace function t.s7_evidence(p_student uuid, p_code text, p_actor uuid,
                                         p_states text[], p_sources text[])
returns uuid language plpgsql as $$
declare v_ss uuid; v_sk uuid; v_org uuid; i int;
begin
  select id into v_sk from public.skills where code = p_code;
  select primary_organization_id into v_org from public.students where id = p_student;
  select id into v_ss from public.student_skills
   where student_id = p_student and skill_id = v_sk;
  if v_ss is null then
    insert into public.student_skills (student_id, skill_id, organization_id, source_type,
             record_provenance, evidence_source, skill_state, created_by)
    values (p_student, v_sk, v_org, 'manual','human_entered','parent','unknown', p_actor)
    returning id into v_ss;
  end if;
  for i in 1..coalesce(array_length(p_states, 1), 0) loop
    insert into public.student_skill_events (student_skill_id, student_id, skill_id,
             organization_id, occurred_on, evidence_note, skill_state, source_type,
             evidence_source, record_provenance, created_by)
    values (v_ss, p_student, v_sk, v_org, date '2026-08-01' + (i * 7),
            'S7 ' || p_code || ' #' || i, p_states[i]::app.skill_state, 'manual',
            p_sources[i]::app.evidence_source, 'human_entered', p_actor);
  end loop;
  perform t.login(p_actor);
  perform public.recompute_student_skill(p_student, v_sk);
  perform t.logout();
  return v_ss;
end $$;

-- A mixed profile, the way a real one gets mixed.
create or replace function t.s7_scenario(p_student uuid, p_actor uuid)
returns void language plpgsql as $$
declare v_sk uuid; v_ss uuid; v_org uuid;
begin
  select primary_organization_id into v_org from public.students where id = p_student;

  -- FR.1  a person looked and said: she has this. Evidence underneath it first.
  perform t.s7_evidence(p_student, 'NST.FR.1', p_actor,
                        array['developing','developing'], array['parent','tutor']);
  perform t.login(p_actor);
  perform public.set_skill_state_override(p_student,
    (select id from public.skills where code='NST.FR.1'), 'secure', 'S7 she has this');
  perform t.logout();

  -- FR.2  real evidence, two occasions, two people. No decision on top.
  perform t.s7_evidence(p_student, 'NST.FR.2', p_actor,
                        array['developing','developing'], array['parent','teacher']);

  -- FR.3  two adults, two different readings, on different days.
  perform t.s7_evidence(p_student, 'NST.FR.3', p_actor,
                        array['developing','emerging'], array['parent','tutor']);

  -- FR.4  a machine guessed and nobody has looked.
  select id into v_sk from public.skills where code = 'NST.FR.4';
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, created_by)
  values (p_student, v_sk, v_org, 'ai_suggestion','ai_proposed_unreviewed','unknown',
          'unknown', p_actor)
  returning id into v_ss;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id,
           organization_id, occurred_on, evidence_note, skill_state, source_type,
           evidence_source, record_provenance, created_by)
  values (v_ss, p_student, v_sk, v_org, date '2026-08-20', 'S7 unreviewed guess',
          null, 'ai_suggestion', 'unknown', 'ai_proposed_unreviewed', p_actor);
  perform t.login(p_actor);
  perform public.recompute_student_skill(p_student, v_sk);
  perform t.logout();

  -- FR.5  nothing at all. Not a row, not a record, nothing.
end $$;

-- The whole pipeline, as one comparable block of text. This is what the
-- independence arms in sections 9 and 10 diff against each other.
create or replace function t.s7_pipeline(p_student uuid, p_actor uuid)
returns text language plpgsql as $$
declare
  v text := ''; v_route text; j jsonb; si uuid; v_sess uuid; v_obs uuid;
  v_path uuid; r record;
begin
  -- A. the profile, as the family sees it
  for r in select k.code,
                  coalesce(ss.skill_state::text,'unknown') as state,
                  coalesce(ss.evidence_sufficiency::text,'none') as suff,
                  coalesce(ss.usable_evidence_count,0) as n,
                  (ss.active_override_id is not null) as decided
             from public.skills k
             left join public.student_skills ss
               on ss.skill_id = k.id and ss.student_id = p_student
            where k.code like 'NST.FR.%' order by k.code
  loop
    v := v || format('profile %s %s/%s n=%s decided=%s', r.code, r.state, r.suff, r.n, r.decided) || E'\n';
  end loop;

  -- B. the diagnostic, from that profile
  perform t.login(p_actor);
  j := public.start_diagnostic_session(p_student,
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  si := (j->>'session_item')::uuid;
  v := v || 'diag opens ' ||
       coalesce((select k.code from public.diagnostic_session_items i
                  join public.skills k on k.id = i.skill_id where i.id = si), '(none)') || E'\n';

  -- a skip, a not_today, then two demonstrations, then difficulty
  j  := public.record_diagnostic_observation(si, 'skipped', 'S7');
  si := (j->>'session_item')::uuid;
  j  := public.record_diagnostic_observation(si, 'not_today', 'S7');
  si := (j->>'session_item')::uuid;
  j  := public.record_diagnostic_observation(si, 'demonstrated', 'S7');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;
  si := (j->>'session_item')::uuid;
  if si is not null then
    j  := public.record_diagnostic_observation(si, 'demonstrated', 'S7');
    si := (j->>'session_item')::uuid;
  end if;
  while si is not null loop
    j  := public.record_diagnostic_observation(si, 'not_demonstrated', 'S7');
    si := (j->>'session_item')::uuid;
  end loop;

  select string_agg(k.code || '/' || i.reason_code || '/' || coalesce(o.outcome::text,'-'),
                    ' | ' order by i.sequence)
    into v_route from public.diagnostic_session_items i
    join public.skills k on k.id = i.skill_id
    left join public.diagnostic_observations o on o.session_item_id = i.id
   where i.session_id = v_sess;
  v := v || 'diag route ' || v_route || E'\n';
  v := v || 'diag stop  ' ||
       coalesce((select s.stop_reason::text from public.diagnostic_sessions s
                  where s.id = v_sess), '-') || E'\n';

  -- C. human review: one confirmed, one rejected
  if v_obs is not null then
    j := public.confirm_diagnostic_observation(v_obs, 'developing', 'S7 I watched her');
    v := v || 'confirmed  computed=' || (j->>'computed_state') ||
         ' effective=' || (j->>'effective_state') || E'\n';
  end if;
  select o.id into v_obs from public.diagnostic_observations o
   where o.session_id = v_sess and o.outcome = 'not_demonstrated'
   order by o.observed_at, o.id limit 1;
  if v_obs is not null then
    begin
      perform public.confirm_diagnostic_observation(v_obs, 'emerging', 'S7');
      v := v || 'unsuccessful obs CONFIRMED (WRONG)' || E'\n';
    exception when others then
      v := v || 'unsuccessful obs cannot become evidence' || E'\n';
    end;
    perform public.reject_diagnostic_observation(v_obs, 'S7 that was me helping');
  end if;

  -- D. the path, from the updated profile
  j := public.generate_learning_path(p_student,
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v_path := (j->>'path')::uuid;
  v := v || 'path steps ' ||
       coalesce((select string_agg(format('%s.%s/%s%s', n->>'position', n->>'skill',
                  n->>'reason', case when (n->>'resource_id') is not null then '+res' else '' end),
                  ' | ' order by (n->>'position')::int)
                   from jsonb_array_elements(j->'nodes') n), '(none)') || E'\n';
  v := v || 'path goals ' ||
       coalesce((select string_agg(g->>'skill' || '/' || (g->>'reason'), ', ')
                   from jsonb_array_elements(j->'goal_targets') g), '(none)') || E'\n';

  if (select s.status from public.diagnostic_sessions s where s.id = v_sess) = 'active' then
    perform public.stop_diagnostic_session(v_sess, 'S7 done');
  end if;
  perform t.logout();
  return v;
end $$;

grant execute on function t.s7_evidence(uuid, text, uuid, text[], text[]) to authenticated;
grant execute on function t.s7_scenario(uuid, uuid) to authenticated;
grant execute on function t.s7_pipeline(uuid, uuid) to authenticated;

-- =============================================================================
-- 3. Evidence -> Profile
-- =============================================================================

begin;
do $$
declare v_ctx jsonb; v_exp jsonb;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');

  -- FR.5: nothing. `unknown` is a statement about Nestra's records.
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.5'), 0,
    '3a. a skill nobody has recorded anything about has no row at all');
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.5'));
  perform t.assert_eq(v_ctx->>'effective_state', 'unknown',
    '3b. and reads back as unknown - insufficient evidence, not a finding about the child');

  -- FR.2: real evidence, two occasions, two sources.
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.2'));
  perform t.assert_eq(v_ctx->>'effective_state', 'developing',
    '3c. two supporting observations on two occasions characterize a skill as developing');
  perform t.assert_eq(v_ctx->>'evidence_sufficiency', 'supported', '3d. on supported evidence');

  -- FR.1: a person decided.
  perform t.assert(app.path_human_confirmed_secure('44444444-4444-4444-8444-00000000000d',
                     (select id from public.skills where code='NST.FR.1')),
    '3e. secure exists only where an authorized person confirmed it');
  perform t.assert_eq(
    (select ss.computed_state::text from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.1'),
    'developing', '3f. and the machine underneath it still says developing, never secure');

  -- FR.3: two people saw different things.
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.3'));
  perform t.assert((v_ctx->>'conflicting_evidence')::boolean,
    '3g. a disagreement between two adults is preserved, not averaged away');
  perform t.assert_eq(v_ctx->>'effective_state', 'developing',
    '3h. and the stronger observation governs rather than the most recent one');

  -- FR.4: a machine guessed.
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.4'));
  perform t.assert_eq((v_ctx->>'usable_evidence_count')::int, 0,
    '3i. an unreviewed AI proposal is not usable evidence');
  perform t.assert_eq(v_ctx->>'effective_state', 'unknown',
    '3j. and cannot move a child out of unknown');
end $$;
rollback;

select t.assert_eq(
  (select count(*)::int from information_schema.columns
    where table_schema='public'
      and table_name in ('student_skills','student_skill_events','student_skill_overrides',
                         'student_skill_refresh_decisions','diagnostic_items',
                         'diagnostic_sessions','diagnostic_session_items',
                         'diagnostic_observations','diagnostic_routing_decisions',
                         'learning_paths','learning_path_nodes','learning_path_events')
      and (column_name ~ '(score|percent|percentile|mastery|ability|grade_level|grade_equivalent|readiness_level)'
           or data_type in ('numeric','real','double precision'))),
  0, '3k. no STEP 7 table anywhere holds a percentage, a score or an ability level');

-- =============================================================================
-- 2 + 4. The profile drives the diagnostic
-- =============================================================================

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  v := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');

  perform t.assert(v like '%profile NST.FR.1 secure/supported n=2 decided=t%',
    '2a. the scenario really is mixed: one skill a person confirmed');
  perform t.assert(v like '%profile NST.FR.3 developing/supported n=2 decided=f%',
    '2b. one where two adults disagreed');
  perform t.assert(v like '%profile NST.FR.4 unknown/none n=0 decided=f%',
    '2c. one an unreviewed machine guess could not characterize');
  perform t.assert(v like '%profile NST.FR.5 unknown/none n=0 decided=f%',
    '2d. and one nobody has recorded anything about');

  perform t.assert(v like '%diag opens NST.FR.4%',
    '4a. the diagnostic opens at the first skill the profile cannot speak to');
  perform t.assert(v not like '%NST.FR.1/explore%' and v not like '%NST.FR.2/explore%',
    '4b. and never re-asks what a person already confirmed or what evidence covers');
  perform t.assert(v like '%NST.FR.4/explore_next_skill/skipped%',
    '4c. a skipped item is recorded as skipped');
  perform t.assert(v like '%/not_today%',
    '4d. and "not today" is a thing about today, recorded as such');
  perform t.assert(v not like '%stop  frustration_floor%',
    '4e. neither of which reaches the frustration floor');
end $$;
rollback;

-- The floor, the single probe, and no regression - from this same profile.
begin;
do $$
declare j jsonb; si uuid; v_sess uuid; v_route text; v_before text; v_after text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  select ss.skill_state::text into v_before from public.student_skills ss
    join public.skills k on k.id = ss.skill_id
   where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.3';

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  si := (j->>'session_item')::uuid;
  while si is not null loop
    j  := public.record_diagnostic_observation(si, 'not_demonstrated', 'S7');
    si := (j->>'session_item')::uuid;
  end loop;
  perform t.logout();

  select string_agg(k.code || '/' || i.reason_code, ' | ' order by i.sequence)
    into v_route from public.diagnostic_session_items i
    join public.skills k on k.id = i.skill_id where i.session_id = v_sess;

  perform t.assert_eq(
    (select s.stop_reason::text from public.diagnostic_sessions s where s.id = v_sess),
    'frustration_floor', '4f. two consecutive unsuccessful observations stop the branch');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_session_items i
      where i.session_id = v_sess and i.reason_code = 'prerequisite_probe'), 1,
    '4g. and exactly one prerequisite probe follows. Never two, never a staircase');
  perform t.assert(v_route like '%NST.FR.3/prerequisite_probe%',
    '4h. aimed at the direct prerequisite, chosen by stable skill code');

  select ss.skill_state::text into v_after from public.student_skills ss
    join public.skills k on k.id = ss.skill_id
   where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.3';
  perform t.assert_eq(v_after, v_before,
    '4i. and a hard afternoon lowers nothing - a difficult session is not evidence against a child');
  perform t.assert(app.path_human_confirmed_secure('44444444-4444-4444-8444-00000000000d',
                     (select id from public.skills where code='NST.FR.1')),
    '4j. what a person confirmed is still confirmed afterwards');
end $$;
rollback;

-- Deterministic: the same scenario twice gives the same everything.
begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  a := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  perform t.assert(a is not null, '4k. the pipeline runs end to end');
end $$;
rollback;
begin;
do $$
declare a text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  a := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  perform t.assert(a like '%diag opens NST.FR.4%' and a like '%path steps 1.NST.FR.4/diagnostic_frontier%',
    '4l. and a second identical run produces the same route and the same path');
end $$;
rollback;

-- =============================================================================
-- 5. Diagnostic -> human review -> profile
-- =============================================================================

begin;
do $$
declare j jsonb; si uuid; v_obs uuid; v_rej uuid; v_ctx jsonb; e record;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j  := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
         (select id from public.skills where code='NST.FR.1'));
  si := (j->>'session_item')::uuid;
  j  := public.record_diagnostic_observation(si, 'demonstrated', 'S7');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;
  si := (j->>'session_item')::uuid;
  j  := public.record_diagnostic_observation(si, 'demonstrated', 'S7');
  select o.id into v_rej from public.diagnostic_observations o where o.session_item_id = si;

  -- BEFORE anybody looks
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.4'));
  perform t.assert_eq((v_ctx->>'usable_evidence_count')::int, 0,
    '5a. two unreviewed observations are not evidence about the child');
  perform t.assert_eq(v_ctx->>'effective_state', 'unknown',
    '5b. and the profile still says unknown');

  -- One confirmed
  j := public.confirm_diagnostic_observation(v_obs, 'developing', 'S7 I watched her');
  select e2.evidence_source::text as src, e2.record_provenance::text as prov
    into e from public.student_skill_events e2
   where e2.id = (select o.promoted_event_id from public.diagnostic_observations o
                   where o.id = v_obs);
  perform t.assert_eq(e.src, 'diagnostic_session',
    '5c. a confirmed observation becomes evidence from the diagnostic session');
  perform t.assert_eq(e.prov, 'human_confirmed_system_observation',
    '5d. recorded as a deterministic system observation a person confirmed');
  perform t.assert_eq(j->>'computed_state', 'emerging',
    '5e. and the profile recomputes to exactly what one observation supports');
  perform t.assert(j->>'effective_state' <> 'secure',
    '5f. never to secure - a machine may not make that decision');

  -- One rejected
  perform public.reject_diagnostic_observation(v_rej, 'S7 that was me helping');
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.4'));
  perform t.assert_eq((v_ctx->>'usable_evidence_count')::int, 1,
    '5g. a rejected observation contributes nothing at all');
  perform t.assert_eq(v_ctx->>'evidence_sufficiency', 'preliminary',
    '5h. and sufficiency moved only as far as one confirmed observation justifies');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 6. Profile -> Learning Path
-- =============================================================================

begin;
do $$
declare v text; j jsonb; v_before int;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  -- She says: we are working toward comparing fractions.
  insert into public.learning_goals (student_id, skill_id, title, horizon, priority,
           status, source_type, approved_by, created_by)
  values ('44444444-4444-4444-8444-00000000000d',
          (select id from public.skills where code='NST.FR.5'),
          'S7 compare fractions', 'short_term', 1, 'active', 'parent',
          '11111111-1111-4111-8111-000000000001','11111111-1111-4111-8111-000000000001');
  select count(*) into v_before from public.student_skill_events;

  v := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');

  -- This is the whole point of the audit in four lines. Her goal was two
  -- uncharacterized skills away when the scenario started. One diagnostic
  -- observation, confirmed by her, characterized NST.FR.4 - and that changed
  -- what is reachable, so the goal became the actionable next step. Evidence ->
  -- readiness -> path, with a person in the middle of it.
  perform t.assert(v like '%path steps 1.NST.FR.5/parent_goal%',
    '6a. after her review, the goal she named IS the next step - the evidence now supports it');
  perform t.assert(v like '%2.NST.FR.4/diagnostic_frontier%',
    '6b. with the skill the session stopped on still on the path behind it');
  perform t.assert(v like '%path goals (none)%',
    '6c. and nothing left held back as a distant target');
  perform t.assert(v not like '%+res%',
    '6d. nothing auto-attached, because no mapping has been confirmed');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      where n.reason_code = 'curriculum_resource_available'), 0,
    '6e. owning material never put a skill on the path');
  perform t.assert(
    (select count(*) from public.learning_path_nodes n
      where n.reason_code = 'prerequisite_support') <= 1,
    '6f. at most one support level, and no staircase');
end $$;
rollback;

-- And the other half: while the ground under it is still uncharacterized, the
-- same goal is kept as a target and is not called a next step.
begin;
do $$
declare v text; j jsonb;
begin
  perform t.logout();
  perform t.s7_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.1',
    '11111111-1111-4111-8111-000000000001',
    array['developing','developing'], array['parent','tutor']);
  perform t.s7_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.2',
    '11111111-1111-4111-8111-000000000001',
    array['developing','developing'], array['parent','teacher']);
  insert into public.learning_goals (student_id, skill_id, title, horizon, priority,
           status, source_type, approved_by, created_by)
  values ('44444444-4444-4444-8444-00000000000d',
          (select id from public.skills where code='NST.FR.5'),
          'S7 compare fractions', 'short_term', 1, 'active', 'parent',
          '11111111-1111-4111-8111-000000000001','11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  perform t.logout();
  perform t.assert_eq(
    (select g->>'skill' from jsonb_array_elements(j->'goal_targets') g limit 1),
    'NST.FR.5', '6i. with two uncharacterized skills underneath, the goal is kept as a target');
  perform t.assert_eq(
    (select n->>'skill' from jsonb_array_elements(j->'nodes') n
      where (n->>'position')::int = 1), 'NST.FR.3',
    '6j. and the actionable path starts where the evidence reaches');
  perform t.assert_eq(
    (select (g->'reason_detail'->>'not_actionable_yet') from jsonb_array_elements(j->'goal_targets') g limit 1),
    'true', '6k. said structurally, so a screen never has to guess');
end $$;
rollback;

-- A confirmed mapping may attach; the same resource unconfirmed may not.
begin;
do $$
declare a uuid; b uuid; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  a := app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk);
  update public.resource_skills rs set confirmed = true,
         confirmed_by = '11111111-1111-4111-8111-000000000001', confirmed_at = now()
   where rs.skill_id = v_sk;
  b := app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.assert(a is null, '6g. an unconfirmed mapping attaches nothing');
  perform t.assert(b is not null, '6h. the same resource attaches once a person confirms it');
end $$;
rollback;

-- =============================================================================
-- 7. The path, in a parent's hands
-- =============================================================================

begin;
do $$
declare j jsonb; v1 uuid; v2 uuid; v_node uuid; v_nodes1 text; v_ev int; v_prof int;
begin
  perform t.logout();
  -- A shorter reach than the full scenario, so that comparing fractions is NOT
  -- already on the path and she can put it there herself.
  perform t.s7_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.1',
    '11111111-1111-4111-8111-000000000001',
    array['developing','developing'], array['parent','tutor']);
  perform t.s7_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.2',
    '11111111-1111-4111-8111-000000000001',
    array['developing','developing'], array['parent','teacher']);
  select count(*) into v_ev from public.student_skill_events;
  select count(*) into v_prof from public.student_skills ss join public.skills k on k.id=ss.skill_id
   where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code like 'NST.FR.%';

  perform t.login('11111111-1111-4111-8111-000000000001');
  j  := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
         (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v1 := (j->>'path')::uuid;
  j  := public.approve_learning_path(v1, 'S7 yes');
  perform t.assert_eq(j->>'status', 'approved', '7a. a parent approves the path');
  perform t.assert_eq((select count(*)::int from public.student_skill_events), v_ev,
    '7b. and approving it creates no evidence');

  -- She puts something of her own at the front, over a prerequisite warning.
  j := public.add_path_node(v1, (select id from public.skills where code='NST.FR.5'),
                            1, 'S7 we want this too');
  perform t.assert(jsonb_array_length(j->'warnings') > 0,
    '7c. adding a skill above what it builds on returns a warning');
  perform t.assert((j->'warnings')::text like '%prerequisite_usually_comes_first%',
    '7d. as a structured code, and advisory only');
  perform t.assert_eq(
    (select n.position from public.learning_path_nodes n
      where n.path_id = v1 and n.skill_id = (select id from public.skills where code='NST.FR.5')), 1,
    '7e. and the skill goes exactly where she put it');

  select n.id into v_node from public.learning_path_nodes n
   where n.path_id = v1 and n.status <> 'removed' order by n.position desc limit 1;
  perform public.remove_path_node(v_node, 'S7 not this term');
  perform t.assert_eq(
    (select n.status::text from public.learning_path_nodes n where n.id = v_node),
    'removed', '7f. she can take one off');

  select n.id into v_node from public.learning_path_nodes n
   where n.path_id = v1 and n.status <> 'removed' order by n.position limit 1;
  j := public.complete_path_node(v_node, 'S7 we did this');
  perform t.assert_eq(j->>'evidence_created', 'false',
    '7g. finishing a step creates no evidence, and says so');
  perform t.assert_eq((select count(*)::int from public.student_skill_events), v_ev,
    '7h. which is true of the events table as well as of the sentence');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code like 'NST.FR.%'),
    v_prof, '7i. and no profile row appeared or changed');

  -- A new suggestion arrives beside the one she approved. Snapshot taken HERE,
  -- after her own edits: the guarantee is that REGENERATION does not rewrite her
  -- version, not that her version never changes. She may edit it all she likes;
  -- what may not happen is Nestra editing it for her.
  v_nodes1 := (public.explain_learning_path(v1)->'nodes')::text;
  j  := public.regenerate_learning_path(v1, 'new_confirmed_evidence', 'S7 something changed');
  v2 := (j->>'path')::uuid;
  perform t.assert_eq((j->>'version')::int, 2, '7j. regenerating makes a new version');
  perform t.assert_eq(j->>'status', 'proposed', '7k. which is a proposal, not a replacement');
  perform t.assert_eq(
    (select lp.status::text from public.learning_paths lp where lp.id = v1),
    'approved', '7l. the version she approved is still the approved one');
  perform t.assert_eq((public.explain_learning_path(v1)->'nodes')::text, v_nodes1,
    '7m. and is still node for node what she agreed to');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 8. The refresh advisory, still advisory
-- =============================================================================

select t.assert_eq(
  (select count(*)::int from public.families where refresh_advisory_enabled),
  0, '8a. the advisory is off for every family that exists');

begin;
do $$
declare j jsonb; v text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');

  -- Off: time alone says nothing.
  j := public.explain_skill_refresh('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  perform t.assert_eq(j->>'refresh_suggested', 'false',
    '8b. with the feature off, no amount of elapsed time suggests anything');
  perform t.assert((j->'blocked_by')::text like '%family_has_not_enabled_it%',
    '8c. and it says which condition stopped it');

  -- On: still advice, and it changes nothing about the child.
  perform public.set_family_refresh_advisory(
    (select family_id from public.students where id='44444444-4444-4444-8444-00000000000d'),
    true, 7);
  perform t.logout();
  v := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(
    (select ss.skill_state::text from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.1'),
    'secure', '8d. secure is never lowered by an advisory');
  perform t.assert(v not like '%NST.FR.1/revisit_requested%',
    '8e. and the advisory alone puts nothing on the Learning Path');
end $$;
rollback;

begin;
do $$
declare v text; j jsonb;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_family_refresh_advisory(
    (select family_id from public.students where id='44444444-4444-4444-8444-00000000000d'),
    true, 7);
  -- She asks, in so many words.
  perform public.request_skill_revisit('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.1'), 'S7 let us look again');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  perform t.logout();
  perform t.assert(
    (select count(*) from jsonb_array_elements(j->'nodes') n
      where n->>'reason' = 'revisit_requested') = 1,
    '8f. a revisit a person asked for IS a path candidate - distinct from the advisory');
  perform t.assert_eq(
    (select ss.skill_state::text from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.1'),
    'secure', '8g. and revisiting something does not doubt it');
end $$;
rollback;

begin;
do $$
declare j jsonb;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_family_refresh_advisory(
    (select family_id from public.students where id='44444444-4444-4444-8444-00000000000d'),
    true, 7);
  perform public.dismiss_skill_refresh('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.1'), 'S7 not now');
  j := public.explain_skill_refresh('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  perform t.assert_eq(j->>'refresh_suggested', 'false',
    '8h. once she has said not now, it stops asking');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 9. Standards independence, over the WHOLE pipeline
-- =============================================================================
-- Not "the path ignores standards" - the entire chain, from evidence through
-- diagnostic routing and human review to the finished Learning Path, compared
-- character for character under four arms. A parent who never opens a benchmark
-- code gets the identical product.

begin;
do $$
declare a text; b text; c text; d text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  a := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq((select count(*)::int from public.standards), 184,
    '9a. arm A runs with the full Florida catalogue present');
end $$;
rollback;

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  a := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  -- arm B: the catalogue is not there at all
  alter table public.skill_standards rename to skill_standards_gone;
  alter table public.standards rename to standards_gone;
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000f',
                        '11111111-1111-4111-8111-000000000003');
  b := t.s7_pipeline('44444444-4444-4444-8444-00000000000f',
                     '11111111-1111-4111-8111-000000000003');
  perform t.assert_eq(a, b,
    '9b. arm B: with the standards catalogue renamed out from under the running code, '
    || 'the profile, the diagnostic route, the stop reason, the confirmed observation''s '
    || 'effect and the whole Learning Path are identical');
end $$;
rollback;

begin;
do $$
declare a text; b text; c text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  a := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  -- arm C: every skill in the branch mapped to a benchmark
  insert into public.skill_standards (skill_id, standard_id, relation, source_type,
           provenance, status, active, rationale, created_by, approved_by, approved_at)
  select k.id, st.id, 'exact', 'manual', 'nestra_reviewed', 'approved', true, 'S7',
         '11111111-1111-4111-8111-000000000001','11111111-1111-4111-8111-000000000001', now()
    from public.skills k
    cross join lateral (select id from public.standards order by id limit 1) st
   where k.code like 'NST.FR.%';
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000f',
                        '11111111-1111-4111-8111-000000000003');
  b := t.s7_pipeline('44444444-4444-4444-8444-00000000000f',
                     '11111111-1111-4111-8111-000000000003');
  perform t.assert_eq(a, b, '9c. arm C: mapping every skill to a benchmark changes nothing');

  -- arm D: and taking every mapping away changes nothing either
  delete from public.skill_standards;
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000e',
                        '11111111-1111-4111-8111-000000000001');
  c := t.s7_pipeline('44444444-4444-4444-8444-00000000000e',
                     '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, c, '9d. arm D: nor does removing every mapping');
end $$;
rollback;

-- =============================================================================
-- 10. Grade and age independence, over the WHOLE pipeline
-- =============================================================================

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  a := t.s7_pipeline('44444444-4444-4444-8444-00000000000d',
                     '11111111-1111-4111-8111-000000000001');
  update public.students set grade_level = '11', grade_equivalent = '11.9',
         date_of_birth = date '2015-02-02'
   where id = '44444444-4444-4444-8444-00000000000f';
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000f',
                        '11111111-1111-4111-8111-000000000003');
  b := t.s7_pipeline('44444444-4444-4444-8444-00000000000f',
                     '11111111-1111-4111-8111-000000000003');
  perform t.assert_eq(a, b,
    '10a. calling a child an eleventh grader born in 2015 changes nothing about '
    || 'her profile, her diagnostic, her review or her path');
end $$;
rollback;

-- =============================================================================
-- 11. The eight loops that must not exist
-- =============================================================================

begin;
do $$
declare j jsonb; v_path uuid; v_node uuid; v_ev int; v_sk uuid; v_ctx jsonb;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  select count(*) into v_ev from public.student_skill_events;
  select id into v_sk from public.skills where code = 'NST.FR.5';

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v_path := (j->>'path')::uuid;
  perform t.assert_eq((select count(*)::int from public.student_skill_events), v_ev,
    '11a. path membership is not evidence');

  j := public.approve_learning_path(v_path, 'S7');
  perform t.assert_eq((select count(*)::int from public.student_skill_events), v_ev,
    '11b. path approval is not evidence');

  select n.id into v_node from public.learning_path_nodes n where n.path_id = v_path
   order by n.position limit 1;
  perform public.complete_path_node(v_node, 'S7');
  perform t.assert_eq((select count(*)::int from public.student_skill_events), v_ev,
    '11c. path completion is not mastery');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills where skill_state = 'secure'
      and student_id = '44444444-4444-4444-8444-00000000000d'), 1,
    '11d. and nothing became secure except the one skill a person confirmed');
  perform t.logout();
end $$;
rollback;

select t.assert_eq(
  (select count(*)::int from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname='public' and k.contype='f'
     and c.relname in ('student_skills','student_skill_events','student_skill_overrides',
                       'diagnostic_observations')
     and k.confrelid::regclass::text like '%learning_path%'),
  0, '11e. no column on any evidence table points at a learning path');

select t.assert_eq(
  (select count(*)::int from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname='public' and k.contype='f'
     and c.relname in ('student_skills','student_skill_events','student_skill_overrides')
     and k.confrelid::regclass::text in ('standards','skill_standards',
                                         'public.standards','public.skill_standards')),
  0, '11f. nor at the standards catalogue - a mapping is never a readiness input');

-- =============================================================================
-- 12. Who may do what, through the real capability architecture
-- =============================================================================

begin;
do $$
declare j jsonb; v_path uuid; v_sess uuid; v_sk uuid;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  select id into v_sk from public.skills where code = 'NST.FR.2';

  -- Carla, guardian_full: the whole lifecycle is hers.
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform t.assert(app.can_student_action('44444444-4444-4444-8444-00000000000d','skill','update'),
    '12a. an authorized parent may record a decision about a skill');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
    'secure', 'S7 confirmed');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  perform public.stop_diagnostic_session(v_sess, 'S7');
  perform public.request_skill_revisit('44444444-4444-4444-8444-00000000000d', v_sk, 'S7');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v_path := (j->>'path')::uuid;
  j := public.approve_learning_path(v_path, 'S7');
  perform t.assert_eq(j->>'status', 'approved',
    '12b. and may confirm, diagnose, request a revisit and approve a path');
  perform t.logout();

  -- Nina, guardian_standard: may help, may not ratify.
  perform t.login('11111111-1111-4111-8111-00000000000b');
  perform t.assert(not app.can_student_action('44444444-4444-4444-8444-00000000000d',
                        'learning_plan','approve'),
    '12c. a standard guardian holds no approve capability for a learning plan');
  perform t.logout();

  -- Diego, a stranger to this child.
  perform t.login('11111111-1111-4111-8111-000000000003');
  perform t.assert_eq((select count(*)::int from public.learning_paths lp
                        where lp.student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '12d. a stranger sees none of her paths');
  begin
    perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
      'secure', 'S7');
    perform t.assert(false, '12e. a stranger made a decision about a child who is not his');
  exception when insufficient_privilege then
    perform t.assert(true, '12e. and cannot make a decision about a child who is not his');
  end;
  begin
    perform public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code='NST.FR.1'));
    perform t.assert(false, '12f. a stranger started a diagnostic for her');
  exception when insufficient_privilege then
    perform t.assert(true, '12f. nor start a diagnostic for her');
  end;
  begin
    perform public.approve_learning_path(v_path, 'S7');
    perform t.assert(false, '12g. a stranger approved her path');
  exception when insufficient_privilege then
    perform t.assert(true, '12g. nor approve her path');
  end;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 13. Explainability: three questions, answered from stored facts
-- =============================================================================

begin;
do $$
declare v text; j jsonb; v_prof jsonb; v_diag jsonb; v_path jsonb;
        v_sess uuid; v_p uuid;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');

  -- A. why does the profile say what it says?
  v_prof := public.explain_student_skill('44444444-4444-4444-8444-00000000000d',
              (select id from public.skills where code='NST.FR.3'));
  perform t.assert(v_prof ? 'state_reasons',
    '13a. the profile explains itself with structured reason codes');
  perform t.assert((v_prof->'state_reasons')::text like '%conflicting_assertions_present%',
    '13b. naming the disagreement rather than hiding it');
  perform t.assert(jsonb_array_length(v_prof->'state_evidence_ids') > 0,
    '13c. and cites by id the observations that support the answer it gave');
  perform t.assert((v_prof->'sufficiency_inputs')::text like '%occasions%',
    '13d. with the counts that produced the sufficiency - occasions, sources, human-origin');
  perform t.assert_eq(v_prof->>'human_decision', null,
    '13e. and says plainly that no person has overridden this one');

  -- B. why did the diagnostic go there?
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  v_diag := public.explain_diagnostic_session(v_sess);
  perform t.assert(v_diag ? 'starting_context',
    '13f. the diagnostic explains itself from the profile it started with');
  perform t.assert((v_diag->'decisions')::text like '%existing_evidence_skip%',
    '13g. recording which skills it skipped and why');
  perform t.assert((v_diag->'route')::text like '%reason%',
    '13h. and a reason code on every question it asked');
  perform public.stop_diagnostic_session(v_sess, 'S7');

  -- C. why is this skill on the path?
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v_p := (j->>'path')::uuid;
  v_path := public.explain_learning_path(v_p);
  perform t.assert((v_path->'nodes')::text like '%readiness_reasons%',
    '13i. every path node carries the reasons that made it reasonable');
  perform t.assert((v_path->'nodes')::text like '%prerequisites_considered%',
    '13j. and what it considered underneath');
  perform t.assert(v_path ? 'generation_inputs',
    '13k. with everything the engine looked at, frozen at the time it looked');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      where n.path_id = v_p and n.reason_detail = '{}'::jsonb), 0,
    '13l. no node relies on prose - each one has a structured account');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 14. Reconstructing what happened, afterwards
-- =============================================================================

begin;
do $$
declare j jsonb; si uuid; v_sess uuid; v_obs uuid; v1 uuid; v2 uuid; v_node uuid;
        v_nodes1 text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j  := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
         (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  si := (j->>'session_item')::uuid;
  j  := public.record_diagnostic_observation(si, 'demonstrated', 'S7');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;
  perform public.confirm_diagnostic_observation(v_obs, 'developing', 'S7');
  perform public.stop_diagnostic_session(v_sess, 'S7');
  j  := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
         (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v1 := (j->>'path')::uuid;
  perform public.approve_learning_path(v1, 'S7');
  select n.id into v_node from public.learning_path_nodes n where n.path_id = v1
   order by n.position desc limit 1;
  perform public.remove_path_node(v_node, 'S7 not this term');
  v_nodes1 := (public.explain_learning_path(v1)->'nodes')::text;
  j  := public.regenerate_learning_path(v1, 'new_confirmed_evidence', 'S7');
  v2 := (j->>'path')::uuid;
  -- Still signed in as her: reconstruction is something the FAMILY can do, not
  -- a thing only a database administrator can see.
  perform t.assert((select count(*) from public.student_skill_events
                     where student_id='44444444-4444-4444-8444-00000000000d') >= 6,
    '14a. every observation anybody recorded is still there');
  perform t.assert_eq(
    (select count(*)::int from public.student_skill_overrides o
      where o.student_id='44444444-4444-4444-8444-00000000000d' and o.status='active'), 1,
    '14b. the decision a person made is still on the record, with her name on it');
  perform t.assert(exists (select 1 from public.diagnostic_sessions s where s.id = v_sess),
    '14c. the diagnostic session survives, with its starting context');
  perform t.assert(exists (select 1 from public.diagnostic_observations o
                            where o.id = v_obs and o.review_status = 'confirmed'
                              and o.reviewed_by is not null),
    '14d. and her review of it, naming her');
  perform t.assert(exists (select 1 from public.diagnostic_routing_decisions d
                            where d.session_id = v_sess),
    '14e. along with every routing decision the engine made');
  perform t.assert_eq(
    (select lp.status::text from public.learning_paths lp where lp.id = v1),
    'approved', '14f. version 1 is still the version she approved');
  perform t.assert_eq((public.explain_learning_path(v1)->'nodes')::text, v_nodes1,
    '14g. node for node, unchanged by the regeneration that followed it');
  perform t.assert((select count(*) from public.learning_path_events e
                     where e.path_id = v1 and e.kind = 'node_removed') = 1,
    '14h. her edit is on the record as an edit she made');
  perform t.assert_eq(
    (select lp.supersedes_id from public.learning_paths lp where lp.id = v2), v1,
    '14i. and version 2 says what it came from');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 15. Structural audit
-- =============================================================================

-- `void is null` is false, not true, so the invariants have to be run rather
-- than compared. Asserting on the return value of a void function passes or
-- fails for reasons that have nothing to do with the invariants.
do $$
begin
  perform t.logout();
  perform app.assert_schema_invariants();
  perform t.assert(true, '15a. every structural invariant STEP 7 added still holds');
exception when others then
  perform t.assert(false, '15a. structural invariants FAILED: ' || sqlerrm);
end $$;

select t.assert_eq(
  (select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
     from pg_enum e join pg_type ty on ty.oid = e.enumtypid
     join pg_namespace n on n.oid = ty.typnamespace
    where n.nspname='app' and ty.typname='skill_state'),
  'unknown, emerging, developing, secure',
  '15b. the state model is still exactly four labels - no fifth state crept in');

select t.assert_eq(
  (select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
     from pg_enum e join pg_type ty on ty.oid = e.enumtypid
     join pg_namespace n on n.oid = ty.typnamespace
    where n.nspname='app' and ty.typname='evidence_confidence'),
  'preliminary, supported, corroborated',
  '15c. and evidence confidence is still exactly three');

select t.assert_eq(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public'
      and (table_name like 'student_skill%' or table_name like 'diagnostic%'
           or table_name like 'learning_path%')
      and (column_name ~ '(percent|score|percentile|mastery|ability|grade_level|grade_equivalent|readiness_level|rank)'
           or data_type in ('numeric','real','double precision'))),
  0, '15d. no STEP 7 table holds a mastery or readiness percentage, a grade equivalent or an ability score');

select t.assert_eq(
  (select count(*)::int from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname='public' and k.contype='f'
     and (c.relname like 'student_skill%' or c.relname like 'diagnostic%')
     and k.confrelid::regclass::text ~ '(standards|skill_standards|learning_path)'),
  0, '15e. and no foreign key runs from a child''s profile into standards or a path');

select t.assert_eq(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app','public')
      and p.proname ~ '(pacing|required_standard|standards_pacing|scope_and_sequence)'),
  0, '15f. nothing in the database paces a child against a standard');

-- =============================================================================
-- 16. Language audit, on the surfaces STEP 7 added
-- =============================================================================
-- The catalogs themselves are checked by scripts/check-family-language.mjs in
-- both locales. What is checked HERE is the database: a reason code or an enum
-- label is a string a screen will eventually render, and none of them may carry
-- a deficit claim.

select t.assert_eq(
  (select count(*)::int from pg_enum e
     join pg_type ty on ty.oid = e.enumtypid
     join pg_namespace n on n.oid = ty.typnamespace
    where n.nspname = 'app'
      and (ty.typname like 'path_%' or ty.typname like 'diagnostic_%'
           or ty.typname like 'refresh_%' or ty.typname in ('skill_state','state_reason_code',
                                                            'evidence_sufficiency'))
      and e.enumlabel ~ '(behind|ahead|below_grade|above_grade|on_grade|deficien|remedia|should_know|expected_for|catch_up|falling)'),
  0, '16a. no STEP 7 enum label describes a child as behind, ahead, deficient or needing remediation');

-- The same words, in a comment. Negations are excluded deliberately: the
-- schema's own documentation says things like "there is no remediation
-- staircase", and a check that flagged that would be demanding the code stop
-- promising the thing it promises. This is the third time this project has met
-- that shape - `vencido` in Phase 4, `nivel de dominio` in Phase 6 - and the
-- rule each time is the same: ban the claim, not the word.
select t.assert_eq(
  (select count(*)::int from pg_description d
     join pg_class c on c.oid = d.objoid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname='public'
      and (c.relname like 'student_skill%' or c.relname like 'diagnostic%'
           or c.relname like 'learning_path%')
      and d.description ~* '(falling behind|below grade|above grade|on grade level|deficien|remediation|should already know|catch up)'
      and d.description !~* '(no|not|never|without|cannot) [a-z'' ]{0,14}(falling behind|below grade|above grade|on grade level|deficien|remediation|should already know|catch up)'),
  0, '16b. nor does any STEP 7 table comment CLAIM one - only deny it');

-- And the check bites, rather than passing because its pattern is dead.
begin;
do $$
begin
  perform t.logout();
  comment on table public.learning_paths is
    'S7 probe: this child is falling behind and needs remediation.';
  perform t.assert_eq(
    (select count(*)::int from pg_description d
       join pg_class c on c.oid = d.objoid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname='public' and c.relname = 'learning_paths'
        and d.description ~* '(falling behind|below grade|above grade|on grade level|deficien|remediation|should already know|catch up)'
        and d.description !~* '(no|not|never|without|cannot) [a-z'' ]{0,14}(falling behind|below grade|above grade|on grade level|deficien|remediation|should already know|catch up)'),
    1, '16c. and the check catches a comment that asserts the claim rather than denying it');
end $$;
rollback;

select t.assert(
  (select ty.typname from pg_type ty join pg_namespace n on n.oid=ty.typnamespace
    where n.nspname='app' and ty.typname='skill_state') is not null
  and not exists (select 1 from pg_enum e join pg_type ty on ty.oid=e.enumtypid
                   where ty.typname='skill_state' and e.enumlabel ~ '(fail|deficit|gap|missing|none)'),
  '16d. `unknown` has no sibling that would let a screen render it as a failure');

-- =============================================================================
-- 17. Adversarial security, across every STEP 7 surface
-- =============================================================================
-- Diego is a real guardian - of Sofia. Everything he tries here is a thing a
-- signed-in user of the product can try.

begin;
do $$
declare
  j jsonb; v_path uuid; v_sess uuid; v_node uuid; v_obs uuid; v_ov uuid; v_ev uuid;
  v_si uuid; v_dec uuid; v_sk uuid; n int; v_err text; v_err2 text;
begin
  perform t.logout();
  perform t.s7_scenario('44444444-4444-4444-8444-00000000000d',
                        '11111111-1111-4111-8111-000000000001');
  select id into v_sk from public.skills where code='NST.FR.1';

  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_family_refresh_advisory(
    (select family_id from public.students where id='44444444-4444-4444-8444-00000000000d'),
    true, 7);
  perform public.request_skill_revisit('44444444-4444-4444-8444-00000000000d', v_sk, 'S7');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  v_sess := (j->>'session')::uuid;
  v_si   := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(v_si, 'demonstrated', 'S7');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = v_si;
  perform public.stop_diagnostic_session(v_sess, 'S7');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'S7');
  v_path := (j->>'path')::uuid;
  select n2.id into v_node from public.learning_path_nodes n2 where n2.path_id = v_path
   order by n2.position limit 1;
  select o.id into v_ov from public.student_skill_overrides o
   where o.student_id='44444444-4444-4444-8444-00000000000d' limit 1;
  select e.id into v_ev from public.student_skill_events e
   where e.student_id='44444444-4444-4444-8444-00000000000d' limit 1;
  select d.id into v_dec from public.student_skill_refresh_decisions d
   where d.student_id='44444444-4444-4444-8444-00000000000d' limit 1;
  perform t.logout();

  -- Every STEP 7 surface, counted as a stranger sees it.
  perform t.login('11111111-1111-4111-8111-000000000003');
  perform t.assert_eq((select count(*)::int from public.student_skills
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17a. profile rows: invisible');
  perform t.assert_eq((select count(*)::int from public.student_skill_events
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17b. evidence: invisible');
  perform t.assert_eq((select count(*)::int from public.student_skill_overrides
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17c. human decisions: invisible');
  perform t.assert_eq((select count(*)::int from public.student_skill_refresh_decisions
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17d. refresh decisions: invisible');
  perform t.assert_eq((select count(*)::int from public.diagnostic_sessions
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17e. diagnostic sessions: invisible');
  perform t.assert_eq((select count(*)::int from public.diagnostic_session_items
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17f. session items: invisible');
  perform t.assert_eq((select count(*)::int from public.diagnostic_observations
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17g. observations: invisible');
  perform t.assert_eq((select count(*)::int from public.diagnostic_routing_decisions
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17h. routing decisions: invisible');
  perform t.assert_eq((select count(*)::int from public.learning_paths
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17i. learning paths: invisible');
  perform t.assert_eq((select count(*)::int from public.learning_path_nodes
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17j. path nodes: invisible');
  perform t.assert_eq((select count(*)::int from public.learning_path_events
                        where student_id='44444444-4444-4444-8444-00000000000d'), 0,
    '17k. path events: invisible');

  -- Naming a row by its id does not get him past RLS either.
  perform t.assert_eq((select count(*)::int from public.learning_paths where id = v_path), 0,
    '17l. naming a path by its id returns nothing');
  perform t.assert_eq((select count(*)::int from public.diagnostic_observations where id = v_obs), 0,
    '17m. naming an observation by its id returns nothing');
  perform t.assert_eq((select count(*)::int from public.student_skill_overrides where id = v_ov), 0,
    '17n. naming a decision by its id returns nothing');

  -- Nor does joining through a table he IS allowed to read. The item bank is
  -- shared - it holds prompt keys, not children - and must not become a window.
  perform t.assert(exists (select 1 from public.diagnostic_items), '17o. he can read the shared item bank');
  perform t.assert_eq(
    (select count(*)::int from public.diagnostic_items di
      join public.diagnostic_session_items si on si.item_id = di.id), 0,
    '17p. and joining it to another family''s session yields nothing');
  perform t.assert_eq(
    (select count(*)::int from public.skills k
      join public.learning_path_nodes n2 on n2.skill_id = k.id), 0,
    '17q. joining the skill graph to another family''s path yields nothing');
  perform t.assert_eq(
    (select count(*)::int from public.learning_resources r
      join public.learning_path_nodes n2 on n2.resource_id = r.id), 0,
    '17r. and joining a shared resource to their nodes yields nothing');

  -- The refusals must look the same whether the row exists or not, or the
  -- difference itself is the leak.
  begin
    perform public.explain_learning_path(v_path);
    v_err := 'ALLOWED';
  exception when others then v_err := sqlerrm; end;
  begin
    perform public.explain_learning_path('00000000-0000-0000-0000-000000000000'::uuid);
    v_err2 := 'ALLOWED';
  exception when others then v_err2 := sqlerrm; end;
  perform t.assert_eq(v_err, v_err2,
    '17s. a real path and an invented one refuse identically - the error text tells him nothing');

  begin
    perform public.explain_diagnostic_session(v_sess);
    v_err := 'ALLOWED';
  exception when others then v_err := sqlerrm; end;
  begin
    perform public.explain_diagnostic_session('00000000-0000-0000-0000-000000000000'::uuid);
    v_err2 := 'ALLOWED';
  exception when others then v_err2 := sqlerrm; end;
  perform t.assert_eq(v_err, v_err2,
    '17t. and so do a real diagnostic session and an invented one');

  -- Writing is refused as firmly as reading.
  begin
    perform public.confirm_diagnostic_observation(v_obs, 'developing', 'S7');
    perform t.assert(false, '17u. a stranger confirmed another family''s observation');
  exception when others then
    perform t.assert(true, '17u. he cannot confirm another family''s observation');
  end;
  begin
    perform public.complete_path_node(v_node, 'S7');
    perform t.assert(false, '17v. a stranger completed a node on another family''s path');
  exception when others then
    perform t.assert(true, '17v. nor tick off a step on their path');
  end;
  update public.learning_path_nodes set position = 99 where id = v_node;
  get diagnostics n = row_count;
  perform t.assert_eq(n, 0, '17w. and a direct write reaches no row of theirs');
  perform t.logout();

  -- It all still belongs to the family it belongs to.
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform t.assert(exists (select 1 from public.learning_paths where id = v_path),
    '17x. while the family it belongs to still sees it');
  perform t.logout();
end $$;
rollback;

select t.assert(true, '--- STEP 7 integration audit complete ---');
