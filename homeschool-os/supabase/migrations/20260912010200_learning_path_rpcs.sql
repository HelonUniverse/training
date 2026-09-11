-- =============================================================================
-- 0100  The calls a family makes, and the ones Nestra is not allowed to make
-- =============================================================================
-- Every function here either proposes something or records that a person
-- decided something. None of them writes to a child's profile. `generate`
-- proposes, `approve` records a yes, `reject` records a no, and `complete`
-- records that a node was worked through - which is NOT the same as saying the
-- child has learned it, and is deliberately not written anywhere near
-- student_skill_events.
--
-- THE REGENERATION RULE. An approved path is never rewritten. Regenerating
-- produces a NEW version, proposed, sitting beside the approved one until a
-- person chooses. And it reads what she did to the last version first: a skill
-- she removed does not quietly come back, and a skill she added herself is
-- carried forward. A suggestion engine that forgets a parent's decisions every
-- time it runs is one she stops using.
--
-- THE REORDER RULE. She may put a skill anywhere. If she puts one before
-- something it usually builds on, Nestra neither refuses nor pretends the orders
-- are equivalent: the move happens, and it comes back with a warning naming the
-- skill. She is the one who knows her child.
-- =============================================================================

-- --- what Nestra would say about putting this skill here ---------------------

create or replace function app.path_order_warnings(
  p_path uuid, p_student uuid, p_skill uuid, p_position integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare r record; v jsonb := '[]'::jsonb;
begin
  for r in
    select k.id, k.code, k.name,
           (select n.position from public.learning_path_nodes n
             where n.path_id = p_path and n.skill_id = k.id and n.status <> 'removed') as at
      from public.skill_prerequisites sp
      join public.skills k on k.id = sp.prerequisite_skill_id
     where sp.skill_id = p_skill and k.active
     order by k.code
  loop
    -- Only worth saying when the prerequisite is not already something Nestra
    -- can speak about. A parent moving a skill above one her child has already
    -- shown her does not need to be told about it.
    if not app.path_well_characterized(p_student, r.id)
       and (r.at is null or r.at >= p_position) then
      v := v || jsonb_build_object(
        'code', 'prerequisite_usually_comes_first',
        'skill_id', r.id, 'skill_code', r.code, 'skill_name', r.name,
        'on_this_path_at', r.at);
    end if;
  end loop;

  if app.path_human_confirmed_secure(p_student, p_skill) then
    v := v || jsonb_build_object('code', 'already_confirmed_by_a_person',
                                 'skill_id', p_skill);
  end if;
  if app.path_resource_for(p_student, p_skill) is null then
    v := v || jsonb_build_object('code', 'no_resource_available_yet',
                                 'skill_id', p_skill);
  end if;
  return v;
end $fn$;

-- =============================================================================
-- Generate
-- =============================================================================

create or replace function public.generate_learning_path(
  p_student uuid,
  p_root uuid,
  p_horizon integer default 4,
  p_context text default null,
  p_supersedes uuid default null,
  p_reason app.path_regeneration_reason default null,
  p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_path uuid; v_org uuid; v_family uuid; v_version int := 1;
  v_old public.learning_paths;
  v_removed uuid[] := '{}';
  v_skills uuid[] := '{}';
  v_reasons text[] := '{}';
  v_supports uuid[] := '{}';          -- the skill each entry exists to support
  v_taken uuid[] := '{}';
  v_sup uuid; v_unmet uuid[]; v_person_named boolean; r record; i int; v_id uuid; v_ready jsonb; v_res uuid;
  v_ids uuid[] := '{}';
  v_inputs jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(p_student, 'learning_plan', 'create') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if p_horizon < 3 or p_horizon > 5 then
    raise exception 'a path proposes between 3 and 5 skills; % was asked for', p_horizon
      using errcode = 'check_violation';
  end if;

  select st.primary_organization_id, st.family_id into v_org, v_family
    from public.students st where st.id = p_student;

  -- What she already decided about the version this one replaces. Read BEFORE
  -- anything is generated, because these decisions outrank the engine.
  if p_supersedes is not null then
    select * into v_old from public.learning_paths lp where lp.id = p_supersedes;
    if not found or v_old.student_id <> p_student then
      raise exception 'no such path' using errcode = 'insufficient_privilege';
    end if;
    v_version := v_old.version + 1;

    select coalesce(array_agg(distinct n.skill_id), '{}') into v_removed
      from public.learning_path_nodes n
     where n.path_id = p_supersedes and n.status = 'removed';

    -- Skills she put there herself keep their place at the front.
    for r in select n.skill_id, n.position from public.learning_path_nodes n
              where n.path_id = p_supersedes and n.added_by_human
                and n.status <> 'removed'
              order by n.position
    loop
      v_skills := v_skills || r.skill_id;
      v_reasons := v_reasons || 'human_added'::text;
      v_supports := v_supports || null::uuid;
      v_taken := v_taken || r.skill_id;
    end loop;
  end if;

  -- The candidates, in the engine's order, minus anything she took out.
  for r in select * from app.path_candidates(p_student, p_root) loop
    exit when array_length(v_skills, 1) >= p_horizon;
    continue when r.skill_id = any(v_taken);
    continue when r.skill_id = any(v_removed);

    -- REACHABILITY, and it is the rule that stops the path jumping. A candidate
    -- whose direct prerequisites Nestra knows nothing about is not a reasonable
    -- next step, however good a resource happens to be attached to it: the first
    -- smoke test produced a path that opened at "compare fractions" for a child
    -- with no fraction evidence at all, purely because that skill had a demo
    -- worksheet.
    --
    -- One unmet prerequisite may be carried by ONE support node. Two or more is
    -- a staircase, and a staircase is what this rule exists to prevent - so the
    -- candidate is skipped and a later path, with more known, can reach it.
    v_unmet := app.path_unmet_prerequisites(p_student, p_root, r.skill_id, v_taken);

    -- REACHABILITY, and who it applies to. The rule exists to stop NESTRA
    -- jumping: the first smoke test produced a path opening at "compare
    -- fractions" for a child with no fraction evidence, purely because that
    -- skill had a demo worksheet attached. So a skill Nestra chose is skipped
    -- when its prerequisites are not something we can speak to.
    --
    -- It does NOT apply to a skill a person named. A parent who says "this term
    -- we are working on comparing fractions" is not making a claim about
    -- readiness that Nestra gets to veto; she is telling us what this family is
    -- doing. The path says yes, proposes what support it can, and records in the
    -- readiness reasons that the ground underneath is not characterized. Found
    -- by the test that asks whether a parent's goal survives the engine.
    v_person_named := r.reason_code in ('parent_goal','revisit_requested','active_plan_priority');

    if not v_person_named and coalesce(array_length(v_unmet, 1), 0) >= 2 then
      continue;
    end if;

    if coalesce(array_length(v_unmet, 1), 0) >= 1 then
      v_sup := v_unmet[1];              -- nearest by stable skill code. One. Never two.
      if v_sup <> all(v_removed)
         and coalesce(array_length(v_skills, 1), 0) + 2 <= p_horizon then
        v_skills := v_skills || v_sup;
        v_reasons := v_reasons || 'prerequisite_support'::text;
        v_supports := v_supports || r.skill_id;
        v_taken := v_taken || v_sup;
      elsif not v_person_named then
        continue;                       -- no room to support it; do not strand it
      end if;
    end if;

    v_skills := v_skills || r.skill_id;
    v_reasons := v_reasons || (r.reason_code::text);
    v_supports := v_supports || null::uuid;
    v_taken := v_taken || r.skill_id;
  end loop;

  v_inputs := jsonb_build_object(
    'rule_version', app.learning_path_rule_version(),
    'branch_root', p_root,
    'horizon', p_horizon,
    'named_by_a_person', (select coalesce(jsonb_agg(jsonb_build_object(
         'skill_id', n.skill_id, 'reason', n.reason) order by n.skill_id), '[]'::jsonb)
       from app.path_named_by_a_person(p_student) n),
    'diagnostic_frontier', (select coalesce(jsonb_agg(f.skill_id order by f.skill_id), '[]'::jsonb)
       from app.path_diagnostic_frontier(p_student, p_root) f),
    'branch', (select coalesce(jsonb_agg(jsonb_build_object(
         'skill_id', b.skill_id, 'code', b.code, 'depth', b.depth,
         'context', app.path_skill_context(p_student, b.skill_id),
         'resource_available', app.path_resource_for(p_student, b.skill_id) is not null)
         order by b.depth, b.code), '[]'::jsonb)
       from app.path_branch(p_root) b),
    'carried_forward_from', p_supersedes,
    'excluded_because_a_person_removed_them', to_jsonb(v_removed));

  insert into public.learning_paths (
      student_id, organization_id, family_id, branch_root_skill_id,
      version, supersedes_id, status, rule_version, node_horizon,
      generation_inputs, regeneration_reason, regeneration_note, parent_context,
      record_provenance, created_by, updated_by)
  values (p_student, v_org, v_family, p_root,
          v_version, p_supersedes, 'proposed', app.learning_path_rule_version(), p_horizon,
          v_inputs, p_reason, p_note, p_context,
          'system_computed', auth.uid(), auth.uid())
  returning id into v_path;

  for i in 1..coalesce(array_length(v_skills, 1), 0) loop
    v_ready := app.path_readiness(p_student, v_skills[i]);
    v_res   := app.path_resource_for(p_student, v_skills[i]);
    insert into public.learning_path_nodes (
        path_id, student_id, skill_id, position, reason_code, reason_detail,
        readiness_reasons, prerequisites_considered, evidence_context,
        resource_id, resource_note, status, added_by_human, added_by)
    values (v_path, p_student, v_skills[i], i, v_reasons[i]::app.path_node_reason,
            jsonb_build_object('reason', v_reasons[i],
                               'supports_skill_id', v_supports[i],
                               'rule_version', app.learning_path_rule_version()),
            (select coalesce(array_agg(x::app.path_readiness_reason), '{}')
               from jsonb_array_elements_text(v_ready->'readiness_reasons') t(x)),
            (select coalesce(array_agg(x::uuid), '{}')
               from jsonb_array_elements_text(v_ready->'prerequisites_considered') t(x)),
            v_ready->'evidence_context',
            v_res,
            case when v_res is null then 'no resource is attached to this skill yet' end,
            'proposed',
            v_reasons[i] = 'human_added',
            case when v_reasons[i] = 'human_added' then auth.uid() end)
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  -- A support node points at the node it supports, which is always the next one.
  for i in 1..coalesce(array_length(v_skills, 1), 0) loop
    if v_supports[i] is not null then
      update public.learning_path_nodes n set supports_node_id = (
        select n2.id from public.learning_path_nodes n2
         where n2.path_id = v_path and n2.skill_id = v_supports[i])
       where n.id = v_ids[i];
    end if;
  end loop;

  insert into public.learning_path_events (path_id, student_id, kind, note, actor)
  values (v_path, p_student,
          (case when p_supersedes is null then 'generated' else 'regenerated' end)::app.path_event_kind,
          p_note, auth.uid());

  return public.explain_learning_path(v_path);
end $fn$;

-- =============================================================================
-- What a person decides
-- =============================================================================

create or replace function public.approve_learning_path(p_path uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found then
    raise exception 'no such path' using errcode = 'insufficient_privilege';
  end if;
  -- Approving is `approve`, not `update`. A tutor may help build a path; only a
  -- guardian with full access makes it the plan.
  if not app.can_student_action(v.student_id, 'learning_plan', 'approve') then
    raise exception 'a learning path is a decision about a child, and this account is not authorized to make it for this child'
      using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'proposed' then
    raise exception 'this path is % and is not waiting for a decision', v.status
      using errcode = 'check_violation';
  end if;

  -- The version she approves replaces the one in force; the old one is archived,
  -- never deleted, and stays exactly as she left it.
  update public.learning_paths lp
     set status = 'archived', archived_at = now(), updated_at = now(), updated_by = auth.uid()
   where lp.student_id = v.student_id
     and lp.branch_root_skill_id is not distinct from v.branch_root_skill_id
     and lp.status in ('approved','paused') and lp.id <> p_path;

  update public.learning_paths lp
     set status = 'approved', approved_by = auth.uid(), approved_at = now(),
         updated_at = now(), updated_by = auth.uid()
   where lp.id = p_path;

  update public.learning_path_nodes n set status = 'approved'
   where n.path_id = p_path and n.status = 'proposed';

  insert into public.learning_path_events (path_id, student_id, kind, note, actor)
  values (p_path, v.student_id, 'approved', p_note, auth.uid());

  return public.explain_learning_path(p_path);
end $fn$;

create or replace function public.reject_learning_path(p_path uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'approve') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'proposed' then
    raise exception 'this path is % and is not waiting for a decision', v.status
      using errcode = 'check_violation';
  end if;
  update public.learning_paths lp
     set status = 'rejected', rejected_by = auth.uid(), rejected_at = now(),
         updated_at = now(), updated_by = auth.uid()
   where lp.id = p_path;
  insert into public.learning_path_events (path_id, student_id, kind, note, actor)
  values (p_path, v.student_id, 'rejected', p_note, auth.uid());
  return public.explain_learning_path(p_path);
end $fn$;

create or replace function public.pause_learning_path(p_path uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.learning_paths lp set status = 'paused', paused_at = now(),
         updated_at = now(), updated_by = auth.uid()
   where lp.id = p_path and lp.status = 'approved';
  insert into public.learning_path_events (path_id, student_id, kind, note, actor)
  values (p_path, v.student_id, 'paused', p_note, auth.uid());
  return public.explain_learning_path(p_path);
end $fn$;

create or replace function public.resume_learning_path(p_path uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.learning_paths lp set status = 'approved', paused_at = null,
         updated_at = now(), updated_by = auth.uid()
   where lp.id = p_path and lp.status = 'paused';
  insert into public.learning_path_events (path_id, student_id, kind, note, actor)
  values (p_path, v.student_id, 'resumed', p_note, auth.uid());
  return public.explain_learning_path(p_path);
end $fn$;

create or replace function public.archive_learning_path(p_path uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.learning_paths lp set status = 'archived', archived_at = now(),
         updated_at = now(), updated_by = auth.uid()
   where lp.id = p_path;
  insert into public.learning_path_events (path_id, student_id, kind, note, actor)
  values (p_path, v.student_id, 'archived', p_note, auth.uid());
  return public.explain_learning_path(p_path);
end $fn$;

-- =============================================================================
-- What a person changes
-- =============================================================================

create or replace function public.add_path_node(
  p_path uuid, p_skill uuid, p_position integer default null, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths; v_pos int; v_warn jsonb; v_ready jsonb; v_id uuid; v_res uuid;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if v.status in ('archived','rejected') then
    raise exception 'this path is % and is not being worked on', v.status
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.learning_path_nodes n
              where n.path_id = p_path and n.skill_id = p_skill and n.status <> 'removed') then
    raise exception 'that skill is already on this path' using errcode = 'check_violation';
  end if;

  select coalesce(max(n.position), 0) + 1 into v_pos
    from public.learning_path_nodes n where n.path_id = p_path;
  v_pos := least(coalesce(p_position, v_pos), v_pos);

  update public.learning_path_nodes n set position = n.position + 1
   where n.path_id = p_path and n.position >= v_pos;

  v_warn  := app.path_order_warnings(p_path, v.student_id, p_skill, v_pos);
  v_ready := app.path_readiness(v.student_id, p_skill);
  v_res   := app.path_resource_for(v.student_id, p_skill);

  insert into public.learning_path_nodes (
      path_id, student_id, skill_id, position, reason_code, reason_detail,
      readiness_reasons, prerequisites_considered, evidence_context,
      resource_id, resource_note, status, added_by_human, added_by)
  values (p_path, v.student_id, p_skill, v_pos, 'human_added',
          jsonb_build_object('reason', 'human_added', 'note', p_note),
          (select coalesce(array_agg(x::app.path_readiness_reason), '{}')
             from jsonb_array_elements_text(v_ready->'readiness_reasons') t(x)),
          (select coalesce(array_agg(x::uuid), '{}')
             from jsonb_array_elements_text(v_ready->'prerequisites_considered') t(x)),
          v_ready->'evidence_context', v_res,
          case when v_res is null then 'no resource is attached to this skill yet' end,
          (case when v.status = 'proposed' then 'proposed' else 'approved' end)::app.path_node_status,
          true, auth.uid())
  returning id into v_id;

  insert into public.learning_path_events (
      path_id, student_id, kind, node_id, skill_id, to_position, note, warnings, actor)
  values (p_path, v.student_id, 'node_added', v_id, p_skill, v_pos, p_note, v_warn, auth.uid());

  return jsonb_build_object('node', v_id, 'position', v_pos, 'warnings', v_warn,
                            'path', public.explain_learning_path(p_path));
end $fn$;

create or replace function public.remove_path_node(p_node uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_path_nodes;
begin
  select * into v from public.learning_path_nodes n where n.id = p_node;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.learning_path_nodes n
     set status = 'removed', removed_by = auth.uid(), removed_at = now()
   where n.id = p_node;
  insert into public.learning_path_events (
      path_id, student_id, kind, node_id, skill_id, from_position, note, actor)
  values (v.path_id, v.student_id, 'node_removed', p_node, v.skill_id, v.position,
          p_note, auth.uid());
  return jsonb_build_object('node', p_node, 'status', 'removed',
                            'path', public.explain_learning_path(v.path_id));
end $fn$;

/**
 * Move a node, and say what that means.
 *
 * The move always happens. A parent knows things about her child that no
 * prerequisite graph does, and a product that refuses her is a product that is
 * wrong about who is in charge. What it does instead is tell her what it knows -
 * "this usually builds on X" - and leave the decision where it belongs.
 */
create or replace function public.reorder_path_node(
  p_node uuid, p_to_position integer, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_path_nodes; v_from int; v_max int; v_to int; v_warn jsonb;
begin
  select * into v from public.learning_path_nodes n where n.id = p_node;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  v_from := v.position;
  select count(*) into v_max from public.learning_path_nodes n
   where n.path_id = v.path_id and n.status <> 'removed';
  v_to := greatest(1, least(p_to_position, v_max));

  if v_to <> v_from then
    if v_to < v_from then
      update public.learning_path_nodes n set position = n.position + 1
       where n.path_id = v.path_id and n.position >= v_to and n.position < v_from;
    else
      update public.learning_path_nodes n set position = n.position - 1
       where n.path_id = v.path_id and n.position > v_from and n.position <= v_to;
    end if;
    update public.learning_path_nodes n set position = v_to where n.id = p_node;
  end if;

  v_warn := app.path_order_warnings(v.path_id, v.student_id, v.skill_id, v_to);

  insert into public.learning_path_events (
      path_id, student_id, kind, node_id, skill_id, from_position, to_position,
      note, warnings, actor)
  values (v.path_id, v.student_id, 'node_reordered', p_node, v.skill_id, v_from, v_to,
          p_note, v_warn, auth.uid());

  return jsonb_build_object('node', p_node, 'from', v_from, 'to', v_to,
                            'warnings', v_warn,
                            'path', public.explain_learning_path(v.path_id));
end $fn$;

/**
 * Mark a node worked through.
 *
 * This says the family did the thing. It does NOT say the child has learned it,
 * and it writes nothing to her profile. Evidence is created by the evidence
 * architecture, by a person who looked at what she actually did - which is the
 * whole reason a path cannot quietly become a transcript.
 */
create or replace function public.complete_path_node(p_node uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_path_nodes;
begin
  select * into v from public.learning_path_nodes n where n.id = p_node;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.learning_path_nodes n
     set status = 'completed', completed_by = auth.uid(), completed_at = now()
   where n.id = p_node;
  insert into public.learning_path_events (
      path_id, student_id, kind, node_id, skill_id, note, actor)
  values (v.path_id, v.student_id, 'node_completed', p_node, v.skill_id, p_note, auth.uid());
  return jsonb_build_object(
    'node', p_node, 'status', 'completed',
    'evidence_created', false,
    'skill_state_changed', false,
    'note', 'Finishing a step records that the family did it. It is not evidence '
            'about the child, and nothing about her profile has changed.');
end $fn$;

create or replace function public.regenerate_learning_path(
  p_path uuid, p_reason app.path_regeneration_reason default 'parent_requested',
  p_note text default null, p_horizon integer default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'create') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  -- The path being replaced is left exactly as it is. If it was approved it
  -- stays approved until she approves the new one instead.
  return public.generate_learning_path(
    v.student_id, v.branch_root_skill_id, coalesce(p_horizon, v.node_horizon),
    v.parent_context, p_path, p_reason, p_note);
end $fn$;

-- --- "why is this here?" ------------------------------------------------------

create or replace function public.explain_learning_path(p_path uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_paths;
begin
  select * into v from public.learning_paths lp where lp.id = p_path;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'path', v.id, 'student', v.student_id, 'version', v.version,
    'supersedes', v.supersedes_id, 'status', v.status,
    'rule_version', v.rule_version, 'horizon', v.node_horizon,
    'branch_root_skill_id', v.branch_root_skill_id,
    'parent_context', v.parent_context,
    'regeneration_reason', v.regeneration_reason,
    'approved_by', v.approved_by, 'approved_at', v.approved_at,
    'generation_inputs', v.generation_inputs,
    'nodes', (select coalesce(jsonb_agg(jsonb_build_object(
                'position', n.position, 'skill_id', n.skill_id, 'skill', k.code,
                'skill_name', k.name,
                'reason', n.reason_code, 'reason_detail', n.reason_detail,
                'readiness_reasons', to_jsonb(n.readiness_reasons),
                'prerequisites_considered', to_jsonb(n.prerequisites_considered),
                'evidence_context', n.evidence_context,
                'resource_id', n.resource_id, 'resource_note', n.resource_note,
                'supports_node_id', n.supports_node_id,
                'status', n.status, 'added_by_human', n.added_by_human,
                'node', n.id) order by n.position), '[]'::jsonb)
                from public.learning_path_nodes n
                join public.skills k on k.id = n.skill_id
               where n.path_id = p_path and n.status <> 'removed'),
    'removed', (select coalesce(jsonb_agg(jsonb_build_object(
                'skill', k.code, 'node', n.id) order by n.position), '[]'::jsonb)
                from public.learning_path_nodes n
                join public.skills k on k.id = n.skill_id
               where n.path_id = p_path and n.status = 'removed'),
    'history', (select coalesce(jsonb_agg(jsonb_build_object(
                'kind', e.kind, 'skill_id', e.skill_id,
                'from', e.from_position, 'to', e.to_position,
                'warnings', e.warnings, 'note', e.note) order by e.created_at, e.id), '[]'::jsonb)
                from public.learning_path_events e where e.path_id = p_path));
end $fn$;

revoke all on function app.path_order_warnings(uuid, uuid, uuid, integer) from public, anon;
grant execute on function app.path_order_warnings(uuid, uuid, uuid, integer) to authenticated, service_role;

revoke all on function public.generate_learning_path(uuid, uuid, integer, text, uuid, app.path_regeneration_reason, text) from public, anon;
revoke all on function public.approve_learning_path(uuid, text) from public, anon;
revoke all on function public.reject_learning_path(uuid, text) from public, anon;
revoke all on function public.pause_learning_path(uuid, text) from public, anon;
revoke all on function public.resume_learning_path(uuid, text) from public, anon;
revoke all on function public.archive_learning_path(uuid, text) from public, anon;
revoke all on function public.add_path_node(uuid, uuid, integer, text) from public, anon;
revoke all on function public.remove_path_node(uuid, text) from public, anon;
revoke all on function public.reorder_path_node(uuid, integer, text) from public, anon;
revoke all on function public.complete_path_node(uuid, text) from public, anon;
revoke all on function public.regenerate_learning_path(uuid, app.path_regeneration_reason, text, integer) from public, anon;
revoke all on function public.explain_learning_path(uuid) from public, anon;

grant execute on function public.generate_learning_path(uuid, uuid, integer, text, uuid, app.path_regeneration_reason, text) to authenticated, service_role;
grant execute on function public.approve_learning_path(uuid, text) to authenticated, service_role;
grant execute on function public.reject_learning_path(uuid, text) to authenticated, service_role;
grant execute on function public.pause_learning_path(uuid, text) to authenticated, service_role;
grant execute on function public.resume_learning_path(uuid, text) to authenticated, service_role;
grant execute on function public.archive_learning_path(uuid, text) to authenticated, service_role;
grant execute on function public.add_path_node(uuid, uuid, integer, text) to authenticated, service_role;
grant execute on function public.remove_path_node(uuid, text) to authenticated, service_role;
grant execute on function public.reorder_path_node(uuid, integer, text) to authenticated, service_role;
grant execute on function public.complete_path_node(uuid, text) to authenticated, service_role;
grant execute on function public.regenerate_learning_path(uuid, app.path_regeneration_reason, text, integer) to authenticated, service_role;
grant execute on function public.explain_learning_path(uuid) to authenticated, service_role;

select app.assert_schema_invariants();
