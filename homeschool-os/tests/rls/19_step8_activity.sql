-- =============================================================================
-- STEP 8 phase 1 - the Learning Activity and Resource engine
-- =============================================================================
-- Every block is rolled back. Rows are marked P8.
--
-- The tests that matter most are 9-13 (nothing an activity does becomes
-- evidence about a child), 3-4 (an unreviewed mapping and an unopenable
-- resource cannot reach a child), 6-7 (no material is a valid answer and the
-- path does not move to find some), and G1-G9, which prove the guards are alive
-- by breaking them one at a time.
-- =============================================================================

\set CARLA '11111111-1111-4111-8111-000000000001'
\set PEDRO '11111111-1111-4111-8111-000000000002'
\set DIEGO '11111111-1111-4111-8111-000000000003'
\set LUCAS '44444444-4444-4444-8444-00000000000d'
\set SOFIA '44444444-4444-4444-8444-00000000000f'

-- --- helpers -----------------------------------------------------------------

create or replace function t.p8_state(p_student uuid, p_code text, p_state text,
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
          p_state::app.skill_state, p_suff::app.evidence_sufficiency,
          case when p_suff = 'none' then 0 else 2 end, p_actor);
end $$;

-- A person confirms what a piece of material teaches. This is the only way a
-- mapping ever becomes eligible, and doing it here rather than in the seed is
-- the point: the migration deliberately ships nothing confirmed.
create or replace function t.p8_confirm(p_code text, p_actor uuid,
                                        p_resource uuid default null)
returns void language plpgsql as $$
begin
  update public.resource_skills rs
     set confirmed = true, confirmed_by = p_actor, confirmed_at = now()
   where rs.skill_id = (select id from public.skills where code = p_code)
     and (p_resource is null or rs.resource_id = p_resource);
end $$;

create or replace function t.p8_path(p_student uuid, p_root text, p_actor uuid,
                                     p_horizon integer default 4)
returns uuid language plpgsql as $$
declare j jsonb;
begin
  perform t.login(p_actor);
  j := public.generate_learning_path(p_student,
        (select id from public.skills where code = p_root), p_horizon, 'P8');
  perform t.logout();
  return (j->>'path')::uuid;
end $$;

create or replace function t.p8_node(p_path uuid, p_code text)
returns uuid language sql as $$
  select n.id from public.learning_path_nodes n
    join public.skills k on k.id = n.skill_id
   where n.path_id = p_path and k.code = p_code and n.status <> 'removed'
   limit 1;
$$;

-- Lucas, with the first two fraction skills characterized, so that NST.FR.3 is
-- a genuinely actionable node rather than one the reachability rule would skip.
create or replace function t.p8_ready_at_fr3(p_actor uuid)
returns uuid language plpgsql as $$
declare v_path uuid;
begin
  perform t.logout();
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported', p_actor);
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported', p_actor);
  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1', p_actor);
  return v_path;
end $$;

grant execute on function t.p8_state(uuid, text, text, text, uuid) to authenticated;
grant execute on function t.p8_confirm(text, uuid, uuid) to authenticated;
grant execute on function t.p8_path(uuid, text, uuid, integer) to authenticated;
grant execute on function t.p8_node(uuid, text) to authenticated;
grant execute on function t.p8_ready_at_fr3(uuid) to authenticated;

-- =============================================================================
-- 1. An actionable node receives an eligible confirmed resource
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_n int;
begin
  v_path := t.p8_ready_at_fr3('11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.assert(v_node is not null, '1a. the path opens on NST.FR.3 for a child who has shown the two before it');

  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  perform t.logout();

  perform t.assert_eq((j->>'selected')::boolean, true,
    '1b. an actionable node with confirmed material receives an activity');
  perform t.assert_eq(j->>'origin', 'deterministic_system_selection',
    '1c. and it is labelled a deterministic selection, not an AI proposal');
  perform t.assert(j->'reasons' ? 'confirmed_skill_match',
    '1d. and says the reason is that a person confirmed the mapping');
  select count(*)::int into v_n from public.learning_activities a
   where a.id = (j->>'activity_id')::uuid
     and a.record_provenance = 'system_computed' and a.selected_by is null
     and a.rule_version = app.learning_activity_rule_version();
  perform t.assert_eq(v_n, 1,
    '1e. the row names no person as the chooser, because no person chose it');
end $$;
rollback;

-- =============================================================================
-- 2. A goal target is not this week's work
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_n int;
begin
  perform t.logout();
  -- A mother says where they are heading. NST.FR.5 sits two unmet prerequisites
  -- away for a child with nothing, so Phase 6 keeps it as a goal target.
  insert into public.learning_goals (student_id, skill_id, title, status, source_type,
                                     entered_by, approved_by)
  values ('44444444-4444-4444-8444-00000000000d',
          (select id from public.skills where code = 'NST.FR.5'),
          'P8 we are working toward comparing fractions', 'active', 'parent',
          '11111111-1111-4111-8111-000000000001',
          '11111111-1111-4111-8111-000000000001');
  perform t.p8_confirm('NST.FR.5', '11111111-1111-4111-8111-000000000001');

  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.5');
  perform t.assert_eq((select node_kind::text from public.learning_path_nodes where id = v_node),
    'goal_target', '2a. the skill she named is kept as a goal target');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  perform t.logout();
  perform t.assert_eq((j->>'selected')::boolean, false,
    '2b. and automatic selection does not treat it as the next thing to do');
  perform t.assert_eq(j->>'reason', 'goal_target_is_not_a_next_step',
    '2c. and says so, rather than failing silently');

  select count(*)::int into v_n from public.learning_activities where path_node_id = v_node;
  perform t.assert_eq(v_n, 0, '2d. nothing was written');

  -- She may still decide to work on it directly. That is a human action.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.5'),
        'P8 comparing halves with the measuring cups', 'manipulative', 'hands_on',
        'en', null, null, 20, v_node);
  perform t.logout();
  perform t.assert_eq(j->>'origin', 'human_created',
    '2e. a parent may choose to work on a goal directly, and it is recorded as hers');
end $$;
rollback;

-- =============================================================================
-- 3. An unreviewed mapping cannot reach a child
-- =============================================================================

begin;
do $$
declare j jsonb; v_n int;
begin
  perform t.logout();
  -- NST.FR.1 has good material. Nobody has confirmed that it teaches NST.FR.1.
  select count(*)::int into v_n from public.resource_skills rs
    join public.skills k on k.id = rs.skill_id
   where k.code = 'NST.FR.1' and not rs.confirmed;
  perform t.assert(v_n >= 1, '3a. there is material mapped to NST.FR.1, unconfirmed');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.1'));
  perform t.logout();
  perform t.assert_eq((j->>'resource_available')::boolean, false,
    '3b. an unreviewed guess about what a worksheet teaches does not reach a child');
  perform t.assert_eq((j->'considered'->>'awaiting_confirmation')::int, 1,
    '3c. and it is reported as waiting for review rather than hidden');

  -- and the moment a person confirms it, it becomes eligible. Same row, same
  -- catalogue; the only thing that changed is that somebody decided.
  perform t.p8_confirm('NST.FR.1', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.1'));
  perform t.logout();
  perform t.assert_eq((j->>'resource_available')::boolean, true,
    '3d. and becomes eligible the moment a person confirms it');
end $$;
rollback;

-- =============================================================================
-- 4. Availability is not a pedagogical judgement, and it is not eligibility
-- =============================================================================

begin;
do $$
declare j jsonb;
begin
  perform t.logout();
  perform t.p8_confirm('NST.FR.2', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.2'));
  perform t.logout();

  perform t.assert_eq((j->>'resource_available')::boolean, false,
    '4a. a confirmed resource that cannot be opened is not auto-selected');
  perform t.assert_eq((j->'considered'->>'blocked_by_availability')::int, 1,
    '4b. and the family is told what is in the way rather than that nothing exists');

  -- Same resource, same mapping, same child. Only the subscription changed.
  update public.learning_resources set availability = 'available'
   where id = 'dddddddd-0000-4000-8000-000000000007';
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.2'));
  perform t.logout();
  perform t.assert_eq((j->>'resource_available')::boolean, true,
    '4c. and it is exactly as suitable as it was once access is restored');
end $$;
rollback;

-- =============================================================================
-- 5-6. The ordering: enrolment first, then the arbitrary-but-stable keys
-- =============================================================================

begin;
do $$
declare j jsonb; v_first uuid; v_second uuid;
begin
  perform t.logout();
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'));
  perform t.logout();
  v_first := (j->>'resource_id')::uuid;
  perform t.assert(v_first is not null, '5a. with five confirmed options, one is chosen');
  perform t.assert(j->'reasons' ? 'deterministic_tiebreak',
    '5b. and Nestra says the order decided it rather than implying a preference');
  perform t.assert(not (j->'reasons' ? 'active_curriculum'),
    '5c. and does not claim an enrolment the family does not have');

  -- The family buys a workbook. Now one of the five is material they own.
  insert into public.student_course_enrollments (student_id, course_id, family_id, status, created_by)
  values ('44444444-4444-4444-8444-00000000000d','dddddddd-0000-4000-8000-0000000000fe',
          '22222222-2222-4222-8222-00000000000a','active',
          '11111111-1111-4111-8111-000000000001');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'));
  perform t.logout();
  v_second := (j->>'resource_id')::uuid;
  perform t.assert_eq(v_second, 'dddddddd-0000-4000-8000-000000000003'::uuid,
    '6a. material the family is actually enrolled in wins the tie');
  perform t.assert(j->'reasons' ? 'active_curriculum',
    '6b. and the reason says exactly that');
  perform t.assert(v_second is distinct from v_first,
    '6c. which is a different answer from the one before the enrolment existed');
end $$;
rollback;

-- =============================================================================
-- 7-8. No material is an answer, and it does not move the child
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_before text; v_after text; v_n int;
begin
  perform t.logout();
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.3','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.4');
  perform t.assert(v_node is not null, '7a. NST.FR.4 is on the path');
  perform t.assert_eq((select count(*)::int from public.resource_skills rs
                        join public.skills k on k.id = rs.skill_id
                       where k.code = 'NST.FR.4'), 0,
    '7b. and there is nothing in the library for it at all');

  select string_agg(n.skill_id::text || ':' || n.position, ',' order by n.position)
    into v_before from public.learning_path_nodes n where n.path_id = v_path;

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  perform t.logout();

  perform t.assert_eq((j->>'resource_available')::boolean, false,
    '7c. no eligible resource is returned as a structured answer, not an error');
  perform t.assert_eq(j->>'reason', 'no_eligible_confirmed_resource',
    '7d. with a reason a screen can render honestly');
  perform t.assert_eq((j->>'selected')::boolean, false, '7e. and nothing was selected');

  select string_agg(n.skill_id::text || ':' || n.position, ',' order by n.position)
    into v_after from public.learning_path_nodes n where n.path_id = v_path;
  perform t.assert_eq(v_after, v_before,
    '8a. the path is byte-for-byte what it was: the model does not bend around the catalogue');
  select count(*)::int into v_n from public.learning_activities where path_node_id = v_node;
  perform t.assert_eq(v_n, 0, '8b. and nothing was invented to fill the gap');
end $$;
rollback;

-- =============================================================================
-- 9. A family's own activity, with no catalogue at all
-- =============================================================================

begin;
do $$
declare j jsonb; a public.learning_activities;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'),
        'P8 measuring cups: is 1/2 the same as 2/4?', 'manipulative', 'hands_on',
        'en', 'Use the 1/2 and 1/4 cups over the sink.', 'Fill them and see.', 15);
  perform t.logout();

  select * into a from public.learning_activities where id = (j->>'activity_id')::uuid;
  perform t.assert_eq(a.origin::text, 'human_created',
    '9a. a parent may invent an activity with no provider and no link');
  perform t.assert(a.resource_id is null,
    '9b. and it is a complete activity rather than a degraded one');
  perform t.assert_eq(a.record_provenance::text, 'human_entered',
    '9c. recorded as hers, never as something the system generated');
  perform t.assert_eq(a.created_by, '11111111-1111-4111-8111-000000000001'::uuid,
    '9d. and it names her');
  perform t.assert_eq((j->>'evidence_created')::boolean, false,
    '9e. describing what they are going to do is not a claim about what the child can do');
end $$;
rollback;

-- =============================================================================
-- 10-12. Replacement changes the material and nothing else
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_old uuid; v_new uuid;
        o public.learning_activities; n2 public.learning_activities;
        v_n int; v_before int;
begin
  v_path := t.p8_ready_at_fr3('11111111-1111-4111-8111-000000000001');
  -- The fixtures already carry evidence for this child from earlier steps, so
  -- the question is whether replacing a worksheet ADDS any - not whether the
  -- table is empty.
  select count(*)::int into v_before from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  v_old := (j->>'activity_id')::uuid;
  j := public.replace_activity_resource(v_old, 'dddddddd-0000-4000-8000-000000000005',
                                        null, 'P8 she would rather watch it');
  v_new := (j->>'activity_id')::uuid;
  perform t.logout();

  select * into o  from public.learning_activities where id = v_old;
  select * into n2 from public.learning_activities where id = v_new;

  perform t.assert_eq(o.status::text, 'replaced', '10a. the first activity is set aside');
  perform t.assert_eq(o.replaced_by_activity_id, v_new, '10b. and points at what took its place');
  perform t.assert_eq(n2.replaces_activity_id, v_old, '10c. and the record reads the same from either end');
  perform t.assert_eq(n2.origin::text, 'human_selected', '10d. a person chose the replacement, and it says so');

  perform t.assert_eq(n2.skill_id, o.skill_id,
    '11a. the target skill has not moved: this is a change of material, not of what she is working on');
  perform t.assert_eq(n2.path_node_id, o.path_node_id,
    '11b. and it is still the same step of the same path');

  select count(*)::int into v_n from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, v_before, '12a. replacing created no evidence');
  perform t.assert_eq((j->>'skill_state_changed')::boolean, false,
    '12b. and nothing about the child changed');
  perform t.assert_eq((j->>'skill_unchanged')::boolean, true,
    '12c. and the payload says so, so a screen cannot imply the first one failed');
end $$;
rollback;

-- =============================================================================
-- 13-17. Nothing an activity does is evidence, and nothing is failure
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_act uuid;
        v_states text; v_ev int; v_ss text; v_ev0 int;
begin
  v_path := t.p8_ready_at_fr3('11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');

  select count(*)::int into v_ev0 from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  select string_agg(k.code || '=' || s.skill_state::text, ',' order by k.code)
    into v_ss from public.student_skills s join public.skills k on k.id = s.skill_id
   where s.student_id = '44444444-4444-4444-8444-00000000000d';

  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  v_act := (j->>'activity_id')::uuid;
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '13a. selecting created no evidence');

  j := public.start_activity(v_act, 'P8 started');
  perform t.assert_eq((j->>'evidence_created')::boolean, false, '14a. starting created no evidence');

  j := public.complete_activity(v_act, 'P8 done');
  perform t.assert_eq((j->>'mastery_implied')::boolean, false,
    '15a. completing the activity implies nothing about the skill');
  perform t.assert_eq((j->>'skill_state_changed')::boolean, false,
    '15b. and moved no state');

  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'), 'P8 another go');
  v_act := (j->>'activity_id')::uuid;
  j := public.skip_activity(v_act, 'P8 we did something else');
  perform t.assert_eq((j->>'failure_implied')::boolean, false,
    '16a. a skipped activity is not a failure');

  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'), 'P8 a third');
  v_act := (j->>'activity_id')::uuid;
  j := public.not_today_activity(v_act, 'P8 not today');
  perform t.assert_eq((j->>'failure_implied')::boolean, false,
    '17a. and neither is not today');
  perform t.logout();

  select count(*)::int into v_ev from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_ev, v_ev0,
    '17b. after selecting, starting, completing, skipping and putting off, not one piece of evidence was added');

  select string_agg(k.code || '=' || s.skill_state::text, ',' order by k.code)
    into v_states from public.student_skills s join public.skills k on k.id = s.skill_id
   where s.student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_states, v_ss,
    '17c. and every skill state is exactly what it was before any of it happened');
end $$;
rollback;

-- =============================================================================
-- 18-19. Secure stays secure, unless a person asks
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.3','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
                                          'secure', 'P8 she has this');
  perform t.logout();

  -- A node on a confirmed-secure skill, arrived at without anybody asking to
  -- revisit it. There is plenty of material; that is not an invitation.
  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', 5);
  v_node := t.p8_node(v_path, 'NST.FR.3');
  if v_node is not null then
    perform t.login('11111111-1111-4111-8111-000000000001');
    j := public.select_activity_for_node(v_node);
    perform t.logout();
    perform t.assert_eq((j->>'selected')::boolean, false,
      '18a. a skill a person confirmed is not automatically retaught because material exists');
    perform t.assert_eq(j->>'reason', 'already_confirmed_by_a_person',
      '18b. and the refusal says why');
  else
    perform t.assert(true, '18a. (skipped: the path did not re-propose the confirmed skill at all)');
    perform t.assert(true, '18b. (skipped)');
  end if;

  -- She asks to come back to it. That is an invitation, and it is honoured.
  perform t.login('11111111-1111-4111-8111-000000000001');
  insert into public.student_skill_refresh_decisions
    (student_id, skill_id, kind, decided_by, decided_at, note)
  values ('44444444-4444-4444-8444-00000000000d', v_sk, 'revisit_requested',
          '11111111-1111-4111-8111-000000000001', now(), 'P8 let us look again');
  perform t.logout();
  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001', 5);
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.assert(v_node is not null, '19a. an explicit revisit puts the skill back on the path');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  perform t.logout();
  perform t.assert_eq((j->>'selected')::boolean, true,
    '19b. and material may be offered for it, because a person asked');
end $$;
rollback;

-- =============================================================================
-- 20. Modality is a property of the material, and of nothing else
-- =============================================================================

begin;
do $$
declare j_none jsonb; j_hands jsonb; v_n int;
begin
  perform t.logout();
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');

  perform t.login('11111111-1111-4111-8111-000000000001');
  j_none := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
              (select id from public.skills where code = 'NST.FR.3'));
  -- An EXPLICIT request, made now, for this one selection. Not a stored fact
  -- about the child and not something Nestra inferred from her history.
  j_hands := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d',
              (select id from public.skills where code = 'NST.FR.3'), null, 'hands_on');
  perform t.logout();

  perform t.assert_eq((select modality::text from public.learning_resources
                        where id = (j_hands->>'resource_id')::uuid), 'hands_on',
    '20a. asking for a hands-on activity returns one');
  perform t.assert(j_hands->'reasons' ? 'modality_match',
    '20b. and says the modality was asked for, not deduced');
  perform t.assert(not (j_none->'reasons' ? 'modality_match'),
    '20c. while a selection nobody expressed a preference for claims no modality match');

  -- and nowhere does a modality attach to the CHILD.
  select count(*)::int into v_n
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name in ('students', 'student_skills', 'profiles')
     and c.column_name ~ '(modality|learning_style|learner_type)';
  perform t.assert_eq(v_n, 0,
    '20d. no column anywhere says a child IS a kind of learner');
end $$;
rollback;

-- =============================================================================
-- 21-23. Language is answered honestly or not at all
-- =============================================================================

begin;
do $$
declare j jsonb; v_lang text; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');

  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk, 'en');
  select r.language::text into v_lang from public.learning_resources r
   where r.id = (j->>'resource_id')::uuid;
  perform t.assert(v_lang in ('en','bilingual','language_neutral'),
    '21a. a family asking for English gets English, bilingual or language-neutral material');
  perform t.assert(j->'reasons' ? 'language_match', '21b. and the reason says so');

  j := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk, 'es');
  select r.language::text into v_lang from public.learning_resources r
   where r.id = (j->>'resource_id')::uuid;
  perform t.assert(v_lang in ('es','bilingual','language_neutral'),
    '22a. una familia que pide espanol recibe material en espanol, bilingue o sin idioma');

  -- The bilingual row satisfies both requests, which is the whole reason
  -- `bilingual` is its own label rather than two rows.
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk, 'es') c
      where c.resource_id = 'dddddddd-0000-4000-8000-000000000005'), 1,
    '23a. bilingual material is eligible for a Spanish request');
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk, 'en') c
      where c.resource_id = 'dddddddd-0000-4000-8000-000000000005'), 1,
    '23b. and for an English one');

  -- and material whose language nobody recorded does NOT satisfy an explicit
  -- requirement. "We do not know" is not Spanish.
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk, 'es') c
      where c.resource_id = 'dddddddd-0000-4000-8000-000000000006'), 0,
    '23c. material of unrecorded language does not satisfy an explicit language requirement');
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk) c
      where c.resource_id = 'dddddddd-0000-4000-8000-000000000006'), 1,
    '23d. but is perfectly eligible when nobody asked for a language');
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 24. Provider provenance survives selection
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; e jsonb;
begin
  v_path := t.p8_ready_at_fr3('11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  e := public.explain_activity((j->>'activity_id')::uuid);
  perform t.logout();

  perform t.assert_eq(e->'resource'->>'content_ownership', 'nestra_owned',
    '24a. the explanation still says who owns the material');
  perform t.assert(e->'resource'->>'license_note' is not null,
    '24b. and what Nestra is permitted to do with it');
  perform t.assert_eq(e->'resource'->>'integration_mode', 'manual',
    '24c. and does not claim an integration that does not exist');
end $$;
rollback;

-- =============================================================================
-- 25. The same question, asked twice, gets the same answer
-- =============================================================================

begin;
do $$
declare a jsonb; b jsonb; c jsonb; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  a := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  b := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  c := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  perform t.assert_eq(a::text, b::text, '25a. the same inputs give the same selection');
  perform t.assert_eq(b::text, c::text, '25b. and again');
end $$;
rollback;

-- =============================================================================
-- 26-27. The standards catalogue cannot change what a child is offered
-- =============================================================================
-- Proved by taking the catalogue away entirely rather than by reading the code.
-- If anything in the selector touched it, the rename would break the call.

begin;
do $$
declare a jsonb; b jsonb; v_sk uuid; v_n int;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  select count(*)::int into v_n from public.standards;
  perform t.assert(v_n > 100, '26a. there is a real standards catalogue present');

  perform t.login('11111111-1111-4111-8111-000000000001');
  a := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();

  alter table public.standards      rename to standards_hidden_p8;
  alter table public.skill_standards rename to skill_standards_hidden_p8;
  alter table public.standards_texts rename to standards_texts_hidden_p8;

  perform t.login('11111111-1111-4111-8111-000000000001');
  b := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  perform t.assert_eq(a::text, b::text,
    '26b. with the entire standards catalogue renamed out from under it, the same resource is chosen');

  alter table public.standards_hidden_p8       rename to standards;
  alter table public.skill_standards_hidden_p8 rename to skill_standards;
  alter table public.standards_texts_hidden_p8 rename to standards_texts;
end $$;
rollback;

begin;
do $$
declare a jsonb; b jsonb; c jsonb; v_sk uuid; v_std uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  a := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();

  select id into v_std from public.standards limit 1;
  delete from public.skill_standards where skill_id = v_sk;
  perform t.login('11111111-1111-4111-8111-000000000001');
  b := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  perform t.assert_eq(a::text, b::text,
    '27a. removing every standards mapping from the skill changes nothing about what is offered');

  insert into public.skill_standards (skill_id, standard_id, relation, source_type,
                                      status, approved_by, approved_at)
  values (v_sk, v_std, 'related', 'manual', 'approved',
          '11111111-1111-4111-8111-000000000001', now());
  perform t.login('11111111-1111-4111-8111-000000000001');
  c := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  perform t.assert_eq(a::text, c::text,
    '27b. and adding one changes nothing either');
end $$;
rollback;

-- =============================================================================
-- 28-29. A birthday and a grade label decide nothing
-- =============================================================================

begin;
do $$
declare a jsonb; b jsonb; c jsonb; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  a := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();

  update public.students set grade_level = '1'
   where id = '44444444-4444-4444-8444-00000000000d';
  perform t.login('11111111-1111-4111-8111-000000000001');
  b := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  perform t.assert_eq(a::text, b::text,
    '28a. moving the child from grade 5 to grade 1 changes nothing about what is offered');

  update public.students set grade_level = '12', date_of_birth = date '2004-01-01'
   where id = '44444444-4444-4444-8444-00000000000d';
  perform t.login('11111111-1111-4111-8111-000000000001');
  c := app.learning_activity_select_resource('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.logout();
  perform t.assert_eq(a::text, c::text,
    '29a. and making her twenty-two changes nothing either');
end $$;
rollback;

-- =============================================================================
-- 30-31. A person's choice is not quietly overruled
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; v_mine uuid; v_after uuid;
begin
  v_path := t.p8_ready_at_fr3('11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');

  -- She picks the video herself. The ordering would not have chosen it.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.choose_activity_resource('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'),
        'dddddddd-0000-4000-8000-000000000005', v_node, 'P8 she likes the video');
  v_mine := (j->>'activity_id')::uuid;

  -- Nestra is asked to choose for the same step.
  j := public.select_activity_for_node(v_node);
  perform t.logout();

  perform t.assert_eq((j->>'selected')::boolean, false,
    '30a. the selector does not overwrite a resource a person chose');
  perform t.assert_eq(j->>'reason', 'a_choice_already_stands', '30b. and says why');
  perform t.assert_eq((j->>'activity_id')::uuid, v_mine,
    '30c. handing back the one she picked');

  select a.resource_id into v_after from public.learning_activities a where a.id = v_mine;
  perform t.assert_eq(v_after, 'dddddddd-0000-4000-8000-000000000005'::uuid,
    '31a. and her row is untouched');
  perform t.assert_eq((select origin::text from public.learning_activities where id = v_mine),
    'human_selected', '31b. still recorded as her choice');
  perform t.assert_eq((select count(*)::int from public.learning_activities
                        where path_node_id = v_node
                          and status in ('proposed','selected','available','started')), 1,
    '31c. and there is exactly one live activity on the step, not two');
end $$;
rollback;

-- =============================================================================
-- 32-33. Other people's children, and people who may only look
-- =============================================================================

begin;
do $$
declare j jsonb; v_act uuid; v_n int; v_err text;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'), 'P8 Lucas only');
  v_act := (j->>'activity_id')::uuid;
  perform t.logout();

  -- Diego is a guardian. Of a different child, in a different family.
  perform t.login('11111111-1111-4111-8111-000000000003');
  select count(*)::int into v_n from public.learning_activities a where a.id = v_act;
  perform t.assert_eq(v_n, 0, '32a. another family''s guardian cannot see the activity');
  select count(*)::int into v_n from public.learning_activity_events e where e.activity_id = v_act;
  perform t.assert_eq(v_n, 0, '32b. nor its history');
  select count(*)::int into v_n from public.learning_activities a
   where a.student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_n, 0, '32c. nor anything else belonging to that child');

  begin
    perform public.complete_activity(v_act);
    perform t.assert(false, '32d. another family''s guardian completed an activity');
  exception when others then
    perform t.assert(true, '32d. and cannot act on it either');
  end;
  perform t.logout();

  -- Pedro may look at Lucas. He may not decide for him.
  perform t.login('11111111-1111-4111-8111-000000000002');
  select count(*)::int into v_n from public.learning_activities a where a.id = v_act;
  perform t.assert_eq(v_n, 1, '33a. a view-only guardian can see the activity');
  begin
    perform public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.3'), 'P8 Pedro should not');
    perform t.assert(false, '33b. a view-only guardian created an activity');
  exception when others then
    perform t.assert(true, '33b. and may not create one');
  end;
  begin
    perform public.complete_activity(v_act);
    perform t.assert(false, '33c. a view-only guardian completed an activity');
  exception when others then
    perform t.assert(true, '33c. nor mark one done');
  end;
  perform t.logout();
end $$;
rollback;

-- =============================================================================
-- 34. "Why this one" is answerable from the record
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; j jsonb; e jsonb;
begin
  v_path := t.p8_ready_at_fr3('11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.3');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.select_activity_for_node(v_node);
  e := public.explain_activity((j->>'activity_id')::uuid);
  perform t.logout();

  perform t.assert_eq(e->'reasons', j->'reasons',
    '34a. the stored reasons are the ones the selection returned');
  perform t.assert(e->'selection_context'->'considered' is not null,
    '34b. and what else was looked at is kept, not re-derived');
  perform t.assert_eq(e->>'rule_version', app.learning_activity_rule_version(),
    '34c. stamped with the rules in force when it was chosen');
  perform t.assert_eq((e->>'standards_consulted')::boolean, false,
    '34d. and states plainly that no standard was consulted');
  perform t.assert_eq((e->>'grade_or_age_consulted')::boolean, false,
    '34e. and no grade or age');
  perform t.assert_eq((e->>'chosen_by_a_person')::boolean, false,
    '34f. and that no person chose this one, so nobody is credited who did not decide');
end $$;
rollback;

-- =============================================================================
-- 35. A demonstration is never dressed up as curriculum
-- =============================================================================

select t.assert_eq(
  (select count(*)::int from public.learning_resources r
     join public.courses c on c.id = r.course_id
    where c.name like 'Nestra demonstration%' and not r.is_demo),
  0, '35a. every resource in a demonstration course is marked as a demonstration');
select t.assert_eq(
  (select count(*)::int from public.learning_resources
    where is_demo and (content_ownership <> 'nestra_owned' or license_note is null)),
  0, '35b. and says who owns it and what Nestra may do with it');
select t.assert_eq(
  (select count(*)::int from public.learning_resources
    where is_demo and integration_mode = 'integrated'),
  0, '35c. and claims no live integration, because there is none');
select t.assert_eq(
  (select count(*)::int from public.resource_skills rs
     join public.learning_resources r on r.id = rs.resource_id
    where r.is_demo and rs.confirmed),
  0, '35d. and no seeded mapping claims a person confirmed it');
select t.assert_eq(
  (select count(*)::int from public.learning_resources r
    where r.is_demo and r.title not like 'Demo:%'),
  0, '35e. and says so in the title, where a family would actually see it');

-- =============================================================================
-- G1-G11. The guards, proved alive by breaking them
-- =============================================================================
-- A structural invariant nobody has watched fail is a comment. Each of these
-- writes the exact violation it is supposed to catch, checks that
-- app.assert_schema_invariants() refuses it, and rolls the damage back.

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.explain_activity(p_activity uuid)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      return (select to_jsonb(s.code) from public.standards s limit 1);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G1. the invariants accepted an activity function that reads the standards catalogue');
  exception when others then
    perform t.assert(sqlerrm like '%never choose what a child does%',
      'G1. an activity function that reads the standards catalogue is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.explain_activity(p_activity uuid)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      return (select to_jsonb(st.date_of_birth) from public.students st limit 1);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G2. the invariants accepted an activity function that reads a birthday');
  exception when others then
    perform t.assert(sqlerrm like '%never from a birthday%',
      'G2. an activity function that routes on grade or age is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.skip_activity(p_activity uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      insert into public.student_skill_events (student_skill_id) values (null);
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G3. the invariants accepted an activity function that writes evidence');
  exception when others then
    perform t.assert(sqlerrm like '%finishing it is not mastery%',
      'G3. an activity function that writes to the profile is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.explain_activity(p_activity uuid)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    declare v app.skill_state;
    begin
      select s.skill_state into v from public.student_skills s limit 1;
      return to_jsonb(v);
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G4. the invariants accepted an activity function that reads computed state');
  exception when others then
    perform t.assert(sqlerrm like '%a fact about a morning%',
      'G4. an activity function that names a child''s computed state is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  -- The single most damaging change anybody could make to this file: drop the
  -- word `confirmed` and every unreviewed guess in the catalogue starts
  -- reaching children, with no other symptom at all.
  execute $x$
    create or replace function app.learning_activity_candidates(
      p_student uuid, p_skill uuid,
      p_language app.learning_resource_language default null,
      p_modality app.learning_activity_modality default null)
    returns table (resource_id uuid, from_active_curriculum boolean,
                   modality_matched boolean, kind_text text, title text, rank integer)
    language sql stable security invoker set search_path = '' as $body$
      select r.id, false, false, r.kind::text, r.title, 1
        from public.learning_resources r
        join public.resource_skills rs on rs.resource_id = r.id
       where rs.skill_id = p_skill;
    $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G5. the invariants accepted a selector that ignores whether a mapping was confirmed');
  exception when others then
    perform t.assert(sqlerrm like '%may not decide what a child receives%',
      'G5. a selector that no longer requires a confirmed mapping is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  execute $x$
    create or replace function public.skip_activity(p_activity uuid, p_note text default null)
    returns jsonb language plpgsql security invoker set search_path = '' as $body$
    begin
      update public.learning_path_nodes set position = position + 1 where false;
      return '{}'::jsonb;
    end $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G6. the invariants accepted an activity function that rewrites the path');
  exception when others then
    perform t.assert(sqlerrm like '%does not bend around%',
      'G6. an activity function that rewrites the learning path is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  -- The arrow the other way: a path that consults availability is a path a
  -- lapsed subscription can reorder.
  execute $x$
    create or replace function app.path_resource_for(p_student uuid, p_skill uuid)
    returns uuid language sql stable security invoker set search_path = '' as $body$
      select r.id from public.learning_resources r
       where r.availability = 'available' limit 1;
    $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G7. the invariants accepted a path engine that reads resource availability');
  exception when others then
    perform t.assert(sqlerrm like '%what a subscription happens to cover%',
      'G7. a learning path that reads resource availability is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  drop trigger la_no_goal_target_autoselection on public.learning_activities;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G8. the invariants accepted the goal-target guard being removed');
  exception when others then
    perform t.assert(sqlerrm like '%activity guards are missing%',
      'G8. removing the goal-target guard is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  alter table public.learning_activities add column failed boolean not null default false;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G9. the invariants accepted a failure column on an activity');
  exception when others then
    perform t.assert(sqlerrm like '%a skipped morning%',
      'G9. a column that would mark a child as having failed is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  alter table public.student_skill_events
    add column activity_id uuid references public.learning_activities(id);
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G10. the invariants accepted evidence pointing at an activity');
  exception when others then
    perform t.assert(sqlerrm like '%may not become a column that implies it%',
      'G10. evidence that points back at an activity is refused');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  alter table public.learning_activities add column score integer;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'G11. the invariants accepted a score on an activity');
  exception when others then
    perform t.assert(sqlerrm like '%not a percentage%',
      'G11. a score column on an activity is refused');
  end;
end $$;
rollback;

-- =============================================================================
-- N1-N5. The same refusals, at the row rather than in a review
-- =============================================================================

begin;
do $$
declare v_path uuid; v_node uuid; v_sk uuid;
begin
  perform t.logout();
  insert into public.learning_goals (student_id, skill_id, title, status, source_type,
                                     entered_by, approved_by)
  values ('44444444-4444-4444-8444-00000000000d',
          (select id from public.skills where code = 'NST.FR.5'),
          'P8 goal', 'active', 'parent',
          '11111111-1111-4111-8111-000000000001',
          '11111111-1111-4111-8111-000000000001');
  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001');
  v_node := t.p8_node(v_path, 'NST.FR.5');
  select skill_id into v_sk from public.learning_path_nodes where id = v_node;

  begin
    insert into public.learning_activities (student_id, skill_id, path_node_id, title,
                                            origin, record_provenance, rule_version)
    values ('44444444-4444-4444-8444-00000000000d', v_sk, v_node, 'N1',
            'deterministic_system_selection', 'system_computed', 'x');
    perform t.assert(false, 'N1. a system-selected activity was attached to a goal target');
  exception when others then
    perform t.assert(sqlerrm like '%not a claim the child is%',
      'N1. the row itself refuses a system-selected activity on a goal target');
  end;
end $$;
rollback;

begin;
do $$
declare j jsonb; v_act uuid; v_other uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'), 'P8 N2');
  v_act := (j->>'activity_id')::uuid;
  perform t.logout();
  select id into v_other from public.skills where code = 'NST.FR.5';

  begin
    update public.learning_activities set skill_id = v_other where id = v_act;
    perform t.assert(false, 'N2. the target skill of an activity was moved');
  exception when others then
    perform t.assert(sqlerrm like '%does not move%',
      'N2. the skill an activity is for cannot be moved out from under it');
  end;

  begin
    update public.learning_activities set origin = 'deterministic_system_selection'
     where id = v_act;
    perform t.assert(false, 'N3. a parent''s own activity was relabelled as a system selection');
  exception when others then
    perform t.assert(sqlerrm like '%not editable%',
      'N3. how an activity came to exist cannot be rewritten afterwards');
  end;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  begin
    insert into public.learning_activities (student_id, skill_id, title, origin,
                                            record_provenance, created_by)
    values ('44444444-4444-4444-8444-00000000000d',
            (select id from public.skills where code = 'NST.FR.3'), 'N4',
            'human_created', 'system_computed',
            '11111111-1111-4111-8111-000000000001');
    perform t.assert(false, 'N4. a human-created activity claimed system provenance');
  exception when others then
    perform t.assert(sqlerrm like '%la_provenance_matches_origin_ck%',
      'N4. an activity''s provenance may not contradict where it came from');
  end;

  -- A person who SELECTED something from the catalogue has to have selected
  -- something. Without this, `human_selected` with no resource would be a
  -- choice nobody could name.
  begin
    insert into public.learning_activities (student_id, skill_id, title, origin,
                                            record_provenance, selected_by)
    values ('44444444-4444-4444-8444-00000000000d',
            (select id from public.skills where code = 'NST.FR.3'), 'N5',
            'human_selected', 'human_entered',
            '11111111-1111-4111-8111-000000000001');
    perform t.assert(false, 'N5. a catalogue selection named no resource');
  exception when others then
    perform t.assert(sqlerrm like '%la_human_selected_names_its_resource_ck%',
      'N5. a catalogue selection has to name the thing that was selected');
  end;

  -- and an activity a person WROTE carries no rule version and no engine
  -- reasons, whatever is attached to it. This is what stops her idea being
  -- recorded as something an ordering produced.
  begin
    insert into public.learning_activities (student_id, skill_id, title, origin,
                                            record_provenance, created_by, rule_version)
    values ('44444444-4444-4444-8444-00000000000d',
            (select id from public.skills where code = 'NST.FR.3'), 'N8',
            'human_created', 'human_entered',
            '11111111-1111-4111-8111-000000000001', '2026-09-13.1');
    perform t.assert(false, 'N8. an authored activity was stamped with a selection rule version');
  exception when others then
    perform t.assert(sqlerrm like '%la_authored_activity_is_not_a_selection_ck%',
      'N8. an activity a person wrote is never recorded as one an ordering produced');
  end;
end $$;
rollback;

begin;
do $$
declare j jsonb; v_act uuid; v_ev uuid;
begin
  perform t.logout();
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'), 'P8 N6');
  v_act := (j->>'activity_id')::uuid;
  perform t.logout();
  select id into v_ev from public.learning_activity_events where activity_id = v_act limit 1;

  begin
    update public.learning_activity_events set note = 'rewritten' where id = v_ev;
    perform t.assert(false, 'N6. an activity event was rewritten');
  exception when others then
    perform t.assert(true, 'N6. what a family decided about an activity is append-only');
  end;
  begin
    delete from public.learning_activity_events where id = v_ev;
    perform t.assert(false, 'N7. an activity event was deleted');
  exception when others then
    perform t.assert(true, 'N7. and cannot be deleted either');
  end;
end $$;
rollback;

-- =============================================================================
-- A1-A6. A person may compose an activity AND attach material to it
-- =============================================================================
-- "Practise with the measuring cups, then watch this video" is one activity a
-- mother wrote. The video supports it; the video is not what it is. What
-- separates human_created from human_selected is who composed the thing, not
-- whether a resource is attached.

begin;
do $$
declare j_bare jsonb; j_res jsonb; a public.learning_activities;
        b public.learning_activities; e jsonb; v_sel uuid;
begin
  perform t.logout();
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');

  j_bare := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'),
        'P8 measuring cups in the kitchen', 'manipulative', 'hands_on', 'en',
        'Use the 1/2 and 1/4 cups.', null, 15);
  perform t.assert_eq((j_bare->>'origin'), 'human_created',
    'A1. a composed activity with no material at all succeeds');
  perform t.assert_eq((j_bare->>'resource_available')::boolean, false,
    'A1b. and honestly reports that there is no material behind it');

  j_res := public.create_custom_activity('44444444-4444-4444-8444-00000000000d',
        (select id from public.skills where code = 'NST.FR.3'),
        'P8 measuring cups, then watch the video', 'manipulative', 'hands_on', 'en',
        'Cups first, video after.', null, 25, null,
        'dddddddd-0000-4000-8000-000000000005');
  perform t.logout();

  select * into b from public.learning_activities where id = (j_res->>'activity_id')::uuid;
  perform t.assert_eq(b.resource_id, 'dddddddd-0000-4000-8000-000000000005'::uuid,
    'A2. the same call may attach a supporting resource');
  perform t.assert_eq(b.origin::text, 'human_created',
    'A4. and the resource does not become the origin of the activity');
  perform t.assert_eq(b.record_provenance::text, 'human_entered',
    'A3. the provenance is still hers');
  perform t.assert_eq(b.created_by, '11111111-1111-4111-8111-000000000001'::uuid,
    'A3b. and it names her');
  perform t.assert_eq(b.title, 'P8 measuring cups, then watch the video',
    'A4b. the title is the one she wrote, not the resource''s');
  perform t.assert(b.rule_version is null,
    'A4c. no rule version, because no ordering produced it');
  perform t.assert_eq(array_length(b.selection_reasons, 1), null,
    'A4d. and no engine reasons either');

  -- the provider and ownership behind the supporting material stay traceable,
  -- frozen at the moment she attached it.
  perform t.assert_eq(b.resource_snapshot->>'content_ownership', 'nestra_owned',
    'A5. who owns the supporting material is recorded on the activity');
  perform t.assert(b.resource_snapshot->>'license_note' is not null,
    'A5b. along with what Nestra may do with it');
  perform t.assert_eq((b.resource_snapshot->>'is_demo')::boolean, true,
    'A5c. and that it is a demonstration');

  perform t.login('11111111-1111-4111-8111-000000000001');
  e := public.explain_activity(b.id);
  perform t.assert_eq((e->>'chosen_by_a_person')::boolean, true,
    'A5d. the explanation credits her');

  -- and a catalogue selection is still a different sentence.
  v_sel := (public.choose_activity_resource('44444444-4444-4444-8444-00000000000d',
             (select id from public.skills where code = 'NST.FR.3'),
             'dddddddd-0000-4000-8000-000000000005')->>'activity_id')::uuid;
  perform t.logout();
  select * into a from public.learning_activities where id = v_sel;
  perform t.assert_eq(a.origin::text, 'human_selected',
    'A6. picking something from the catalogue is still human_selected');
  perform t.assert(a.selected_by is not null and a.created_by is null,
    'A6b. which names her as the chooser rather than the author');
  perform t.assert(b.selected_by is null and b.created_by is not null,
    'A6c. and composing names her as the author rather than the chooser');
  perform t.assert_eq(a.title, 'Demo: equivalent fractions / fracciones equivalentes',
    'A6d. a selection carries the resource''s own title, because the resource is the activity');
end $$;
rollback;

-- =============================================================================
-- B. Working with a secure skill again changes nothing about the child
-- =============================================================================

begin;
do $$
declare v_sk uuid; j jsonb; v_act uuid;
        v_state text; v_state2 text; v_ov int; v_ov2 int;
        v_ev int; v_ev2 int; v_ref int; v_ref2 int;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.3','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.set_skill_state_override('44444444-4444-4444-8444-00000000000d', v_sk,
                                          'secure', 'P8 she has this');
  perform t.logout();

  select s.skill_state::text into v_state from public.student_skills s
   where s.student_id = '44444444-4444-4444-8444-00000000000d' and s.skill_id = v_sk;
  select count(*)::int into v_ov from public.student_skill_overrides
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk;
  select count(*)::int into v_ev from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  select count(*)::int into v_ref from public.student_skill_refresh_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d';

  -- She works on it again anyway, deliberately, and takes it all the way
  -- through: chosen, started, completed.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.choose_activity_resource('44444444-4444-4444-8444-00000000000d', v_sk,
        'dddddddd-0000-4000-8000-000000000005', null, 'P8 one more look');
  v_act := (j->>'activity_id')::uuid;
  perform public.start_activity(v_act);
  j := public.complete_activity(v_act, 'P8 done again');
  perform t.logout();

  perform t.assert_eq((j->>'mastery_implied')::boolean, false,
    'B1. completing an activity on a secure skill implies nothing about mastery');

  select s.skill_state::text into v_state2 from public.student_skills s
   where s.student_id = '44444444-4444-4444-8444-00000000000d' and s.skill_id = v_sk;
  perform t.assert_eq(v_state2, v_state,
    'B2. and secure did not move: no downgrade, no regression');
  perform t.assert_eq(v_state2, 'secure', 'B2b. it is still secure');

  select count(*)::int into v_ov2 from public.student_skill_overrides
   where student_id = '44444444-4444-4444-8444-00000000000d' and skill_id = v_sk;
  perform t.assert_eq(v_ov2, v_ov, 'B3. her confirmation was not touched');

  select count(*)::int into v_ev2 from public.student_skill_events
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_ev2, v_ev, 'B4. no evidence was created');

  select count(*)::int into v_ref2 from public.student_skill_refresh_decisions
   where student_id = '44444444-4444-4444-8444-00000000000d';
  perform t.assert_eq(v_ref2, v_ref,
    'B5. and no refresh requirement appeared merely because an activity exists');
end $$;
rollback;

-- =============================================================================
-- C1-C6. Availability: a faithful backfill, and an honest default afterwards
-- =============================================================================

begin;
do $$
declare v_new uuid; j jsonb; v_avail text; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';

  -- C1 is proved over genuinely pre-STEP-8 data in tests/migration (section 12);
  -- here the same guarantee is checked against the rows STEP 5 and 6 shipped.
  perform t.assert_eq(
    (select count(*)::int from public.learning_resources r
      where r.availability = 'unknown'
        and r.id in ('dddddddd-0000-4000-8000-000000000001',
                     'dddddddd-0000-4000-8000-000000000002')), 0,
    'C1. catalogue rows that predate STEP 8 were not retroactively restricted');

  -- C2. A row written from here on says nobody has established availability.
  insert into public.learning_resources (course_id, kind, title)
  values ('dddddddd-0000-4000-8000-0000000000ff', 'practice', 'P8 brand new resource')
  returning id into v_new;
  select availability::text into v_avail from public.learning_resources where id = v_new;
  perform t.assert_eq(v_avail, 'unknown',
    'C2. a resource created after this migration defaults to unknown, not available');

  -- C3. And unknown is not automatically selectable, even fully confirmed.
  insert into public.resource_skills (resource_id, skill_id, source_type, confirmed,
                                      confirmed_by, confirmed_at)
  values (v_new, v_sk, 'manual', true, '11111111-1111-4111-8111-000000000001', now());
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk) c where c.resource_id = v_new), 0,
    'C3. a confirmed resource whose availability nobody established is not auto-selected');

  -- C4. Somebody establishes it, and nothing else changes.
  update public.learning_resources set availability = 'available' where id = v_new;
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk) c where c.resource_id = v_new), 1,
    'C4. once a person establishes it, the same row is eligible');

  -- C5. Explicitly blocked stays blocked.
  update public.learning_resources set availability = 'unavailable' where id = v_new;
  perform t.assert_eq(
    (select count(*)::int from app.learning_activity_candidates(
       '44444444-4444-4444-8444-00000000000d', v_sk) c where c.resource_id = v_new), 0,
    'C5. an explicitly unavailable resource is not auto-selected');

  -- C6. And a family is never shown "unknown" as though it meant "unavailable".
  -- Both labels exist, and they do not say the same thing in either language.
  perform t.assert(
    app.learning_activity_supply('44444444-4444-4444-8444-00000000000d', v_sk)
      ->>'blocked_by_availability' is not null,
    'C6. what is blocked is counted separately from what exists');
end $$;
rollback;

-- =============================================================================
-- D. The lifecycle graph, every cell of it
-- =============================================================================
-- 81 pairs, checked against the matrix written down rather than against the
-- function's own opinion of itself. A graph that is only tested by the code
-- that implements it is not tested.

begin;
do $$
declare
  v_states text[] := array['proposed','selected','available','started',
                           'completed','skipped','not_today','replaced','archived'];
  -- The matrix, transcribed. Same-status is allowed everywhere (an update that
  -- does not move the status is not a transition), so it is excluded here and
  -- checked separately.
  v_allowed jsonb := jsonb_build_object(
    'proposed',  jsonb_build_array('selected','available','skipped','not_today','replaced','archived'),
    'selected',  jsonb_build_array('available','started','skipped','not_today','replaced','archived'),
    'available', jsonb_build_array('selected','started','skipped','not_today','replaced','archived'),
    'started',   jsonb_build_array('completed','skipped','not_today','replaced','archived'),
    'completed', jsonb_build_array('archived'),
    'skipped',   jsonb_build_array('selected','available','started','replaced','archived'),
    'not_today', jsonb_build_array('selected','available','started','replaced','archived'),
    'replaced',  jsonb_build_array(),
    'archived',  jsonb_build_array());
  f text; tt text; v_want boolean; v_got boolean; v_bad text := '';
  v_pairs int := 0;
begin
  perform t.logout();
  foreach f in array v_states loop
    foreach tt in array v_states loop
      continue when f = tt;
      v_pairs := v_pairs + 1;
      v_want := v_allowed->f ? tt;
      v_got  := app.learning_activity_transition_allowed(
                  f::app.learning_activity_status, tt::app.learning_activity_status);
      if v_want is distinct from v_got then
        v_bad := v_bad || format('%s->%s want %s got %s; ', f, tt, v_want, v_got);
      end if;
    end loop;
  end loop;
  perform t.assert_eq(v_pairs, 72, 'D1. every ordered pair of distinct statuses was checked');
  perform t.assert_eq(v_bad, '', 'D2. and the graph matches the matrix exactly: ' || v_bad);

  foreach f in array v_states loop
    perform t.assert(app.learning_activity_transition_allowed(
        f::app.learning_activity_status, f::app.learning_activity_status),
      'D3. an update that does not move the status is never a transition: ' || f);
  end loop;

  -- The three endings, named individually because they are the point.
  perform t.assert(not app.learning_activity_transition_allowed('completed','started'),
    'D4. a completed activity is never un-completed');
  perform t.assert(not app.learning_activity_transition_allowed('completed','not_today'),
    'D5. nor put off after the fact');
  perform t.assert(not app.learning_activity_transition_allowed('replaced','started'),
    'D6. a replaced activity stays replaced');
  perform t.assert(not app.learning_activity_transition_allowed('archived','started'),
    'D7. an archived activity stays archived');
  perform t.assert_eq(app.learning_activity_transition_refusal('completed','started'),
    'a_completed_activity_is_not_undone', 'D8. and the refusal is a code, not an opaque error');
end $$;
rollback;

begin;
do $$
declare j jsonb; v_act uuid; v_sk uuid; v_status text;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d', v_sk, 'P8 D');
  v_act := (j->>'activity_id')::uuid;

  -- selected -> completed is not a step. You start something before you finish it.
  j := public.complete_activity(v_act);
  perform t.assert_eq((j->>'moved')::boolean, false,
    'D9. a step the activity cannot take from here is refused, structurally');
  perform t.assert_eq(j->>'reason', 'not_a_step_this_activity_can_take_from_here',
    'D10. with a code a screen can render');
  perform t.assert(j->'allowed_next' ? 'started',
    'D11. and the answer says what it CAN do instead');
  perform t.assert_eq((j->>'evidence_created')::boolean, false,
    'D12. and a refused transition still creates no evidence');
  select status::text into v_status from public.learning_activities where id = v_act;
  perform t.assert_eq(v_status, 'selected', 'D13. nothing moved');

  -- The real path: start, then finish.
  perform public.start_activity(v_act);
  j := public.complete_activity(v_act);
  perform t.assert_eq((j->>'moved')::boolean, true, 'D14. started then completed works');

  -- And afterwards the morning stays on the record.
  j := public.start_activity(v_act);
  perform t.assert_eq(j->>'reason', 'a_completed_activity_is_not_undone',
    'D15. a completed activity is not restarted');
  j := public.not_today_activity(v_act);
  perform t.assert_eq(j->>'reason', 'a_completed_activity_is_not_undone',
    'D16. nor put off');
  j := public.reopen_activity(v_act);
  perform t.assert_eq((j->>'moved')::boolean, false, 'D17. nor reopened');
  j := public.archive_activity(v_act);
  perform t.assert_eq((j->>'moved')::boolean, true, 'D18. archiving it is the one thing left');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare j jsonb; v_act uuid; v_sk uuid; v_status text;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d', v_sk, 'P8 Tuesday');
  v_act := (j->>'activity_id')::uuid;

  -- Tuesday went sideways.
  j := public.not_today_activity(v_act, 'P8 the baby was up all night');
  perform t.assert_eq((j->>'moved')::boolean, true, 'D19. a morning can be put off');
  perform t.assert_eq((j->>'failure_implied')::boolean, false, 'D20. and it is not a failure');

  -- Thursday came back.
  j := public.reopen_activity(v_act, 'selected', 'P8 picking this back up');
  perform t.assert_eq((j->>'moved')::boolean, true,
    'D21. and it can be picked back up without inventing a second row');
  select status::text into v_status from public.learning_activities where id = v_act;
  perform t.assert_eq(v_status, 'selected', 'D22. it really moved');

  j := public.skip_activity(v_act, 'P8 actually no');
  j := public.reopen_activity(v_act, 'started', 'P8 changed my mind again');
  perform t.assert_eq((j->>'moved')::boolean, true, 'D23. a skipped one reopens too');
  select status::text into v_status from public.learning_activities where id = v_act;
  perform t.assert_eq(v_status, 'started', 'D24. straight to started, because she is doing it now');
  perform t.logout();
end $$;
rollback;

begin;
do $$
declare j jsonb; v_act uuid; v_sk uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.create_custom_activity('44444444-4444-4444-8444-00000000000d', v_sk, 'P8 direct');
  v_act := (j->>'activity_id')::uuid;
  perform public.start_activity(v_act);
  perform public.complete_activity(v_act);
  perform t.logout();

  -- The RPCs refuse politely. The row refuses absolutely, so that a future code
  -- path cannot reach the same wrong place by a different route.
  begin
    update public.learning_activities set status = 'started' where id = v_act;
    perform t.assert(false, 'D25. a direct update un-completed an activity');
  exception when others then
    perform t.assert(sqlerrm like '%cannot go from completed to started%',
      'D25. the row itself refuses to un-complete an activity');
  end;

  begin
    update public.learning_activities set status = 'proposed' where id = v_act;
    perform t.assert(false, 'D26. a direct update put a completed activity back to proposed');
  exception when others then
    perform t.assert(true, 'D26. and refuses to put it back to a proposal');
  end;

  -- Replacing something that already happened is refused too, and structurally.
  perform t.login('11111111-1111-4111-8111-000000000001');
  j := public.replace_activity_resource(v_act, 'dddddddd-0000-4000-8000-000000000005');
  perform t.logout();
  perform t.assert_eq((j->>'replaced')::boolean, false,
    'D27. a completed activity is not swapped out after the fact');
  perform t.assert_eq(j->>'reason', 'a_completed_activity_is_not_undone',
    'D28. with the same code');
end $$;
rollback;

-- =============================================================================
-- F1-F6. One definition of "the curriculum this family is using"
-- =============================================================================
-- Phase 6 preferred material from ANY enrolment row; STEP 8 prefers ACTIVE
-- enrolment. 0108 aligns them forward. These prove the alignment happened and
-- that nothing else about the Learning Path moved.

begin;
do $$
declare v_sk uuid; a uuid; b uuid; c uuid; v_enrol uuid;
begin
  perform t.logout();
  select id into v_sk from public.skills where code = 'NST.FR.3';
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');

  a := app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.assert(a is not null, 'F0. the path attaches something with no enrolment at all');

  insert into public.student_course_enrollments (student_id, course_id, family_id, status, created_by)
  values ('44444444-4444-4444-8444-00000000000d','dddddddd-0000-4000-8000-0000000000fe',
          '22222222-2222-4222-8222-00000000000a','active',
          '11111111-1111-4111-8111-000000000001')
  returning id into v_enrol;

  b := app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.assert_eq(b, 'dddddddd-0000-4000-8000-000000000003'::uuid,
    'F1. an ACTIVE enrolment gets enrolled-curriculum priority in the path');
  perform t.assert_eq(b, (app.learning_activity_select_resource(
      '44444444-4444-4444-8444-00000000000d', v_sk)->>'resource_id')::uuid,
    'F1b. and the path and the activity engine now agree on the same row');

  -- The family finished the book in May.
  update public.student_course_enrollments set status = 'completed' where id = v_enrol;
  c := app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk);
  perform t.assert_eq(c, a,
    'F2. a finished enrolment does NOT get priority - it is a fact about last year');
  perform t.assert(c is distinct from b,
    'F2b. which is a different answer from the one an active enrolment gives');

  update public.student_course_enrollments set status = 'dropped' where id = v_enrol;
  perform t.assert_eq(app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk), a,
    'F2c. nor does a dropped one');
  update public.student_course_enrollments set status = 'paused' where id = v_enrol;
  perform t.assert_eq(app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk), a,
    'F2d. nor a paused one');

  update public.student_course_enrollments set status = 'active' where id = v_enrol;
  perform t.assert_eq(app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk),
    app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk),
    'F3. and the answer is the same every time it is asked');
  perform t.assert_eq(app.path_resource_for('44444444-4444-4444-8444-00000000000d', v_sk), b,
    'F3b. reactivating restores the enrolled answer exactly');
end $$;
rollback;

begin;
do $$
declare v_before text; v_after text; v_enrol uuid; v_path uuid; v_snap text;
        v_approved text; v_v2 text;
begin
  perform t.logout();
  perform t.p8_confirm('NST.FR.3', '11111111-1111-4111-8111-000000000001');
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.1','developing','supported',
                     '11111111-1111-4111-8111-000000000001');
  perform t.p8_state('44444444-4444-4444-8444-00000000000d','NST.FR.2','developing','supported',
                     '11111111-1111-4111-8111-000000000001');

  -- F4. Which skills reach the path, and in what order, has nothing to do with
  -- enrolment: path_resource_for runs after the candidates are chosen.
  select string_agg(c.code || '/' || c.reason_code, ',' order by c.reason_rank, c.code)
    into v_before from app.path_candidates('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.1')) c;

  insert into public.student_course_enrollments (student_id, course_id, family_id, status, created_by)
  values ('44444444-4444-4444-8444-00000000000d','dddddddd-0000-4000-8000-0000000000fe',
          '22222222-2222-4222-8222-00000000000a','active',
          '11111111-1111-4111-8111-000000000001')
  returning id into v_enrol;

  select string_agg(c.code || '/' || c.reason_code, ',' order by c.reason_rank, c.code)
    into v_after from app.path_candidates('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.1')) c;
  perform t.assert_eq(v_after, v_before,
    'F4. candidate skill routing is untouched by enrolment, active or otherwise');

  update public.student_course_enrollments set status = 'completed' where id = v_enrol;
  select string_agg(c.code || '/' || c.reason_code, ',' order by c.reason_rank, c.code)
    into v_after from app.path_candidates('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.1')) c;
  perform t.assert_eq(v_after, v_before, 'F4b. and by the enrolment ending');

  -- F5. Versioning and what a parent approved.
  update public.student_course_enrollments set status = 'active' where id = v_enrol;
  v_path := t.p8_path('44444444-4444-4444-8444-00000000000d','NST.FR.1',
                      '11111111-1111-4111-8111-000000000001');
  perform t.login('11111111-1111-4111-8111-000000000001');
  perform public.approve_learning_path(v_path, 'P8 yes');
  perform t.logout();
  select string_agg(n.skill_id::text || ':' || n.position || ':' || coalesce(n.resource_id::text,'-'),
                    ',' order by n.position)
    into v_approved from public.learning_path_nodes n where n.path_id = v_path;

  -- The enrolment ends. Her approved path does not move.
  update public.student_course_enrollments set status = 'completed' where id = v_enrol;
  select string_agg(n.skill_id::text || ':' || n.position || ':' || coalesce(n.resource_id::text,'-'),
                    ',' order by n.position)
    into v_snap from public.learning_path_nodes n where n.path_id = v_path;
  perform t.assert_eq(v_snap, v_approved,
    'F5. the path a parent approved is exactly as she approved it, enrolment or no enrolment');
  perform t.assert_eq((select status::text from public.learning_paths where id = v_path),
    'approved', 'F5b. and it is still the approved version');

  -- F6. Standards, grade and age still decide nothing about a path.
  update public.students set grade_level = '1', date_of_birth = date '2004-01-01'
   where id = '44444444-4444-4444-8444-00000000000d';
  select string_agg(c.code || '/' || c.reason_code, ',' order by c.reason_rank, c.code)
    into v_after from app.path_candidates('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.1')) c;
  perform t.assert_eq(v_after, v_before, 'F6. grade and age still decide nothing about a path');

  alter table public.standards rename to standards_hidden_f6;
  select string_agg(c.code || '/' || c.reason_code, ',' order by c.reason_rank, c.code)
    into v_after from app.path_candidates('44444444-4444-4444-8444-00000000000d',
      (select id from public.skills where code = 'NST.FR.1')) c;
  perform t.assert_eq(v_after, v_before,
    'F6b. and the path still runs with the standards catalogue renamed away');
  alter table public.standards_hidden_f6 rename to standards;
end $$;
rollback;

begin;
do $$
begin
  perform t.logout();
  -- The alignment itself is guarded: a selector that prefers enrolment without
  -- requiring it to be active puts the two answers back out of step, silently.
  execute $x$
    create or replace function app.path_resource_for(p_student uuid, p_skill uuid)
    returns uuid language sql stable security invoker set search_path = '' as $body$
      select r.id from public.resource_skills rs
        join public.learning_resources r on r.id = rs.resource_id
       where rs.confirmed
       order by case when exists (select 1 from public.student_course_enrollments e
                                   where e.student_id = p_student) then 0 else 1 end,
                r.id
       limit 1;
    $body$;
  $x$;
  begin
    perform app.assert_schema_invariants();
    perform t.assert(false, 'F7. the invariants accepted two different definitions of enrolment');
  exception when others then
    perform t.assert(sqlerrm like '%not the curriculum they are using%',
      'F7. a selector that prefers a finished enrolment is refused');
  end;
end $$;
rollback;
