-- =============================================================================
-- 0120  The replan engine: consumes the profile, never computes it
-- =============================================================================
-- Same graph, same profile, same evidence, same approved path, same rule
-- version produces the same answer - the same guarantee app.path_candidates
-- already gives, because this reads that function rather than re-deriving
-- anything it already decided. Nothing here calls a model, and nowhere here
-- could one be reached.
--
-- THE PROFILE-FIRST RULE. If evidence legitimately changed what Nestra
-- believes about a child, that change already happened - through
-- recompute_student_skill, through set_skill_state_override, through
-- confirm_skill_evidence - before anything in this file is ever called. This
-- file reads app.path_skill_context, app.path_candidates and
-- app.path_human_confirmed_secure, exactly as the path engine itself does; it
-- does not read student_skills directly and it computes no state of its own.
-- 0121 checks this by name.
-- =============================================================================

create or replace function app.replan_rule_version()
returns text language sql immutable set search_path = '' as $fn$
  select '2026-10-01.1'::text;
$fn$;

-- =============================================================================
-- Same-skill: computed fresh, every time, never stored
-- =============================================================================
-- The exact philosophy app.refresh_advisory already established: a
-- suggestion that can drift out of agreement with the candidates that
-- produced it is worse than no suggestion. This is read-only, touches no
-- table, and is the whole of what Phase 3 does for wants_more, for a resource
-- going unavailable, for an ended enrollment, and for "something different"
-- once it has already been approved - all four of those stay on the same
-- skill by construction, so none of them is a path question at all.
--
-- A requested modality is read only when the CALLER asks for one. Nothing
-- here infers a preference from what she chose last time, and nothing
-- persists a "learning style" anywhere - app.learning_activity_candidates
-- itself carries that same rule forward from Phase 1.

create or replace function app.same_skill_recommendation(
  p_student          uuid,
  p_skill            uuid,
  p_current_resource uuid default null,
  p_requested_modality app.learning_activity_modality default null)
returns jsonb language sql stable security invoker set search_path = '' as $fn$
  with alts as (
    select c.* from app.learning_activity_candidates(p_student, p_skill, null, p_requested_modality) c
     where p_current_resource is null or c.resource_id <> p_current_resource
  )
  select jsonb_build_object(
    'outcome', case
        when p_requested_modality is not null
             and exists (select 1 from alts where modality_matched) then 'offer_alternative_modality'
        when exists (select 1 from alts) then 'offer_alternative_resource'
        else 'continue_current_skill' end,
    'skill_id', p_skill,
    'requested_modality', p_requested_modality,
    'alternatives', coalesce((select jsonb_agg(jsonb_build_object(
        'resource_id', a.resource_id, 'title', a.title, 'kind', a.kind_text,
        'from_active_curriculum', a.from_active_curriculum,
        'modality_matched', a.modality_matched, 'rank', a.rank) order by a.rank)
       from alts a), '[]'::jsonb),
    'skill_unchanged', true,
    'evidence_created', false, 'skill_state_changed', false, 'mastery_implied', false);
$fn$;

comment on function app.same_skill_recommendation(uuid, uuid, uuid, app.learning_activity_modality) is
  'What else already-confirmed material exists for the same skill. Computed '
  'on demand like the refresh advisory, never stored, and never a claim about '
  'how this child learns - only ever about what this family already has.';

-- =============================================================================
-- Path-level: which live path, if any, a skill belongs to
-- =============================================================================
-- Prefers the path that already has the skill as a node; otherwise the live
-- path whose branch contains it. Deterministic tie-break on version, the same
-- as everywhere else in this engine.

create or replace function app.find_live_path_for_skill(p_student uuid, p_skill uuid)
returns public.learning_paths
language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select lp.* into v
    from public.learning_paths lp
    join public.learning_path_nodes n on n.path_id = lp.id
   where lp.student_id = p_student and lp.status in ('approved', 'paused')
     and n.skill_id = p_skill and n.status <> 'removed'
   order by lp.version desc
   limit 1;
  if found then
    return v;
  end if;

  for v in
    select lp.* from public.learning_paths lp
     where lp.student_id = p_student and lp.status in ('approved', 'paused')
     order by lp.version desc
  loop
    if exists (select 1 from app.path_branch(v.branch_root_skill_id) b where b.skill_id = p_skill) then
      return v;
    end if;
  end loop;

  return null;
end $fn$;

comment on function app.find_live_path_for_skill(uuid, uuid) is
  'The one approved or paused path, if any, this skill belongs to. Null means '
  'there is nothing currently live to replan against - a legitimate answer, '
  'not an error.';

-- =============================================================================
-- Path-level classification
-- =============================================================================
-- Diffs what the engine would propose now against what is already approved,
-- using only facts app.path_candidates and app.learning_path_nodes already
-- produced. This NEVER reads student_skills, student_skill_events or
-- student_skill_overrides directly, and 0121 checks that by name: the profile
-- was already consulted, upstream, by the engine this reads from.

create or replace function app.classify_replan_outcome(
  p_trigger_reason  app.replan_trigger_reason,
  p_skill           uuid,
  p_old_actionable  uuid[],
  p_new_actionable  uuid[],
  p_new_path        uuid)
returns app.replan_outcome
language plpgsql stable security invoker set search_path = '' as $fn$
declare
  v_added   uuid[];
  v_removed uuid[];
  v_all_prereq_support boolean;
begin
  select coalesce(array_agg(s), '{}') into v_added
    from unnest(p_new_actionable) s where s <> all(p_old_actionable);
  select coalesce(array_agg(s), '{}') into v_removed
    from unnest(p_old_actionable) s where s <> all(p_new_actionable);

  -- A confirmed revisit bringing its own skill back is named for what it is,
  -- regardless of where that skill happens to sit in the graph.
  if p_trigger_reason = 'approved_revisit'
     and p_skill = any(p_new_actionable) and not (p_skill = any(p_old_actionable)) then
    return 'revisit_later';
  end if;

  if coalesce(array_length(v_added, 1), 0) = 0 and coalesce(array_length(v_removed, 1), 0) = 0 then
    return 'refresh_current_path';
  end if;

  if coalesce(array_length(v_removed, 1), 0) = 0 and coalesce(array_length(v_added, 1), 0) > 0 then
    select coalesce(bool_and(n.reason_code = 'prerequisite_support'), false) into v_all_prereq_support
      from public.learning_path_nodes n
     where n.path_id = p_new_path and n.skill_id = any(v_added) and n.node_kind = 'actionable';
    if v_all_prereq_support then
      return 'return_to_prerequisite';
    else
      return 'advance_to_connected_skill';
    end if;
  end if;

  -- Anything else - a removal, or a mix this engine is not confident reading
  -- as one direction - is handed to a person rather than guessed at.
  return 'await_human_review';
end $fn$;

comment on function app.classify_replan_outcome(app.replan_trigger_reason, uuid, uuid[], uuid[], uuid) is
  'Classifies a diff the path engine already computed into one of the '
  'planning-decision outcomes. Reads reason_code off the new path''s own '
  'nodes; never reads a skill''s state directly.';

revoke all on function app.replan_rule_version() from public, anon;
revoke all on function app.same_skill_recommendation(uuid, uuid, uuid, app.learning_activity_modality) from public, anon;
revoke all on function app.find_live_path_for_skill(uuid, uuid) from public, anon;
revoke all on function app.classify_replan_outcome(app.replan_trigger_reason, uuid, uuid[], uuid[], uuid) from public, anon;

grant execute on function app.replan_rule_version() to authenticated, service_role;
grant execute on function app.same_skill_recommendation(uuid, uuid, uuid, app.learning_activity_modality) to authenticated, service_role;
grant execute on function app.find_live_path_for_skill(uuid, uuid) to authenticated, service_role;
grant execute on function app.classify_replan_outcome(app.replan_trigger_reason, uuid, uuid[], uuid[], uuid) to authenticated, service_role;
