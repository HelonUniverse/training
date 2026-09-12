-- =============================================================================
-- 0105  The calls a family makes about what to actually do
-- =============================================================================
-- Every function here does one of three things: it offers something, it records
-- that a person chose something, or it records that something happened. None of
-- them writes to a child's profile, and 0107 refuses any that tries.
--
-- THE FOUR REFUSALS, all of which return a structured answer rather than an
-- error, because each one is a normal thing to ask for and a normal thing to be
-- told no about:
--
--   goal_target        a goal is where the family is heading. Automatic
--                      selection does not treat it as this week's work.
--   already secure     material existing is not a reason to reteach something a
--                      person has already confirmed.
--   a choice stands    if there is already a live activity on this node, the
--                      selector returns it. It does not replace a parent's pick
--                      because an ORDER BY would have chosen differently.
--   nothing eligible   resource_available: false, and the path is untouched.
--
-- AND THE SENTENCE THAT EVERY RETURN VALUE CARRIES: completing an activity is
-- not mastery, skipping one is not failure, and nothing here has changed what
-- Nestra believes about the child. It is in the payload on purpose - a screen
-- built against these functions has the honest wording handed to it.
-- =============================================================================

-- --- a small shared helper ---------------------------------------------------
-- Not a policy decision, just the shape every lifecycle transition writes.

create or replace function app.learning_activity_note(p_what text)
returns text language sql immutable set search_path = '' as $fn$
  select case p_what
    when 'completed' then
      'The activity was completed. That is a fact about the activity, not about '
      || 'the child: nothing in her profile has changed and no evidence was created.'
    when 'skipped' then
      'The family moved past this one. Not a failure, and nothing about the '
      || 'child has changed.'
    when 'not_today' then
      'Not today. Nothing about the child has changed, and this is not a mark '
      || 'against anyone.'
    when 'replaced' then
      'A different way in, for the same skill. The first one was not wrong and '
      || 'the target has not moved.'
    else
      'Nothing about the child has changed.'
  end;
$fn$;

-- =============================================================================
-- Automatic selection, for one actionable node
-- =============================================================================

create or replace function public.select_activity_for_node(
  p_node     uuid,
  p_language app.learning_resource_language default null,
  p_modality app.learning_activity_modality default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_node  public.learning_path_nodes;
  v_res   jsonb;
  v_live  public.learning_activities;
  v_r     public.learning_resources;
  v_id    uuid;
  v_reasons app.learning_resource_reason[];
  v_family uuid; v_org uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v_node from public.learning_path_nodes n where n.id = p_node;
  if not found or not app.can_student_action(v_node.student_id, 'learning_plan', 'create') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  -- A parent's choice is not overwritten because the ordering would have gone
  -- another way. This is also what makes the call idempotent.
  select * into v_live from public.learning_activities a
   where a.path_node_id = p_node
     and a.status in ('proposed', 'selected', 'available', 'started')
   limit 1;
  if found then
    return jsonb_build_object(
      'selected', false,
      'reason', 'a_choice_already_stands',
      'activity_id', v_live.id,
      'origin', v_live.origin,
      'note', 'There is already something chosen for this step. Nestra does not '
              || 'swap it out; choose something different if you would rather.');
  end if;

  -- A goal is where the family is heading. Turning it into this week's work
  -- would be Nestra telling a mother her child is ready for something nothing
  -- in the evidence supports - and she never said that.
  if not app.learning_activity_node_is_actionable(p_node) then
    return jsonb_build_object(
      'selected', false,
      'reason', 'goal_target_is_not_a_next_step',
      'skill_id', v_node.skill_id,
      'path_changed', false,
      'note', 'This is what the family is working toward. You can still choose '
              || 'an activity for it yourself.');
  end if;

  -- Secure stays secure. Material existing is not an invitation.
  if not app.learning_activity_revisit_is_invited(v_node.student_id, v_node.skill_id, p_node) then
    return jsonb_build_object(
      'selected', false,
      'reason', 'already_confirmed_by_a_person',
      'skill_id', v_node.skill_id,
      'path_changed', false,
      'note', 'Someone has already confirmed this one. Nestra will not suggest '
              || 'going back over it on its own; ask to revisit it if you want to.');
  end if;

  v_res := app.learning_activity_select_resource(
             v_node.student_id, v_node.skill_id, p_language, p_modality);

  -- NO ELIGIBLE RESOURCE IS AN ANSWER. Nothing is written, the path is not
  -- touched, the skill is not changed, and nothing is invented to fill the gap.
  if not (v_res ->> 'resource_available')::boolean then
    return v_res || jsonb_build_object(
      'selected', false,
      'path_changed', false,
      'skill_changed', false,
      'note', 'No activity selected yet. The skill still belongs here - there is '
              || 'just nothing in the library for it, and you can add something '
              || 'of your own.');
  end if;

  select * into v_r from public.learning_resources r where r.id = (v_res ->> 'resource_id')::uuid;
  select st.family_id, st.primary_organization_id into v_family, v_org
    from public.students st where st.id = v_node.student_id;

  select array_agg(x::app.learning_resource_reason order by ord) into v_reasons
    from jsonb_array_elements_text(v_res -> 'reasons') with ordinality as t(x, ord);

  insert into public.learning_activities (
      student_id, family_id, organization_id, skill_id, path_id, path_node_id,
      resource_id, provider_id, activity_kind, modality, language, title,
      estimated_minutes, status, origin, record_provenance,
      selection_reasons, selection_context, rule_version)
  values (
      v_node.student_id, v_family, v_org, v_node.skill_id, v_node.path_id, p_node,
      v_r.id, v_r.provider_id, v_r.activity_kind, v_r.modality, v_r.language, v_r.title,
      v_r.estimated_minutes, 'selected', 'deterministic_system_selection', 'system_computed',
      coalesce(v_reasons, '{}'), v_res, app.learning_activity_rule_version())
  returning id into v_id;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, to_resource_id, reasons, detail, actor)
  values (v_id, v_node.student_id, 'selected', v_node.skill_id, v_r.id,
          coalesce(v_reasons, '{}'), v_res, auth.uid());

  return jsonb_build_object(
    'selected', true,
    'activity_id', v_id,
    'resource_available', true,
    'resource_id', v_r.id,
    'skill_id', v_node.skill_id,
    'origin', 'deterministic_system_selection',
    'reasons', v_res -> 'reasons',
    'rule_version', app.learning_activity_rule_version(),
    'evidence_created', false,
    'skill_state_changed', false,
    'note', 'Chosen by an ordering over material a person confirmed. No model '
            || 'was asked, and nothing about the child has changed.');
end $fn$;

comment on function public.select_activity_for_node(uuid, app.learning_resource_language, app.learning_activity_modality) is
  'Offers material for one actionable path node. Refuses, with a reason, on a '
  'goal target, on a skill a person confirmed, and when a choice already '
  'stands - and returns an honest nothing when the library has nothing.';

-- =============================================================================
-- A person chooses from the catalogue
-- =============================================================================
-- Distinct from the deterministic selection above in the one column anybody
-- would audit: she picked it, and the row says so.

create or replace function public.choose_activity_resource(
  p_student  uuid,
  p_skill    uuid,
  p_resource uuid,
  p_node     uuid default null,
  p_note     text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_r public.learning_resources; v_id uuid; v_family uuid; v_org uuid;
        v_path uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(p_student, 'learning_plan', 'create') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  select * into v_r from public.learning_resources r where r.id = p_resource;
  if not found then
    raise exception 'no such resource' using errcode = 'insufficient_privilege';
  end if;
  if p_node is not null then
    select n.path_id into v_path from public.learning_path_nodes n
     where n.id = p_node and n.student_id = p_student;
    if not found then
      raise exception 'no such node' using errcode = 'insufficient_privilege';
    end if;
  end if;

  select st.family_id, st.primary_organization_id into v_family, v_org
    from public.students st where st.id = p_student;

  insert into public.learning_activities (
      student_id, family_id, organization_id, skill_id, path_id, path_node_id,
      resource_id, provider_id, activity_kind, modality, language, title,
      estimated_minutes, status, origin, record_provenance, selected_by,
      selection_context)
  values (p_student, v_family, v_org, p_skill, v_path, p_node,
          v_r.id, v_r.provider_id, v_r.activity_kind, v_r.modality, v_r.language,
          v_r.title, v_r.estimated_minutes, 'selected', 'human_selected',
          'human_entered', auth.uid(),
          jsonb_build_object('chosen_by_a_person', true, 'note', p_note))
  returning id into v_id;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, to_resource_id, note, actor)
  values (v_id, p_student, 'selected', p_skill, v_r.id, p_note, auth.uid());

  return jsonb_build_object(
    'activity_id', v_id, 'origin', 'human_selected', 'resource_id', v_r.id,
    'skill_id', p_skill, 'evidence_created', false, 'skill_state_changed', false);
end $fn$;

-- =============================================================================
-- A person invents one
-- =============================================================================
-- "Use the measuring cups in the kitchen to compare 1/2 and 2/4" is a complete
-- activity and needs no provider, no catalogue row and no link. It is also not
-- evidence: she described what they are going to do, not what her daughter can
-- do, and the return value says so rather than leaving it to be assumed.

create or replace function public.create_custom_activity(
  p_student  uuid,
  p_skill    uuid,
  p_title    text,
  p_kind     app.learning_activity_kind default null,
  p_modality app.learning_activity_modality default 'unspecified',
  p_language app.learning_resource_language default 'unknown',
  p_parent_instructions text default null,
  p_child_instructions  text default null,
  p_minutes  integer default null,
  p_node     uuid default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_id uuid; v_family uuid; v_org uuid; v_path uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(p_student, 'learning_plan', 'create') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'an activity needs a name' using errcode = 'check_violation';
  end if;
  if p_node is not null then
    select n.path_id into v_path from public.learning_path_nodes n
     where n.id = p_node and n.student_id = p_student;
    if not found then
      raise exception 'no such node' using errcode = 'insufficient_privilege';
    end if;
  end if;

  select st.family_id, st.primary_organization_id into v_family, v_org
    from public.students st where st.id = p_student;

  insert into public.learning_activities (
      student_id, family_id, organization_id, skill_id, path_id, path_node_id,
      resource_id, activity_kind, modality, language, title,
      parent_instructions, child_instructions, estimated_minutes,
      status, origin, record_provenance, created_by, selection_context)
  values (p_student, v_family, v_org, p_skill, v_path, p_node,
          null, p_kind, coalesce(p_modality, 'unspecified'),
          coalesce(p_language, 'unknown'), btrim(p_title),
          p_parent_instructions, p_child_instructions, p_minutes,
          'selected', 'human_created', 'human_entered', auth.uid(),
          jsonb_build_object('made_by_a_person', true))
  returning id into v_id;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, note, actor)
  values (v_id, p_student, 'created', p_skill, p_parent_instructions, auth.uid());

  return jsonb_build_object(
    'activity_id', v_id, 'origin', 'human_created', 'resource_available', false,
    'skill_id', p_skill, 'evidence_created', false, 'skill_state_changed', false,
    'note', 'Your own activity, recorded as yours. Describing what you are going '
            || 'to do is not a statement about what your child can do.');
end $fn$;

comment on function public.create_custom_activity(uuid, uuid, text, app.learning_activity_kind, app.learning_activity_modality, app.learning_resource_language, text, text, integer, uuid) is
  'A family''s own activity for a skill, with no catalogue resource at all. A '
  'first-class activity, not a degraded one - and never automatically evidence.';

-- =============================================================================
-- Replacement
-- =============================================================================
-- The target skill does not move. That is what makes this a change of material
-- rather than a change of what the child is working on, and it is the one thing
-- a parent needs to be able to trust when she swaps a worksheet for a walk.
--
-- Resource A did not fail. The child did not fail. Nothing about the profile
-- moves, and the old row stays, marked, so the record still reads honestly.

create or replace function public.replace_activity_resource(
  p_activity uuid,
  p_resource uuid default null,
  p_title    text default null,
  p_note     text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_old public.learning_activities; v_r public.learning_resources; v_new uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v_old from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v_old.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if v_old.status in ('replaced', 'archived') then
    raise exception 'this activity has already been set aside' using errcode = 'check_violation';
  end if;
  if p_resource is null and coalesce(btrim(p_title), '') = '' then
    raise exception 'replacing needs either a resource or a name for what you are doing instead'
      using errcode = 'check_violation';
  end if;

  if p_resource is not null then
    select * into v_r from public.learning_resources r where r.id = p_resource;
    if not found then
      raise exception 'no such resource' using errcode = 'insufficient_privilege';
    end if;
  end if;

  -- The old one moves out of the way FIRST, so the one-live-per-node index is
  -- never momentarily violated.
  update public.learning_activities a
     set status = 'replaced', closed_at = now(), closed_by = auth.uid(),
         replacement_note = p_note
   where a.id = p_activity;

  insert into public.learning_activities (
      student_id, family_id, organization_id,
      skill_id,                      -- UNCHANGED. The target does not move.
      path_id, path_node_id,
      resource_id, provider_id, activity_kind, modality, language, title,
      estimated_minutes, status, origin, record_provenance,
      selected_by, created_by, replaces_activity_id, selection_context)
  values (
      v_old.student_id, v_old.family_id, v_old.organization_id,
      v_old.skill_id,
      v_old.path_id, v_old.path_node_id,
      v_r.id, v_r.provider_id,
      coalesce(v_r.activity_kind, v_old.activity_kind),
      coalesce(v_r.modality, 'unspecified'),
      coalesce(v_r.language, 'unknown'),
      coalesce(nullif(btrim(coalesce(p_title, '')), ''), v_r.title),
      v_r.estimated_minutes, 'selected',
      (case when p_resource is null then 'human_created'
            else 'human_selected' end)::app.learning_activity_origin,
      'human_entered',
      case when p_resource is null then null else auth.uid() end,
      auth.uid(), p_activity,
      jsonb_build_object('replaces', p_activity, 'chosen_by_a_person', true,
                         'note', p_note))
  returning id into v_new;

  update public.learning_activities a
     set replaced_by_activity_id = v_new
   where a.id = p_activity;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id,
      from_resource_id, to_resource_id, note, actor)
  values (v_new, v_old.student_id, 'replaced', v_old.skill_id,
          v_old.resource_id, v_r.id, p_note, auth.uid());

  return jsonb_build_object(
    'activity_id', v_new,
    'replaces', p_activity,
    'skill_id', v_old.skill_id,
    'skill_unchanged', true,
    'path_changed', false,
    'evidence_created', false,
    'skill_state_changed', false,
    'note', app.learning_activity_note('replaced'));
end $fn$;

comment on function public.replace_activity_resource(uuid, uuid, text, text) is
  'Swaps the material, keeps the skill. Implies nothing about the first '
  'resource and nothing at all about the child; creates no evidence and moves '
  'no state.';

-- =============================================================================
-- What happened
-- =============================================================================
-- Four transitions, one shape. Each records a fact about a morning and returns
-- the same two false flags, because the temptation to read meaning into them is
-- exactly what this layer exists to refuse.

create or replace function app.learning_activity_transition(
  p_activity uuid, p_status app.learning_activity_status,
  p_kind app.learning_activity_event_kind, p_note text)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_plan', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  update public.learning_activities a
     set status = p_status,
         started_at   = case when p_status = 'started' then coalesce(a.started_at, now())
                             else a.started_at end,
         completed_at = case when p_status = 'completed' then now() else a.completed_at end,
         completed_by = case when p_status = 'completed' then auth.uid() else a.completed_by end,
         closed_at    = case when p_status in ('skipped','not_today','archived')
                             then now() else a.closed_at end,
         closed_by    = case when p_status in ('skipped','not_today','archived')
                             then auth.uid() else a.closed_by end
   where a.id = p_activity;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, from_resource_id, note, actor)
  values (p_activity, v.student_id, p_kind, v.skill_id, v.resource_id, p_note, auth.uid());

  return jsonb_build_object(
    'activity_id', p_activity,
    'status', p_status,
    'skill_id', v.skill_id,
    'evidence_created', false,
    'skill_state_changed', false,
    'mastery_implied', false,
    'failure_implied', false,
    'note', app.learning_activity_note(p_status::text));
end $fn$;

create or replace function public.start_activity(p_activity uuid, p_note text default null)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.learning_activity_transition(p_activity, 'started', 'started', p_note);
$fn$;

create or replace function public.complete_activity(p_activity uuid, p_note text default null)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.learning_activity_transition(p_activity, 'completed', 'completed', p_note);
$fn$;

create or replace function public.skip_activity(p_activity uuid, p_note text default null)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.learning_activity_transition(p_activity, 'skipped', 'skipped', p_note);
$fn$;

create or replace function public.not_today_activity(p_activity uuid, p_note text default null)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.learning_activity_transition(p_activity, 'not_today', 'not_today', p_note);
$fn$;

create or replace function public.archive_activity(p_activity uuid, p_note text default null)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.learning_activity_transition(p_activity, 'archived', 'archived', p_note);
$fn$;

comment on function public.complete_activity(uuid, text) is
  'Records that the activity was completed. Says nothing whatever about the '
  'skill: no evidence is created, no state moves, and the return value states '
  'both in the payload so a screen cannot quietly imply otherwise.';

comment on function public.skip_activity(uuid, text) is
  'The family moved past this one. Not a failure, not a state change, and never '
  'counted against anybody.';

-- =============================================================================
-- Why this one
-- =============================================================================
-- Reconstructed from the stored structured reasons plus what the catalogue held
-- at the time - not from prose, and not by re-running the selector, which would
-- answer "what would I choose today" rather than "why is this here".

create or replace function public.explain_activity(p_activity uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; v_k record; v_r record;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  select k.code, k.name into v_k from public.skills k where k.id = v.skill_id;
  select r.title, r.kind, r.availability, r.content_ownership, r.is_demo,
         r.license_note, r.integration_mode
    into v_r from public.learning_resources r where r.id = v.resource_id;

  return jsonb_build_object(
    'activity_id', v.id,
    'title', v.title,
    'status', v.status,
    'skill', jsonb_build_object('id', v.skill_id, 'code', v_k.code, 'name', v_k.name),
    'resource', case when v.resource_id is null then null else jsonb_build_object(
        'id', v.resource_id, 'title', v_r.title, 'kind', v_r.kind,
        'availability', v_r.availability, 'content_ownership', v_r.content_ownership,
        'integration_mode', v_r.integration_mode,
        'license_note', v_r.license_note,
        'is_demo', v_r.is_demo) end,
    'resource_available', v.resource_id is not null,
    'origin', v.origin,
    'record_provenance', v.record_provenance,
    'chosen_by_a_person', v.origin in ('human_selected', 'human_created'),
    'reasons', to_jsonb(v.selection_reasons),
    'selection_context', v.selection_context,
    'rule_version', v.rule_version,
    'modality', v.modality,
    'language', v.language,
    'replaces', v.replaces_activity_id,
    'replaced_by', v.replaced_by_activity_id,
    'evidence_created', false,
    'skill_state_changed', false,
    'standards_consulted', false,
    'grade_or_age_consulted', false);
end $fn$;

comment on function public.explain_activity(uuid) is
  'Why this activity, answered from the structured record rather than from '
  'prose or a re-run of the selector. Reports plainly that no standard, grade '
  'or age was consulted, because that is a thing a parent is entitled to check.';

revoke all on function app.learning_activity_note(text) from public, anon;
revoke all on function app.learning_activity_transition(uuid, app.learning_activity_status, app.learning_activity_event_kind, text) from public, anon;
revoke all on function public.select_activity_for_node(uuid, app.learning_resource_language, app.learning_activity_modality) from public, anon;
revoke all on function public.choose_activity_resource(uuid, uuid, uuid, uuid, text) from public, anon;
revoke all on function public.create_custom_activity(uuid, uuid, text, app.learning_activity_kind, app.learning_activity_modality, app.learning_resource_language, text, text, integer, uuid) from public, anon;
revoke all on function public.replace_activity_resource(uuid, uuid, text, text) from public, anon;
revoke all on function public.start_activity(uuid, text) from public, anon;
revoke all on function public.complete_activity(uuid, text) from public, anon;
revoke all on function public.skip_activity(uuid, text) from public, anon;
revoke all on function public.not_today_activity(uuid, text) from public, anon;
revoke all on function public.archive_activity(uuid, text) from public, anon;
revoke all on function public.explain_activity(uuid) from public, anon;

grant execute on function app.learning_activity_note(text) to authenticated, service_role;
grant execute on function app.learning_activity_transition(uuid, app.learning_activity_status, app.learning_activity_event_kind, text) to authenticated, service_role;
grant execute on function public.select_activity_for_node(uuid, app.learning_resource_language, app.learning_activity_modality) to authenticated, service_role;
grant execute on function public.choose_activity_resource(uuid, uuid, uuid, uuid, text) to authenticated, service_role;
grant execute on function public.create_custom_activity(uuid, uuid, text, app.learning_activity_kind, app.learning_activity_modality, app.learning_resource_language, text, text, integer, uuid) to authenticated, service_role;
grant execute on function public.replace_activity_resource(uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.start_activity(uuid, text) to authenticated, service_role;
grant execute on function public.complete_activity(uuid, text) to authenticated, service_role;
grant execute on function public.skip_activity(uuid, text) to authenticated, service_role;
grant execute on function public.not_today_activity(uuid, text) to authenticated, service_role;
grant execute on function public.archive_activity(uuid, text) to authenticated, service_role;
grant execute on function public.explain_activity(uuid) to authenticated, service_role;

select app.assert_schema_invariants();
