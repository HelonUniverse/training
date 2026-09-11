-- =============================================================================
-- STEP 7 phase 6 - the adaptive Learning Path
-- =============================================================================
-- Every block is rolled back. Rows are marked P6.
--
-- The tests that matter most are 20-22 (nothing a path does becomes evidence
-- about a child), 16-19 (standards, grade and age cannot change the path), and
-- 27-28 (a path a parent approved is still there, unchanged, after Nestra
-- suggests something else).
-- =============================================================================

\set CARLA '11111111-1111-4111-8111-000000000001'
\set PEDRO '11111111-1111-4111-8111-000000000002'
\set DIEGO '11111111-1111-4111-8111-000000000003'
\set NINA  '11111111-1111-4111-8111-00000000000b'
\set LUCAS '44444444-4444-4444-8444-00000000000d'
\set SOFIA '44444444-4444-4444-8444-00000000000f'

-- Put a characterization on the profile directly. This is the profile SAYING
-- something, which is what the path engine reads; how it got there is Phase 3's
-- business and is tested there.
create or replace function t.p6_state(p_student uuid, p_code text, p_state text,
                                      p_suff text, p_actor uuid)
returns uuid language plpgsql as $$
declare v_sk uuid; v_org uuid; v_id uuid;
begin
  select id into v_sk from public.skills where code = p_code;
  select primary_organization_id into v_org from public.students where id = p_student;
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, evidence_sufficiency,
           usable_evidence_count, created_by)
  values (p_student, v_sk, v_org, 'manual', 'human_entered', 'parent',
          p_state::app.skill_state, p_suff::app.evidence_sufficiency,
          case when p_suff = 'none' then 0 else 2 end, p_actor)
  returning id into v_id;
  return v_id;
end $$;

-- Real evidence, the honest way: two usable observations on two occasions from
-- two sources, recomputed.
create or replace function t.p6_evidence(p_student uuid, p_code text, p_state text, p_actor uuid)
returns void language plpgsql as $$
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
  values (v_ss, p_student, v_sk, v_org, current_date - 40,'P6', p_state::app.skill_state,
          'manual','parent','human_entered', p_actor),
         (v_ss, p_student, v_sk, v_org, current_date - 30,'P6', p_state::app.skill_state,
          'manual','tutor','human_entered', p_actor);
  perform t.login(p_actor);
  perform public.recompute_student_skill(p_student, v_sk);
  perform t.logout();
end $$;

-- One path, as one comparable string.
create or replace function t.p6_path(p_student uuid, p_root_code text, p_actor uuid,
                                     p_horizon integer default 4)
returns text language plpgsql as $$
declare j jsonb; v text;
begin
  perform t.login(p_actor);
  j := public.generate_learning_path(p_student,
        (select id from public.skills where code = p_root_code), p_horizon, 'P6');
  perform t.logout();
  select string_agg(format('%s.%s/%s%s', n->>'position', n->>'skill', n->>'reason',
           case when (n->>'resource_id') is not null then '+res' else '' end),
           ' | ' order by (n->>'position')::int)
    into v from jsonb_array_elements(j->'nodes') n;
  return coalesce(v, '(no nodes)');
end $$;

grant execute on function t.p6_state(uuid, text, text, text, uuid) to authenticated;
grant execute on function t.p6_evidence(uuid, text, text, uuid) to authenticated;
grant execute on function t.p6_path(uuid, text, uuid, integer) to authenticated;

-- =============================================================================
-- 1-2. A first path, and where it opens
-- =============================================================================

begin;
do $$
declare v text;
begin
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(v,
    '1.NST.FR.1/continue_connected_skill | 2.NST.FR.2/prerequisite_support | 3.NST.FR.3/curriculum_resource_available+res',
    '1a. a child Nestra knows nothing about gets a path that starts at the beginning of the branch');
  perform t.assert(v not like '%NST.FR.5%',
    '1b. and does not jump to the far end of the graph because a worksheet happens to exist there');
end $$;
rollback;

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v like '1.NST.FR.3/%',
    '2a. with the first two characterized, the path opens at the skill that follows them');
  perform t.assert(v not like '%NST.FR.1%' and v not like '%NST.FR.2%',
    '2b. and does not re-propose work the profile already speaks to');
end $$;
rollback;

-- =============================================================================
-- 3-4. What a person has already confirmed
-- =============================================================================

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.p6_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.1'), 'secure', 'P6 she is solid');
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v not like '%NST.FR.1/%',
    '3a. a skill a parent confirmed secure is not put back on the path to be taught again');
  perform t.assert(v like '1.NST.FR.2/%',
    '3b. the path opens at what comes after it instead');
end $$;
rollback;

begin;
do $$
declare v text;
begin
  perform t.logout();
  -- FR.3 is the one with a demo resource attached, so confirming it is what
  -- makes application work available rather than imagined.
  perform t.p6_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.3','developing',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.3'), 'secure', 'P6 confirmed');
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001', 5);
  perform t.assert(v like '%NST.FR.3/enrichment%',
    '4a. a confirmed skill may still appear, as application, when real material exists for it');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      join public.skills k on k.id = n.skill_id
     where k.code = 'NST.FR.3' and n.reason_code = 'enrichment'
       and n.resource_id is not null), 1,
    '4b. and the enrichment node names the resource rather than inventing an activity');
end $$;
rollback;

-- =============================================================================
-- 5-6. unknown is not failure, emerging is not behind
-- =============================================================================

select t.assert_eq(
  (select count(*)::int from pg_enum e join pg_type t2 on t2.oid = e.enumtypid
     join pg_namespace n on n.oid = t2.typnamespace
    where n.nspname = 'app' and t2.typname in ('path_node_reason','path_readiness_reason')
      and e.enumlabel ~ '(behind|ahead|remedia|deficien|gap|missing|below|catch)'),
  0, '5a. no path reason describes a child as behind, deficient or missing something');

begin;
do $$
declare v text; v_rr jsonb;
begin
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  select to_jsonb(n.readiness_reasons) into v_rr
    from public.learning_path_nodes n join public.skills k on k.id = n.skill_id
   where k.code = 'NST.FR.1';
  perform t.assert(v_rr ? 'no_evidence_yet',
    '5b. a skill with no evidence says exactly that - Nestra has none, not that the child lacks something');
  perform t.assert(not (v_rr ? 'prerequisite_uncertain'),
    '5c. and an absent record is not reported as an uncertain one');
end $$;
rollback;

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','emerging','preliminary',
                     '11111111-1111-4111-8111-000000000001');
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v like '%NST.FR.1/uncertain_boundary%',
    '6a. early evidence keeps a skill in play as an open question, not as a failure');
  -- NST.FR.1 is the emerging one. It may be proposed as an open question; what
  -- it may never be is something the path treats as missing and props up.
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      join public.skills k on k.id = n.skill_id
     where k.code = 'NST.FR.1' and n.reason_code = 'prerequisite_support'), 0,
    '6b. and emerging is never treated as an unmet prerequisite needing support');
  perform t.assert_eq(
    coalesce(array_length(app.path_unmet_prerequisites(
       '44444444-4444-4444-8444-00000000000d',
       (select id from public.skills where code='NST.FR.1'),
       (select id from public.skills where code='NST.FR.2'), '{}'::uuid[]), 1), 0), 0,
    '6c. early evidence satisfies a prerequisite - it is not a gate that needs secure');
end $$;
rollback;

-- =============================================================================
-- 7-8. What a person asked for, and where the diagnostic ran out
-- =============================================================================

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  -- Carla says: this term we care about comparing fractions.
  insert into public.learning_goals (student_id, skill_id, title, horizon, priority,
           status, source_type, approved_by, created_by)
  values ('44444444-4444-4444-8444-00000000000d',
          (select id from public.skills where code='NST.FR.5'),
          'P6 compare fractions', 'short_term', 1, 'active', 'parent',
          '11111111-1111-4111-8111-000000000001','11111111-1111-4111-8111-000000000001');
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001', 5);
  perform t.assert(v like '%NST.FR.5/parent_goal%',
    '7a. a skill a parent set as a goal is on the path, and says so');
  perform t.assert(v like '%NST.FR.3/prerequisite_support%',
    '7b. with one support node underneath it - the nearest unmet prerequisite by skill code');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      where n.reason_code = 'prerequisite_support'), 1,
    '7c. exactly one. A goal two steps away does not become a five-step staircase');
end $$;
rollback;

begin;
do $$
declare v text; j jsonb; si uuid; v_sess uuid;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'not_demonstrated','P6');
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'not_demonstrated','P6');
  -- The floor leaves one prerequisite probe outstanding, so the session is still
  -- open. The frontier deliberately reads only sessions that have FINISHED - a
  -- session a child is in the middle of is not a conclusion about anything.
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'not_demonstrated','P6');
  perform t.logout();

  perform t.assert_eq(
    (select count(*)::int from app.path_diagnostic_frontier(
       '44444444-4444-4444-8444-00000000000d',
       (select id from public.skills where code='NST.FR.1'))),
    (select count(*)::int from app.path_diagnostic_frontier(
       '44444444-4444-4444-8444-00000000000d',
       (select id from public.skills where code='NST.FR.1'))),
    '8a. the frontier is a stable reading of the last session');
  perform t.assert(exists (
    select 1 from app.path_diagnostic_frontier('44444444-4444-4444-8444-00000000000d',
              (select id from public.skills where code='NST.FR.1')) f
      join public.skills k on k.id = f.skill_id where k.code = 'NST.FR.3'),
    '8b. the skill the session stopped on is on the frontier');
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v like '%NST.FR.3/diagnostic_frontier%',
    '8c. and the path picks it up, saying that is where the session ended');
end $$;
rollback;

-- =============================================================================
-- 9-11. What may and may not establish readiness
-- =============================================================================

begin;
do $$
declare j jsonb; si uuid; v_ctx jsonb;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'demonstrated','P6');
  j := public.record_diagnostic_observation((j->>'session_item')::uuid,'demonstrated','P6');
  perform t.logout();
  -- Nobody has reviewed any of that.
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.1'));
  perform t.assert_eq((v_ctx->>'usable_evidence_count')::int, 0,
    '9a. two unreviewed diagnostic observations are not evidence about the child');
  perform t.assert(not app.path_well_characterized('44444444-4444-4444-8444-00000000000d',
                     (select id from public.skills where code='NST.FR.1')),
    '9b. and cannot make a skill count as characterized for the path');
end $$;
rollback;

begin;
do $$
declare j jsonb; si uuid; v_obs uuid; v_ctx jsonb;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.start_diagnostic_session('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'));
  si := (j->>'session_item')::uuid;
  j := public.record_diagnostic_observation(si,'demonstrated','P6');
  select o.id into v_obs from public.diagnostic_observations o where o.session_item_id = si;
  j := public.confirm_diagnostic_observation(v_obs, 'developing', 'P6 I watched her');
  perform t.logout();
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.1'));
  perform t.assert_eq((v_ctx->>'usable_evidence_count')::int, 1,
    '10a. an observation a person confirmed IS evidence the path may reason from');
  perform t.assert_eq(v_ctx->>'effective_state', 'emerging',
    '10b. held to the same ceiling Phase 3 set - one observation is one observation');
end $$;
rollback;

begin;
do $$
declare v_sk uuid; v_ss uuid; v_org uuid; v_ctx jsonb;
begin
  perform t.logout();
  select id into v_sk from public.skills where code='NST.FR.1';
  select primary_organization_id into v_org from public.students
   where id='44444444-4444-4444-8444-00000000000d';
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, created_by)
  values ('44444444-4444-4444-8444-00000000000d', v_sk, v_org, 'ai_suggestion',
          'ai_proposed_unreviewed','unknown','unknown','11111111-1111-4111-8111-000000000001')
  returning id into v_ss;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id, organization_id,
           occurred_on, evidence_note, skill_state, source_type, evidence_source,
           record_provenance, created_by)
  values (v_ss, '44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date,
          'P6 unreviewed', null, 'ai_suggestion','unknown','ai_proposed_unreviewed',
          '11111111-1111-4111-8111-000000000001');
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.assert_eq((v_ctx->>'usable_evidence_count')::int, 0,
    '11a. an unreviewed AI proposal is not evidence the path may reason from');
  perform t.assert(not app.path_well_characterized('44444444-4444-4444-8444-00000000000d', v_sk),
    '11b. and cannot make a skill count as characterized');
end $$;
rollback;

-- =============================================================================
-- 12-14. One level of support, no staircase, a small horizon
-- =============================================================================

begin;
do $$
declare v text; v_n int;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001', 5);
  select count(*) into v_n from public.learning_path_nodes n
   where n.reason_code = 'prerequisite_support' and n.supports_node_id is not null;
  perform t.assert(v_n <= 2, '12a. support nodes are occasional, not a layer under everything');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      where n.reason_code = 'prerequisite_support'
        and exists (select 1 from public.learning_path_nodes n2
                     where n2.id = n.supports_node_id
                       and n2.reason_code = 'prerequisite_support')), 0,
    '13a. no support node supports another support node - there is no staircase');
end $$;
rollback;

do $$
declare v_lo text; v_hi text;
begin
  perform t.logout();
  begin
    perform t.login('11111111-1111-4111-8111-000000000001');
    perform public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code='NST.FR.1'), 9);
    perform t.assert(false, '14a. a path of nine skills was accepted');
  exception when check_violation then
    perform t.assert(true, '14a. a path may not be asked to plan out nine skills');
  end;
  perform t.logout();
end $$;

begin;
do $$
declare v_n int;
begin
  perform t.logout();
  perform t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                    '11111111-1111-4111-8111-000000000001', 5);
  select count(*) into v_n from public.learning_path_nodes;
  perform t.assert(v_n between 1 and 5,
    '14b. and never proposes more skills than the horizon allows');
end $$;
rollback;

-- =============================================================================
-- 15-19. Determinism, and the four things that must not change it
-- =============================================================================

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  a := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  b := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, b, '15a. the same inputs produce the same path, twice running');
end $$;
rollback;

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  a := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  -- arm B: the catalogue renamed out from under the running engine
  alter table public.skill_standards rename to skill_standards_gone;
  alter table public.standards rename to standards_gone;
  b := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, b,
    '16a. the path is identical with the standards catalogue gone entirely');
end $$;
rollback;

begin;
do $$
declare a text; b text; c text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  a := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  insert into public.skill_standards (skill_id, standard_id, relation, source_type,
           provenance, status, active, rationale, created_by, approved_by, approved_at)
  select k.id, st.id, 'exact', 'manual', 'nestra_reviewed', 'approved', true, 'P6',
         '11111111-1111-4111-8111-000000000001','11111111-1111-4111-8111-000000000001', now()
    from public.skills k
    cross join lateral (select id from public.standards order by id limit 1) st
   where k.code like 'NST.FR.%';
  b := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, b, '17a. mapping every skill to a benchmark changes nothing');
  delete from public.skill_standards;
  c := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, c, '17b. and removing every mapping changes nothing either');
end $$;
rollback;

begin;
do $$
declare a text; b text;
begin
  perform t.logout();
  perform t.p6_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  a := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  update public.students set grade_level = '11', grade_equivalent = '11.9'
   where id = '44444444-4444-4444-8444-00000000000d';
  b := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, b, '18a. calling the same child an eleventh grader changes nothing');
  update public.students set date_of_birth = date '2015-02-02'
   where id = '44444444-4444-4444-8444-00000000000d';
  b := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert_eq(a, b, '19a. and moving her birthday changes nothing');
end $$;
rollback;

-- =============================================================================
-- 20-22. The loop that is not allowed to exist
-- =============================================================================

begin;
do $$
declare j jsonb; v_path uuid; v_before int; v_after int; v_node uuid;
begin
  perform t.logout();
  select count(*) into v_before from public.student_skill_events;
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_path := (j->>'path')::uuid;
  select count(*) into v_after from public.student_skill_events;
  perform t.assert_eq(v_after, v_before, '20a. generating a path creates no evidence');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code like 'NST.FR.%'), 0,
    '20b. and no profile rows - a proposal is not a characterization');

  j := public.approve_learning_path(v_path, 'P6 yes');
  select count(*) into v_after from public.student_skill_events;
  perform t.assert_eq(v_after, v_before, '21a. approving a path creates no evidence');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code like 'NST.FR.%'), 0,
    '21b. and still no profile rows');

  select n.id into v_node from public.learning_path_nodes n where n.path_id = v_path
   order by n.position limit 1;
  j := public.complete_path_node(v_node, 'P6 we did this');
  select count(*) into v_after from public.student_skill_events;
  perform t.assert_eq(v_after, v_before, '22a. finishing a step creates no evidence');
  perform t.assert_eq(j->>'evidence_created', 'false',
    '22b. and says so plainly rather than leaving a family to assume');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d'
        and k.code like 'NST.FR.%' and ss.skill_state <> 'unknown'), 0,
    '22c. doing the work is not the same as having shown it');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 23-26. A parent's hands on it
-- =============================================================================

begin;
do $$
declare j jsonb; v_path uuid; v_node uuid; v_fr5 uuid; v_warn jsonb;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_path := (j->>'path')::uuid;

  select n.id into v_node from public.learning_path_nodes n where n.path_id = v_path
   order by n.position desc limit 1;
  j := public.remove_path_node(v_node, 'P6 not this term');
  perform t.assert_eq(
    (select n.status::text from public.learning_path_nodes n where n.id = v_node),
    'removed', '23a. a parent can take a skill off the path');
  -- Checked against the node ids themselves, not the JSON text: a support node
  -- names the node it supports, so a substring search finds the removed id in a
  -- perfectly correct payload.
  perform t.assert_eq(
    (select count(*)::int from jsonb_array_elements(j->'path'->'nodes') n
      where (n->>'node')::uuid = v_node), 0,
    '23b. and it stops being part of the plan she is looking at');
  perform t.assert_eq(
    (select count(*)::int from jsonb_array_elements(j->'path'->'removed') n
      where (n->>'node')::uuid = v_node), 1,
    '23c. while staying on the record, because her decision is worth keeping');

  select id into v_fr5 from public.skills where code = 'READ.PHO';
  j := public.add_path_node(v_path, v_fr5, 1, 'P6 she asked to do phonics');
  perform t.assert_eq(
    (select n.reason_code::text from public.learning_path_nodes n
      where n.path_id = v_path and n.skill_id = v_fr5),
    'human_added', '24a. a parent can put a skill on the path herself');
  perform t.assert(
    (select n.added_by is not null from public.learning_path_nodes n
      where n.path_id = v_path and n.skill_id = v_fr5),
    '24b. and the record names her rather than crediting Nestra');

  select n.id into v_node from public.learning_path_nodes n
   where n.path_id = v_path and n.status <> 'removed' order by n.position desc limit 1;
  j := public.reorder_path_node(v_node, 1, 'P6 do this first');
  perform t.assert_eq((j->>'to')::int, 1, '25a. a parent can move a skill to the front');
  v_warn := j->'warnings';
  perform t.assert(jsonb_array_length(v_warn) > 0,
    '26a. and is told what that skill usually builds on');
  perform t.assert(v_warn::text like '%prerequisite_usually_comes_first%',
    '26b. by a structured code, not a sentence somebody has to parse');
  perform t.assert_eq(
    (select n.position from public.learning_path_nodes n where n.id = v_node), 1,
    '26c. the move happens anyway - she is the one who knows her child');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 27-28. New suggestions do not touch what she approved
-- =============================================================================

begin;
do $$
declare j jsonb; v_v1 uuid; v_v2 uuid; v_nodes1 text;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_v1 := (j->>'path')::uuid;
  j := public.approve_learning_path(v_v1, 'P6 yes');
  v_nodes1 := (j->'nodes')::text;

  j := public.regenerate_learning_path(v_v1, 'new_confirmed_evidence', 'P6 something changed');
  v_v2 := (j->>'path')::uuid;

  perform t.assert(v_v2 <> v_v1, '27a. regenerating produces a new path, not an edit');
  perform t.assert_eq((j->>'version')::int, 2, '27b. and a new version number');
  perform t.assert_eq(j->>'status', 'proposed',
    '27c. which is a proposal - it does not take over by arriving');
  perform t.assert_eq(
    (select lp.status::text from public.learning_paths lp where lp.id = v_v1),
    'approved', '27d. the version she approved is still the approved one');

  perform t.assert_eq(
    (public.explain_learning_path(v_v1)->'nodes')::text, v_nodes1,
    '28a. and is still exactly what she approved, node for node');
  perform t.assert_eq(
    (select lp.supersedes_id from public.learning_paths lp where lp.id = v_v2), v_v1,
    '28b. with the new version pointing at what it came from');
  perform t.logout();
end $$;
rollback;

-- A skill she took out does not come back on its own.
begin;
do $$
declare j jsonb; v_v1 uuid; v_node uuid; v_skill uuid; v2 jsonb;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_v1 := (j->>'path')::uuid;
  select n.id, n.skill_id into v_node, v_skill from public.learning_path_nodes n
   where n.path_id = v_v1 order by n.position limit 1;
  perform public.remove_path_node(v_node, 'P6 not this one');
  v2 := public.regenerate_learning_path(v_v1, 'parent_requested', 'P6 try again');
  perform t.assert_eq(
    (select count(*)::int from public.learning_path_nodes n
      where n.path_id = (v2->>'path')::uuid and n.skill_id = v_skill), 0,
    '28c. a skill a parent removed is not quietly proposed again by the next run');
  perform t.logout();
end $$;
rollback;

-- A skill she added herself is carried forward.
begin;
do $$
declare j jsonb; v_v1 uuid; v_skill uuid; v2 jsonb;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_v1 := (j->>'path')::uuid;
  select id into v_skill from public.skills where code = 'READ.FLU';
  perform public.add_path_node(v_v1, v_skill, 1, 'P6 reading too');
  v2 := public.regenerate_learning_path(v_v1, 'parent_requested', 'P6 try again');
  perform t.assert_eq(
    (select n.reason_code::text from public.learning_path_nodes n
      where n.path_id = (v2->>'path')::uuid and n.skill_id = v_skill),
    'human_added', '28d. and a skill she added herself is still there afterwards');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 29-30. Who may see it, and who may decide
-- =============================================================================

begin;
do $$
declare j jsonb; v_path uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_path := (j->>'path')::uuid;
  perform t.logout();

  -- Diego is a guardian of Sofia, not of Lucas.
  perform t.login('11111111-1111-4111-8111-000000000003');
  perform t.assert_eq((select count(*)::int from public.learning_paths), 0,
    '29a. a stranger to this child sees none of her paths');
  perform t.assert_eq((select count(*)::int from public.learning_path_nodes), 0,
    '29b. nor any of their nodes - not even a count that would tell him one exists');
  begin
    perform public.explain_learning_path(v_path);
    perform t.assert(false, '29c. a stranger read a path by naming its id');
  exception when insufficient_privilege or no_data_found then
    perform t.assert(true, '29c. naming the id directly does not get him past it');
  end;
  begin
    perform public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code='NST.FR.1'), 4, 'P6');
    perform t.assert(false, '29d. a stranger generated a path for a child who is not his');
  exception when insufficient_privilege then
    perform t.assert(true, '29d. and cannot make one for a child who is not his');
  end;
  perform t.logout();

  -- Nina is a guardian_standard: she may help build a plan, not ratify it.
  perform t.login('11111111-1111-4111-8111-00000000000b');
  perform t.assert(exists (select 1 from public.learning_paths lp where lp.id = v_path),
    '30a. a standard guardian can see the path');
  begin
    perform public.approve_learning_path(v_path, 'P6');
    perform t.assert(false, '30b. a standard guardian approved a path');
  exception when insufficient_privilege then
    perform t.assert(true, '30b. but approving it is a decision reserved to full access');
  end;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 31-34. The other phases, still meaning what they meant
-- =============================================================================

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.p6_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.1'), 'secure', 'P6 confirmed');
  -- The family turns the refresh advisory on. It is advice, and stays advice.
  perform public.set_family_refresh_advisory(
    (select family_id from public.students where id='44444444-4444-4444-8444-00000000000d'),
    true, 7);
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v not like '%NST.FR.1/%',
    '31a. an advisory to revisit does not force a confirmed skill back onto the path');
  perform t.assert_eq(
    (select ss.skill_state::text from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.1'),
    'secure', '31b. and nothing about the advisory lowers what a person confirmed');
end $$;
rollback;

begin;
do $$
declare v text;
begin
  perform t.logout();
  perform t.p6_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.1'), 'secure', 'P6 confirmed');
  perform public.set_family_refresh_advisory(
    (select family_id from public.students where id='44444444-4444-4444-8444-00000000000d'),
    true, 7);
  -- She asks, in so many words, to come back to it.
  perform public.request_skill_revisit('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.1'), 'P6 I want to check this again');
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v like '%NST.FR.1/revisit_requested%',
    '32a. a revisit a person asked for is a different thing, and is on the path');
  perform t.assert_eq(
    (select ss.skill_state::text from public.student_skills ss join public.skills k on k.id=ss.skill_id
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and k.code='NST.FR.1'),
    'secure', '32b. and it is still secure while she revisits it');
end $$;
rollback;

begin;
do $$
declare v_ctx jsonb; v_sk uuid; v_ss uuid; v_org uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code='NST.FR.1';
  select primary_organization_id into v_org from public.students
   where id='44444444-4444-4444-8444-00000000000d';
  insert into public.student_skills (student_id, skill_id, organization_id, source_type,
           record_provenance, evidence_source, skill_state, created_by)
  values ('44444444-4444-4444-8444-00000000000d', v_sk, v_org, 'manual',
          'human_entered','parent','unknown','11111111-1111-4111-8111-000000000001')
  returning id into v_ss;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id, organization_id,
           occurred_on, evidence_note, skill_state, source_type, evidence_source,
           record_provenance, created_by)
  values (v_ss,'44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date - 20,
          'P6 one view','developing','manual','parent','human_entered',
          '11111111-1111-4111-8111-000000000001'),
         (v_ss,'44444444-4444-4444-8444-00000000000d', v_sk, v_org, current_date - 10,
          'P6 another','emerging','manual','tutor','human_entered',
          '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.recompute_student_skill('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.assert(( v_ctx->>'conflicting_evidence')::boolean,
    '33a. two people seeing different things is carried into the path context, not averaged away');
  perform t.assert_eq(v_ctx->>'effective_state', 'developing',
    '33b. and the stronger observation still governs, exactly as Phase 3 decided');
end $$;
rollback;

begin;
do $$
declare v_ctx jsonb;
begin
  perform t.logout();
  perform t.p6_evidence('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing',
                        '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d',
    (select id from public.skills where code='NST.FR.2'), 'emerging', 'P6 I think less than that');
  perform t.logout();
  v_ctx := app.path_skill_context('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code='NST.FR.2'));
  perform t.assert_eq(v_ctx->>'effective_state', 'emerging',
    '34a. the path reads what the person decided, not what the machine computed');
  perform t.assert((v_ctx->>'human_confirmed')::boolean,
    '34b. and knows a person is behind it');
end $$;
rollback;

-- =============================================================================
-- 35-39. No numbers about a child; resources honest about themselves
-- =============================================================================

select t.assert_eq(
  (select count(*)::int from information_schema.columns
    where table_schema='public' and table_name like 'learning_path%'
      and (column_name ~ '(score|percent|percentile|mastery|readiness_level|rank|ability|grade_level|grade_equivalent)'
           or data_type in ('numeric','real','double precision'))),
  0, '35a. no learning path table holds a score, a percentage or a readiness level');

select t.assert_eq(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('app','public') and p.proname ~ 'path|learning_path'
      and p.prosrc ~* '(percentile|grade_equivalent|readiness_score|ability_score|percent)'),
  0, '35b. and nothing in the path engine computes one');

begin;
do $$
declare j jsonb; v_path uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_path := (j->>'path')::uuid;
  perform public.approve_learning_path(v_path, 'P6');
  perform t.assert_eq(
    (select count(*)::int from public.student_skills ss
      where ss.student_id='44444444-4444-4444-8444-00000000000d' and ss.skill_state='secure'), 0,
    '36a. nothing a path does arrives at secure');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare v text;
begin
  perform t.logout();
  v := t.p6_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                 '11111111-1111-4111-8111-000000000001');
  perform t.assert(v like '%NST.FR.1/continue_connected_skill |%',
    '37a. a skill with nothing attached to it is still on the path');
  perform t.assert_eq(
    (select n.resource_note from public.learning_path_nodes n
      join public.skills k on k.id = n.skill_id where k.code = 'NST.FR.1'),
    'no resource is attached to this skill yet',
    '37b. and says so, rather than being filled with something invented');
end $$;
rollback;

begin;
do $$
declare a uuid; b uuid;
begin
  perform t.logout();
  a := app.path_resource_for('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.3'));
  b := app.path_resource_for('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.3'));
  perform t.assert(a is not null, '38a. a skill with material gets material');
  perform t.assert_eq(a, b, '38b. and the same one every time it is asked');
end $$;
rollback;

select t.assert_eq(
  (select count(*)::int from public.learning_resources where is_demo),
  2, '39a. the seed resources are marked as demonstrations');
select t.assert_eq(
  (select count(*)::int from public.learning_resources r
    where r.is_demo and r.title not like 'Demo:%'),
  0, '39b. and say so in their titles, where a family would see it');
select t.assert_eq(
  (select count(*)::int from public.resource_skills rs
    join public.learning_resources r on r.id = rs.resource_id
   where r.is_demo and rs.confirmed),
  0, '39c. and no seed mapping claims a person confirmed it');

-- =============================================================================
-- G1-G5. The guards, proved alive by breaking them
-- =============================================================================

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function app.path_candidates(p_student uuid, p_root uuid)
    returns table (skill_id uuid, reason_code app.path_node_reason,
                   readiness_reasons app.path_readiness_reason[],
                   reason_rank integer, depth integer, code text)
    language sql stable security invoker set search_path = '' as $body$
      select null::uuid, null::app.path_node_reason, null::app.path_readiness_reason[],
             null::integer, null::integer, (select s.code from public.standards s limit 1);
    $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G1. the invariants accepted a path engine that reads the standards catalogue');
  exception when others then
    perform t.assert(sqlerrm like '%never choose what a child does next%',
      'G1. the invariants refuse a path engine that reads the standards catalogue');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function app.path_characterized(p_student uuid, p_skill uuid)
    returns boolean language sql stable security invoker set search_path = '' as $body$
      select exists (select 1 from public.students s
                      where s.id = p_student and s.grade_level > '3');
    $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G2. the invariants accepted a path engine that reads grade');
  exception when others then
    perform t.assert(sqlerrm like '%not from her birthday%',
      'G2. the invariants refuse a path engine that reads grade or age');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.complete_path_node(p_node uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      update public.student_skills set skill_state = 'secure' where id = p_node;
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G3. the invariants accepted a path that writes to the profile');
  exception when others then
    perform t.assert(sqlerrm like '%finishing one is not mastery%',
      'G3. the invariants refuse a path that writes to the profile');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  alter table public.student_skill_events
    add column p6_path_node_id uuid references public.learning_path_nodes(id);
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G4. the invariants accepted evidence pointing at a learning path');
  exception when others then
    perform t.assert(sqlerrm like '%Path membership is not evidence%',
      'G4. the invariants refuse a column that would make path membership into evidence');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  drop trigger learning_paths_no_silent_rewrite on public.learning_paths;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G5. the invariants accepted the loss of the approved-path guard');
  exception when others then
    perform t.assert(sqlerrm like '%no longer protected%',
      'G5. the invariants refuse the loss of the approved-path guard');
  end;
end $$;
rollback;

-- And the guard itself bites, not only its absence.
begin;
do $$
declare j jsonb; v_path uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.generate_learning_path('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code='NST.FR.1'), 4, 'P6');
  v_path := (j->>'path')::uuid;
  perform public.approve_learning_path(v_path, 'P6');
  perform t.logout();
  begin
    update public.learning_paths set generation_inputs = '{"rewritten": true}'::jsonb
     where id = v_path;
    perform t.assert(false, 'G6. an approved path was rewritten in place');
  exception when others then
    perform t.assert(sqlerrm like '%new version, not an edit%',
      'G6. an approved path cannot be rewritten in place - a new suggestion is a new version');
  end;
  begin
    update public.learning_path_nodes set reason_code = 'human_added'
     where path_id = v_path;
    perform t.assert(false, 'G7. the reason a skill was proposed was edited after the fact');
  exception when others then
    perform t.assert(sqlerrm like '%are not editable%',
      'G7. why a skill was proposed, and what was known then, cannot be edited afterwards');
  end;
end $$;
rollback;
