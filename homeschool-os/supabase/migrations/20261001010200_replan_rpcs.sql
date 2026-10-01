-- =============================================================================
-- 0121  Replan RPCs - an explainable recommendation, never a hidden mutation
-- =============================================================================
-- Two public entry points carry all of Phase 3's behaviour:
--
--   suggest_same_skill_alternative   same-skill, read-only, for wants_more
--                                     and modality switching
--   request_replan_evaluation        the eight legitimate triggers, which
--                                     branches internally into the same
--                                     read-only path above, or into a real
--                                     path-level regeneration attempt
--
-- NEITHER FUSES WITH THE ACTION THAT MADE IT LEGITIMATE. Accepting evidence,
-- confirming a skill secure, confirming a revisit and approving a child's
-- change request are all unchanged, deployed, STEP 7 / STEP 8 functions - none
-- of them is edited here, and none of them is taught to call into this file.
-- A caller chains the two calls explicitly, the same way this codebase has
-- always chained confirm_skill_evidence and recompute_student_skill as two
-- separate steps rather than fusing them. That is not a missing integration;
-- it is the same profile-first discipline the rest of STEP 7 already uses,
-- applied one step further down the chain.
-- =============================================================================

create or replace function public.suggest_same_skill_alternative(
  p_activity uuid,
  p_requested_modality app.learning_activity_modality default null)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_activities;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  return app.same_skill_recommendation(v.student_id, v.skill_id, v.resource_id, p_requested_modality)
         || jsonb_build_object('activity_id', p_activity, 'rule_version', app.replan_rule_version());
end $fn$;

comment on function public.suggest_same_skill_alternative(uuid, app.learning_activity_modality) is
  'Child-facing: what else already-confirmed exists for the skill this '
  'activity is already for. Read-only - the point of wants_more, a resource '
  'going unavailable, or an approved "something different" is that none of '
  'them is a reason to touch the path.';

-- =============================================================================
-- The eight triggers
-- =============================================================================

create or replace function public.request_replan_evaluation(
  p_student           uuid,
  p_trigger_reason    app.replan_trigger_reason,
  p_skill             uuid,
  p_trigger_record_id uuid default null,
  p_note              text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_path             public.learning_paths;
  v_pending_id       uuid;
  v_old_actionable   uuid[];
  v_candidate_set    uuid[];
  v_regen_reason     app.path_regeneration_reason;
  v_result           jsonb;
  v_new_path_id      uuid;
  v_new_actionable   uuid[];
  v_outcome          app.replan_outcome;
  v_id               uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(p_student, 'learning_plan', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  -- =========================================================================
  -- SAME-SKILL. Resource going unavailable, an enrollment ending, and a
  -- child's already-approved request to change activities all stay on the
  -- SAME skill by construction - Scenario B and the architecture behind it
  -- both say so - so nothing here ever reaches the path.
  -- =========================================================================
  if p_trigger_reason in ('resource_unavailable', 'child_change_request_approved',
                          'active_enrollment_changed') then
    return app.same_skill_recommendation(p_student, p_skill, null, null)
           || jsonb_build_object(
                'trigger_reason', p_trigger_reason, 'trigger_record_id', p_trigger_record_id,
                'requires_review', false, 'rule_version', app.replan_rule_version(),
                'note', 'This stays on the same skill - nothing about the plan changed.');
  end if;

  -- =========================================================================
  -- PATH-LEVEL. A direction-capable change, and the same capability
  -- regenerate_learning_path has always required: a child may run her own
  -- morning and ask for something different, and still never hold this.
  -- =========================================================================
  if not app.can_student_action(p_student, 'learning_plan', 'create') then
    raise exception 'a replan that could change what your child is asked to do next is not this account''s decision to make'
      using errcode = 'insufficient_privilege';
  end if;

  v_path := app.find_live_path_for_skill(p_student, p_skill);
  if v_path.id is null then
    return jsonb_build_object(
      'outcome', 'no_change', 'trigger_reason', p_trigger_reason, 'trigger_record_id', p_trigger_record_id,
      'requires_review', false, 'rule_version', app.replan_rule_version(),
      'note', 'Nothing is currently approved for this branch, so there is no plan to reconsider.');
  end if;

  -- IDEMPOTENCE. Reopening Today, or the same canonical signal firing twice,
  -- must not pile up proposals - it hands back the one already waiting.
  select r.id into v_pending_id
    from public.learning_path_replan_recommendations r
    join public.learning_paths lp on lp.id = r.resulting_path_id
   where r.student_id = p_student
     and r.branch_root_skill_id = v_path.branch_root_skill_id
     and lp.status = 'proposed'
   order by r.created_at desc
   limit 1;
  if v_pending_id is not null then
    return public.explain_replan_recommendation(v_pending_id) || jsonb_build_object('already_pending', true);
  end if;

  select coalesce(array_agg(n.skill_id order by n.position), '{}') into v_old_actionable
    from public.learning_path_nodes n
   where n.path_id = v_path.id and n.status <> 'removed' and n.node_kind = 'actionable';

  select coalesce(array_agg(x.skill_id), '{}') into v_candidate_set
    from (
      select c.skill_id from app.path_candidates(p_student, v_path.branch_root_skill_id) c
       order by c.reason_rank, c.depth, c.code
       limit v_path.node_horizon
    ) x;

  -- THE CHEAP CHECK. If what the engine would propose today is exactly what
  -- is already approved, there is nothing to regenerate and nothing to
  -- record - the honest answer is no_change, and a proposed version that
  -- would read identically to the one already live is never created.
  if (select coalesce(array_agg(s order by s), '{}') from unnest(v_candidate_set) s)
     = (select coalesce(array_agg(s order by s), '{}') from unnest(v_old_actionable) s) then
    return jsonb_build_object(
      'outcome', 'no_change', 'trigger_reason', p_trigger_reason, 'trigger_record_id', p_trigger_record_id,
      'requires_review', false, 'rule_version', app.replan_rule_version(), 'prior_path_id', v_path.id,
      'note', 'What the evidence now supports is exactly what the approved plan already has next.');
  end if;

  v_regen_reason := case p_trigger_reason
    when 'confirmed_evidence_changed_profile' then 'new_confirmed_evidence'
    when 'human_confirmed_secure'             then 'new_confirmed_evidence'
    when 'parent_goal_changed'                then 'goals_changed'
    when 'approved_revisit'                   then 'refresh_advisory'
    when 'diagnostic_frontier_changed'        then 'diagnostic_completed'
  end::app.path_regeneration_reason;

  -- THE ONLY PATH TO AN ACTUAL PROPOSAL, and it is the one that already
  -- existed: regenerate_learning_path, called here rather than reimplemented.
  -- It creates a new PROPOSED version and leaves the approved one exactly as
  -- it was - the old approved direction remains active until a person calls
  -- approve_learning_path, same as it always has.
  v_result := public.regenerate_learning_path(v_path.id, v_regen_reason, p_note, null);
  v_new_path_id := (v_result ->> 'path')::uuid;

  select coalesce(array_agg(n.skill_id order by n.position), '{}') into v_new_actionable
    from public.learning_path_nodes n
   where n.path_id = v_new_path_id and n.status <> 'removed' and n.node_kind = 'actionable';

  v_outcome := app.classify_replan_outcome(
    p_trigger_reason, p_skill, v_old_actionable, v_new_actionable, v_new_path_id);

  insert into public.learning_path_replan_recommendations (
      student_id, skill_id, branch_root_skill_id, trigger_reason, trigger_record_id,
      outcome, requires_review, prior_path_id, resulting_path_id,
      skill_states_consulted, explanation, rule_version, created_by)
  values (
      p_student, p_skill, v_path.branch_root_skill_id, p_trigger_reason, p_trigger_record_id,
      v_outcome, true, v_path.id, v_new_path_id,
      (select coalesce(jsonb_agg(app.path_skill_context(p_student, s)), '[]'::jsonb)
         from unnest(v_old_actionable || v_new_actionable) s),
      jsonb_build_object(
        'trigger_reason', p_trigger_reason, 'skill_id', p_skill,
        'prior_actionable', to_jsonb(v_old_actionable), 'new_actionable', to_jsonb(v_new_actionable)),
      app.replan_rule_version(), auth.uid())
  returning id into v_id;

  return public.explain_replan_recommendation(v_id);
end $fn$;

comment on function public.request_replan_evaluation(
  uuid, app.replan_trigger_reason, uuid, uuid, text) is
  'The one entry point for all eight legitimate replan triggers. Three of '
  'them never leave the current skill; the other five may call '
  'regenerate_learning_path, which only ever produces a new PROPOSED version '
  '- the live plan does not move until a person approves it.';

-- =============================================================================
-- "Why did Nestra suggest this?"
-- =============================================================================

create or replace function app.replan_note(
  p_reason app.replan_trigger_reason, p_outcome app.replan_outcome)
returns text language sql immutable set search_path = '' as $fn$
  select (case p_reason
    when 'confirmed_evidence_changed_profile' then 'New learning evidence was confirmed.'
    when 'human_confirmed_secure'             then 'A person confirmed this skill as secure.'
    when 'parent_goal_changed'                then 'A goal was set or changed.'
    when 'approved_revisit'                   then 'You asked to revisit this skill.'
    when 'resource_unavailable'               then 'The resource you were using is no longer available.'
    when 'child_change_request_approved'      then 'You asked for something different, and an adult approved the change.'
    when 'active_enrollment_changed'          then 'What this family is enrolled in changed.'
    when 'diagnostic_frontier_changed'        then 'A diagnostic session finished near here.'
  end) || ' ' || (case p_outcome
    when 'no_change'                  then 'The current plan still fits.'
    when 'continue_current_skill'     then 'This skill is still part of the approved learning path.'
    when 'offer_alternative_resource' then 'Here is another confirmed option for the same skill.'
    when 'offer_alternative_modality' then 'Here is a different way to work on the same skill.'
    when 'revisit_later'              then 'This skill is back under consideration.'
    when 'refresh_current_path'       then 'The plan has been refreshed to reflect this.'
    when 'advance_to_connected_skill' then 'A connected skill may now be worth exploring.'
    when 'return_to_prerequisite'     then 'Something this skill builds on may need attention first.'
    when 'await_human_review'         then 'This needs a person to look at it before anything changes.'
  end);
$fn$;

comment on function app.replan_note(app.replan_trigger_reason, app.replan_outcome) is
  'A fixed sentence per structured code, never generated prose and never the '
  'source of truth. There is no sentence here that says a child failed, is '
  'behind, or should already know something - 0121''s own invariant check '
  'refuses one that does.';

create or replace function public.explain_replan_recommendation(p_recommendation uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare r public.learning_path_replan_recommendations; v_path_status text;
begin
  select * into r from public.learning_path_replan_recommendations x where x.id = p_recommendation;
  if not found or not app.can_student_action(r.student_id, 'learning_plan', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  select lp.status::text into v_path_status
    from public.learning_paths lp where lp.id = r.resulting_path_id;

  return jsonb_build_object(
    'recommendation_id', r.id, 'student_id', r.student_id, 'skill_id', r.skill_id,
    'branch_root_skill_id', r.branch_root_skill_id,
    'trigger_reason', r.trigger_reason, 'trigger_record_id', r.trigger_record_id,
    'outcome', r.outcome, 'requires_review', r.requires_review,
    'prior_path_id', r.prior_path_id, 'resulting_path_id', r.resulting_path_id,
    -- Read live off the path itself, never copied: a copy is a value that can
    -- disagree with the row it was copied from.
    'resulting_path_status', case v_path_status
        when 'proposed' then 'pending'
        when 'approved' then 'approved'
        when 'rejected' then 'declined'
        when 'archived' then 'superseded'
        else v_path_status end,
    'explanation', r.explanation, 'rule_version', r.rule_version,
    'created_at', r.created_at, 'created_by', r.created_by,
    'evidence_created', false, 'skill_state_changed', false,
    'note', app.replan_note(r.trigger_reason, r.outcome));
end $fn$;

comment on function public.explain_replan_recommendation(uuid) is
  'Why did Nestra suggest this? Everything here is a structured field or a '
  'fixed sentence keyed to one; nothing is generated and nothing claims more '
  'than the record actually supports.';

revoke all on function public.suggest_same_skill_alternative(uuid, app.learning_activity_modality) from public, anon;
revoke all on function public.request_replan_evaluation(uuid, app.replan_trigger_reason, uuid, uuid, text) from public, anon;
revoke all on function app.replan_note(app.replan_trigger_reason, app.replan_outcome) from public, anon;
revoke all on function public.explain_replan_recommendation(uuid) from public, anon;

grant execute on function public.suggest_same_skill_alternative(uuid, app.learning_activity_modality) to authenticated, service_role;
grant execute on function public.request_replan_evaluation(uuid, app.replan_trigger_reason, uuid, uuid, text) to authenticated, service_role;
grant execute on function app.replan_note(app.replan_trigger_reason, app.replan_outcome) to authenticated, service_role;
grant execute on function public.explain_replan_recommendation(uuid) to authenticated, service_role;
