-- =============================================================================
-- 0093  The routing engine: deterministic, auditable, and unable to call a model
-- =============================================================================
-- Same graph, same starting profile, same responses, same rule version produces
-- the same route. Every branch of this file is arithmetic over rows a family can
-- see. No model is consulted, and no model could be: there is nowhere in the
-- path for one to be reached.
--
-- THE FOUR RULES, in full.
--
-- WHERE IT STARTS. The branch is the root skill plus everything downstream of it
-- in the prerequisite graph, ranked by longest path from the root so a skill
-- always sorts after its prerequisites. A skill is ESTABLISHED when the profile
-- already says something useful about it: effective state `developing` or
-- `secure`, on at least `supported` evidence. The FRONTIER is the skills that
-- are not established but whose in-branch prerequisites all are, and the session
-- starts at the shallowest of those, breaking ties on skill code.
--
-- That is the rule that stops a child being asked about addition because of her
-- age. If multiplication is established, addition is behind the frontier and is
-- never presented; the session opens where Nestra's knowledge actually runs out.
--
-- WHERE IT GOES NEXT. Two demonstrated observations of a skill inside the
-- session are enough to explore the next connected skill - there is no score to
-- push higher, so a third correct answer buys nothing and costs a child's
-- afternoon. Fewer than two, and the next item comes from the same skill.
--
-- THE FRUSTRATION FLOOR. Two consecutive `not_demonstrated` observations ANYWHERE
-- in the branch, and the branch stops escalating. At most ONE prerequisite probe
-- follows, and then the session ends. There is no downward staircase: a child is
-- not walked backwards through five skills to find a floor.
--
-- The probe targets a DIRECT prerequisite of the floored skill that was not
-- observed in this session and is not human-confirmed secure. Direct only, so
-- there is no recursive descent. Unseen, because re-asking something she just
-- demonstrated is the repetition this rule exists to prevent. Not
-- human-confirmed secure, because a parent's standing judgement is not re-opened
-- by difficulty further up. Ties between equally-near prerequisites break on
-- skill code. If nothing qualifies there is no probe at all and the branch
-- simply ends.
--
-- The probe's own result creates an observation, may explain the boundary, and
-- does exactly nothing else: it lowers no state, and it cannot trigger a second
-- probe.
--
-- SKIPPED AND NOT TODAY ARE NOT FAILURES. They do not touch the consecutive
-- counter, they cannot reach the floor, and they leave the profile alone. A
-- child who says "not today" has told us something about today, not about
-- herself.
--
-- SESSION-LOCAL, AND THE LOOP THAT IS NOT ALLOWED TO EXIST. Observations made
-- during a session steer the rest of that session. They are NOT written into the
-- profile, so the routing cannot read back its own unreviewed guess as
-- established evidence and grow more confident from it. The established set is
-- the profile plus this session's demonstrated observations, and the profile
-- half of that only ever contains things a person put there.
-- =============================================================================

create or replace function app.diagnostic_rule_version()
returns text language sql immutable set search_path = '' as $fn$
  select '2026-09-11.1'::text;
$fn$;

-- --- the branch ---------------------------------------------------------------
-- Longest path from the root, so a skill with two prerequisites sorts after both
-- of them. Depth 20 is a cycle guard; the graph already refuses cycles.

create or replace function app.diagnostic_branch(p_root uuid)
returns table (skill_id uuid, depth integer, code text)
language sql stable security invoker set search_path = '' as $fn$
  with recursive down as (
    select p_root as sid, 0 as d
    union all
    select sp.skill_id, w.d + 1
      from public.skill_prerequisites sp
      join down w on sp.prerequisite_skill_id = w.sid
     where w.d < 20
  )
  select w.sid, max(w.d)::integer, k.code
    from down w join public.skills k on k.id = w.sid
   where k.active
   group by w.sid, k.code;
$fn$;

-- --- what the profile already establishes -------------------------------------
-- The effective state, so a parent's decision counts, and the Phase 3 evidence
-- sufficiency, so a state resting on one note does not stop us exploring. Both
-- come from rows a person put there: an unreviewed proposal is not usable
-- evidence and never reaches this.

create or replace function app.diagnostic_established(p_student uuid, p_skill uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select coalesce((select ss.skill_state in ('developing','secure')
                     and ss.evidence_sufficiency >= 'supported'
                     from public.student_skills ss
                    where ss.student_id = p_student and ss.skill_id = p_skill), false);
$fn$;

-- --- a state a person put there, and that a probe may not disturb --------------
-- An active human confirmation of `secure` is not a hypothesis the diagnostic
-- gets to re-open because something downstream went badly. A parent said her
-- daughter is solid on this; a hard afternoon with the next skill up is not
-- evidence against that, and asking again would imply it was.

create or replace function app.diagnostic_human_confirmed_secure(p_student uuid, p_skill uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select exists (
    select 1 from public.student_skills ss
      join public.student_skill_overrides o on o.id = ss.active_override_id
     where ss.student_id = p_student and ss.skill_id = p_skill
       and ss.skill_state = 'secure' and o.status = 'active'
       and o.decided_state = 'secure' and o.decided_by is not null);
$fn$;

-- --- what this session has seen so far ----------------------------------------

create or replace function app.diagnostic_session_state(p_session uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare
  r record;
  v_per      jsonb := '{}'::jsonb;
  v_cur      jsonb;
  v_key      text;
  v_consec   int := 0;
  v_floored  boolean := false;
  v_probe    boolean := false;
  v_last     uuid;
  v_n        int;
  v_seq      int := 0;
begin
  for r in
    select si.skill_id, si.sequence, si.reason_code, o.outcome
      from public.diagnostic_session_items si
      left join public.diagnostic_observations o on o.session_item_id = si.id
     where si.session_id = p_session
     order by si.sequence
  loop
    v_seq  := r.sequence;
    v_last := r.skill_id;
    v_key  := r.skill_id::text;
    if r.reason_code = 'prerequisite_probe' then v_probe := true; end if;

    v_cur := coalesce(v_per -> v_key,
                      jsonb_build_object('demonstrated', 0, 'presented', 0, 'answered', 0));
    v_cur := jsonb_set(v_cur, '{presented}', to_jsonb((v_cur->>'presented')::int + 1));

    if r.outcome is not null then
      v_cur := jsonb_set(v_cur, '{answered}', to_jsonb((v_cur->>'answered')::int + 1));
    end if;

    if r.outcome = 'demonstrated' then
      v_cur := jsonb_set(v_cur, '{demonstrated}', to_jsonb((v_cur->>'demonstrated')::int + 1));
      v_consec := 0;
    elsif r.outcome = 'not_demonstrated' then
      v_consec := v_consec + 1;
      if v_consec >= 2 then v_floored := true; end if;
    end if;
    -- `skipped` and `not_today` deliberately fall through: they change nothing
    -- except that the item was presented.

    v_per := jsonb_set(v_per, array[v_key], v_cur);
  end loop;

  return jsonb_build_object(
    'per_skill', v_per,
    'consecutive_not_demonstrated', v_consec,
    'floored', v_floored,
    'prerequisite_probe_spent', v_probe,
    'last_skill_id', v_last,
    'last_sequence', v_seq);
end $fn$;

-- --- where to go next ---------------------------------------------------------

create or replace function app.diagnostic_next(p_session uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare
  v_s        public.diagnostic_sessions;
  v_state    jsonb;
  v_per      jsonb;
  r          record;
  v_item     uuid;
  v_est      boolean;
  v_ready    boolean;
  v_reason   app.diagnostic_reason_code;
  v_frontier boolean := false;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  if not found then
    raise exception 'no such session' using errcode = 'insufficient_privilege';
  end if;

  v_state := app.diagnostic_session_state(p_session);
  v_per   := v_state -> 'per_skill';

  -- the floor, and the single probe it is allowed
  if (v_state->>'floored')::boolean then
    if (v_state->>'prerequisite_probe_spent')::boolean then
      return jsonb_build_object('done', true, 'stop_reason', 'frustration_floor');
    end if;
    -- DIRECT prerequisites of the floored skill only. Every one of them is
    -- equally near, so the stable skill code decides between them - never a
    -- benchmark, a grade, an age or a number about the child.
    for r in
      select k.id as skill_id, k.code
        from public.skill_prerequisites sp
        join public.skills k on k.id = sp.prerequisite_skill_id
       where sp.skill_id = (v_state->>'last_skill_id')::uuid
         and k.active
       order by k.code
    loop
      -- TWO CONDITIONS, and a skill must clear both.
      --
      -- Not seen this session: a prerequisite the child demonstrated twenty
      -- minutes ago is not re-asked, because asking it again would be the
      -- repeated exposure to failure this whole rule exists to prevent.
      --
      -- Not human-confirmed secure: a parent's standing judgement is not
      -- re-opened because the next skill up went badly.
      --
      -- What is left is exactly what is worth one question - a prerequisite
      -- Nestra is taking on trust from the stored profile, unseen today.
      if coalesce(((v_per -> r.skill_id::text)->>'answered')::int, 0) = 0
         and not app.diagnostic_human_confirmed_secure(v_s.student_id, r.skill_id) then
        select i.id into v_item from public.diagnostic_items i
         where i.skill_id = r.skill_id and i.active
           and not exists (select 1 from public.diagnostic_session_items si
                            where si.session_id = p_session and si.item_id = i.id)
         order by i.sequence, i.id limit 1;
        if v_item is not null then
          return jsonb_build_object('done', false, 'skill_id', r.skill_id,
                                    'item_id', v_item, 'reason_code', 'prerequisite_probe');
        end if;
      end if;
    end loop;
    return jsonb_build_object('done', true, 'stop_reason', 'frustration_floor');
  end if;

  -- the frontier: not established, every in-branch prerequisite established
  for r in
    select b.skill_id, b.depth, b.code
      from app.diagnostic_branch(v_s.branch_root_skill_id) b
     order by b.depth, b.code
  loop
    v_est := app.diagnostic_established(v_s.student_id, r.skill_id)
             or coalesce(((v_per -> r.skill_id::text)->>'demonstrated')::int, 0) >= 2;
    if v_est then continue; end if;

    select bool_and(app.diagnostic_established(v_s.student_id, sp.prerequisite_skill_id)
                    or coalesce(((v_per -> sp.prerequisite_skill_id::text)->>'demonstrated')::int, 0) >= 2)
      into v_ready
      from public.skill_prerequisites sp
      join app.diagnostic_branch(v_s.branch_root_skill_id) b2 on b2.skill_id = sp.prerequisite_skill_id
     where sp.skill_id = r.skill_id;
    if coalesce(v_ready, true) is not true then continue; end if;

    v_frontier := true;
    select i.id into v_item from public.diagnostic_items i
     where i.skill_id = r.skill_id and i.active
       and not exists (select 1 from public.diagnostic_session_items si
                        where si.session_id = p_session and si.item_id = i.id)
     order by i.sequence, i.id limit 1;
    if v_item is null then continue; end if;

    v_reason := case
      when (v_state->>'last_skill_id') is null                 then 'explore_next_skill'
      when (v_state->>'last_skill_id')::uuid = r.skill_id      then 'uncertainty_probe'
      else 'explore_next_skill' end::app.diagnostic_reason_code;

    return jsonb_build_object('done', false, 'skill_id', r.skill_id,
                              'item_id', v_item, 'reason_code', v_reason);
  end loop;

  return jsonb_build_object('done', true,
    'stop_reason', case when v_frontier then 'no_items_available' else 'branch_complete' end);
end $fn$;

-- =============================================================================
-- The calls a family makes
-- =============================================================================

create or replace function app.diagnostic_present(p_session uuid, p_next jsonb)
returns uuid language plpgsql security invoker set search_path = '' as $fn$
declare v_s public.diagnostic_sessions; v_id uuid; v_seq int;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  select coalesce(max(si.sequence), 0) + 1 into v_seq
    from public.diagnostic_session_items si where si.session_id = p_session;

  insert into public.diagnostic_session_items (session_id, student_id, skill_id, item_id,
           sequence, reason_code)
  values (p_session, v_s.student_id, (p_next->>'skill_id')::uuid, (p_next->>'item_id')::uuid,
          v_seq, (p_next->>'reason_code')::app.diagnostic_reason_code)
  returning id into v_id;

  insert into public.diagnostic_routing_decisions (session_id, student_id, sequence,
           reason_code, to_skill_id, detail)
  values (p_session, v_s.student_id, v_seq,
          (p_next->>'reason_code')::app.diagnostic_reason_code,
          (p_next->>'skill_id')::uuid, p_next);
  return v_id;
end $fn$;

create or replace function app.diagnostic_finish(
  p_session uuid, p_reason app.diagnostic_stop_reason, p_status app.diagnostic_session_status)
returns void language plpgsql security invoker set search_path = '' as $fn$
declare v_s public.diagnostic_sessions; v_seq int;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  select coalesce(max(si.sequence), 0) + 1 into v_seq
    from public.diagnostic_routing_decisions si where si.session_id = p_session;
  insert into public.diagnostic_routing_decisions (session_id, student_id, sequence,
           reason_code, from_skill_id, detail)
  values (p_session, v_s.student_id, v_seq,
          case when p_reason = 'frustration_floor' then 'frustration_floor_reached'
               else 'branch_complete' end::app.diagnostic_reason_code,
          null, jsonb_build_object('stop_reason', p_reason::text));
  update public.diagnostic_sessions s
     set status = p_status, completed_at = now(), stop_reason = p_reason,
         stopped_by = auth.uid()
   where s.id = p_session;
end $fn$;

/**
 * Start one. The starting context is stored because the route only makes sense
 * against the knowledge it was made with: read two years later, "why did it open
 * at equivalent fractions" is answerable without re-deriving a profile that has
 * since moved on.
 */
create or replace function public.start_diagnostic_session(p_student uuid, p_root_skill uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_id uuid; v_ctx jsonb; v_next jsonb; v_item uuid; v_org uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(p_student, 'skill', 'create') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'skill_id', b.skill_id, 'code', b.code, 'depth', b.depth,
           'established', app.diagnostic_established(p_student, b.skill_id),
           'effective_state', (select ss.skill_state from public.student_skills ss
                                where ss.student_id = p_student and ss.skill_id = b.skill_id),
           'evidence_sufficiency', (select ss.evidence_sufficiency from public.student_skills ss
                                where ss.student_id = p_student and ss.skill_id = b.skill_id))
           order by b.depth, b.code), '[]'::jsonb)
    into v_ctx from app.diagnostic_branch(p_root_skill) b;

  select st.primary_organization_id into v_org from public.students st where st.id = p_student;

  insert into public.diagnostic_sessions (student_id, organization_id, branch_root_skill_id,
           status, rule_version, starting_context, started_by)
  values (p_student, v_org, p_root_skill, 'active', app.diagnostic_rule_version(), v_ctx, auth.uid())
  returning id into v_id;

  -- everything already established is skipped, and the skip is recorded
  insert into public.diagnostic_routing_decisions (session_id, student_id, sequence,
           reason_code, to_skill_id, detail)
  select v_id, p_student, 0, 'existing_evidence_skip', null,
         jsonb_build_object('skipped', jsonb_agg(b.code order by b.depth, b.code))
    from app.diagnostic_branch(p_root_skill) b
   where app.diagnostic_established(p_student, b.skill_id)
  having count(*) > 0;

  v_next := app.diagnostic_next(v_id);
  if (v_next->>'done')::boolean then
    perform app.diagnostic_finish(v_id, (v_next->>'stop_reason')::app.diagnostic_stop_reason, 'completed');
  else
    v_item := app.diagnostic_present(v_id, v_next);
  end if;

  return jsonb_build_object('session', v_id, 'rule_version', app.diagnostic_rule_version(),
                            'starting_context', v_ctx, 'next', v_next, 'session_item', v_item);
end $fn$;

/**
 * Record what a person saw, and route.
 *
 * The outcome is supplied by the human who watched, never inferred. Nestra does
 * not decide whether a child demonstrated something - it records that somebody
 * said so, and routes on it.
 */
create or replace function public.record_diagnostic_observation(
  p_session_item uuid, p_outcome text, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_si public.diagnostic_session_items;
  v_s  public.diagnostic_sessions;
  v_obs uuid; v_next jsonb; v_item uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v_si from public.diagnostic_session_items si where si.id = p_session_item;
  if not found then
    raise exception 'no such item' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(v_si.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  select * into v_s from public.diagnostic_sessions s where s.id = v_si.session_id;
  if v_s.status <> 'active' then
    raise exception 'this session is % and is not taking observations', v_s.status
      using errcode = 'check_violation';
  end if;
  if v_s.rule_version <> app.diagnostic_rule_version() then
    raise exception 'this session was routed under rules % and the current rules are %',
      v_s.rule_version, app.diagnostic_rule_version() using errcode = 'check_violation';
  end if;

  insert into public.diagnostic_observations (session_id, session_item_id, student_id,
           skill_id, outcome, note, observed_by)
  values (v_si.session_id, v_si.id, v_si.student_id, v_si.skill_id,
          p_outcome::app.diagnostic_outcome, p_note, auth.uid())
  returning id into v_obs;

  v_next := app.diagnostic_next(v_si.session_id);
  if (v_next->>'done')::boolean then
    perform app.diagnostic_finish(v_si.session_id,
      (v_next->>'stop_reason')::app.diagnostic_stop_reason, 'completed');
  else
    v_item := app.diagnostic_present(v_si.session_id, v_next);
  end if;

  return jsonb_build_object('observation', v_obs, 'outcome', p_outcome,
                            'next', v_next, 'session_item', v_item,
                            'session_state', app.diagnostic_session_state(v_si.session_id));
end $fn$;

create or replace function public.pause_diagnostic_session(p_session uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_s public.diagnostic_sessions;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  if not found or not app.can_student_action(v_s.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.diagnostic_sessions s set status = 'paused', paused_at = now()
   where s.id = p_session and s.status = 'active';
  return jsonb_build_object('session', p_session, 'status', 'paused',
                            'rule_version', v_s.rule_version);
end $fn$;

/**
 * Resume, or refuse to.
 *
 * A paused session carries the rule version it was routed under. If the engine
 * has moved on, this does NOT quietly re-route the remainder under new rules -
 * the session would then be half one algorithm and half another, and nobody
 * could say afterwards which questions came from which. It reports that a
 * restart is needed and leaves the session exactly as it was.
 */
create or replace function public.resume_diagnostic_session(p_session uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_s public.diagnostic_sessions;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  if not found or not app.can_student_action(v_s.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if v_s.rule_version <> app.diagnostic_rule_version() then
    return jsonb_build_object('session', p_session, 'resumed', false,
      'reason', 'rule_version_changed',
      'session_rule_version', v_s.rule_version,
      'current_rule_version', app.diagnostic_rule_version(),
      'status', v_s.status);
  end if;
  update public.diagnostic_sessions s set status = 'active', paused_at = null
   where s.id = p_session and s.status = 'paused';
  return jsonb_build_object('session', p_session, 'resumed', true,
                            'rule_version', v_s.rule_version, 'status', 'active');
end $fn$;

create or replace function public.stop_diagnostic_session(p_session uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_s public.diagnostic_sessions; v_n int;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  if not found or not app.can_student_action(v_s.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  perform app.diagnostic_finish(p_session, 'parent_stopped', 'stopped');
  update public.diagnostic_sessions s set note = p_note where s.id = p_session;
  select count(*) into v_n from public.diagnostic_observations o where o.session_id = p_session;
  return jsonb_build_object('session', p_session, 'status', 'stopped',
                            'stop_reason', 'parent_stopped', 'observations_preserved', v_n);
end $fn$;

-- =============================================================================
-- Review: the only way an observation becomes evidence
-- =============================================================================

create or replace function public.confirm_diagnostic_observation(
  p_observation uuid, p_skill_state text default null, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_o public.diagnostic_observations; v_ss uuid; v_ev uuid; v_org uuid; v_on date;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v_o from public.diagnostic_observations o where o.id = p_observation;
  if not found or not app.can_student_action(v_o.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if v_o.outcome <> 'demonstrated' then
    raise exception 'only an observation in which a child demonstrated something becomes evidence'
      using errcode = 'check_violation';
  end if;
  if v_o.review_status <> 'pending' then
    raise exception 'this observation has already been reviewed' using errcode = 'check_violation';
  end if;

  select st.primary_organization_id into v_org from public.students st where st.id = v_o.student_id;
  select ss.id into v_ss from public.student_skills ss
   where ss.student_id = v_o.student_id and ss.skill_id = v_o.skill_id;
  if v_ss is null then
    insert into public.student_skills (student_id, skill_id, organization_id, source_type,
             record_provenance, evidence_source, skill_state, created_by)
    values (v_o.student_id, v_o.skill_id, v_org, 'observation', 'human_entered',
            'diagnostic_session', 'unknown', auth.uid())
    returning id into v_ss;
  end if;

  v_on := v_o.observed_at::date;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id, organization_id,
           occurred_on, evidence_note, skill_state, source_type, evidence_source,
           record_provenance, created_by)
  values (v_ss, v_o.student_id, v_o.skill_id, v_org, v_on, coalesce(p_note, v_o.note),
          nullif(p_skill_state, '')::app.skill_state, 'observation', 'diagnostic_session',
          'human_confirmed_ai_proposal', auth.uid())
  returning id into v_ev;

  update public.diagnostic_observations o
     set review_status = 'confirmed', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = p_note, promoted_event_id = v_ev
   where o.id = p_observation;

  return public.recompute_student_skill(v_o.student_id, v_o.skill_id)
         || jsonb_build_object('observation', p_observation, 'evidence_event', v_ev);
end $fn$;

create or replace function public.reject_diagnostic_observation(
  p_observation uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_o public.diagnostic_observations;
begin
  select * into v_o from public.diagnostic_observations o where o.id = p_observation;
  if not found or not app.can_student_action(v_o.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.diagnostic_observations o
     set review_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = p_note
   where o.id = p_observation and o.review_status = 'pending';
  return jsonb_build_object('observation', p_observation, 'review_status', 'rejected');
end $fn$;

-- --- "why did it go there?" ---------------------------------------------------

create or replace function public.explain_diagnostic_session(p_session uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v_s public.diagnostic_sessions;
begin
  select * into v_s from public.diagnostic_sessions s where s.id = p_session;
  if not found or not app.can_student_action(v_s.student_id, 'skill', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'session', v_s.id, 'status', v_s.status, 'rule_version', v_s.rule_version,
    'stop_reason', v_s.stop_reason, 'starting_context', v_s.starting_context,
    'route', (select coalesce(jsonb_agg(jsonb_build_object(
                 'sequence', si.sequence, 'skill', k.code, 'reason', si.reason_code,
                 'outcome', o.outcome) order by si.sequence), '[]'::jsonb)
                from public.diagnostic_session_items si
                join public.skills k on k.id = si.skill_id
                left join public.diagnostic_observations o on o.session_item_id = si.id
               where si.session_id = p_session),
    'decisions', (select coalesce(jsonb_agg(jsonb_build_object(
                 'sequence', d.sequence, 'reason', d.reason_code, 'detail', d.detail)
                 order by d.sequence), '[]'::jsonb)
                from public.diagnostic_routing_decisions d where d.session_id = p_session),
    'session_state', app.diagnostic_session_state(p_session));
end $fn$;

revoke all on function app.diagnostic_rule_version() from public, anon;
revoke all on function app.diagnostic_branch(uuid) from public, anon;
revoke all on function app.diagnostic_established(uuid, uuid) from public, anon;
revoke all on function app.diagnostic_human_confirmed_secure(uuid, uuid) from public, anon;
revoke all on function app.diagnostic_session_state(uuid) from public, anon;
revoke all on function app.diagnostic_next(uuid) from public, anon;
revoke all on function app.diagnostic_present(uuid, jsonb) from public, anon;
revoke all on function app.diagnostic_finish(uuid, app.diagnostic_stop_reason, app.diagnostic_session_status) from public, anon;
grant execute on function app.diagnostic_rule_version() to authenticated, service_role;
grant execute on function app.diagnostic_branch(uuid) to authenticated, service_role;
grant execute on function app.diagnostic_established(uuid, uuid) to authenticated, service_role;
grant execute on function app.diagnostic_human_confirmed_secure(uuid, uuid) to authenticated, service_role;
grant execute on function app.diagnostic_session_state(uuid) to authenticated, service_role;
grant execute on function app.diagnostic_next(uuid) to authenticated, service_role;
grant execute on function app.diagnostic_present(uuid, jsonb) to authenticated, service_role;
grant execute on function app.diagnostic_finish(uuid, app.diagnostic_stop_reason, app.diagnostic_session_status) to authenticated, service_role;

revoke all on function public.start_diagnostic_session(uuid, uuid) from public, anon;
revoke all on function public.record_diagnostic_observation(uuid, text, text) from public, anon;
revoke all on function public.pause_diagnostic_session(uuid) from public, anon;
revoke all on function public.resume_diagnostic_session(uuid) from public, anon;
revoke all on function public.stop_diagnostic_session(uuid, text) from public, anon;
revoke all on function public.confirm_diagnostic_observation(uuid, text, text) from public, anon;
revoke all on function public.reject_diagnostic_observation(uuid, text) from public, anon;
revoke all on function public.explain_diagnostic_session(uuid) from public, anon;
grant execute on function public.start_diagnostic_session(uuid, uuid) to authenticated, service_role;
grant execute on function public.record_diagnostic_observation(uuid, text, text) to authenticated, service_role;
grant execute on function public.pause_diagnostic_session(uuid) to authenticated, service_role;
grant execute on function public.resume_diagnostic_session(uuid) to authenticated, service_role;
grant execute on function public.stop_diagnostic_session(uuid, text) to authenticated, service_role;
grant execute on function public.confirm_diagnostic_observation(uuid, text, text) to authenticated, service_role;
grant execute on function public.reject_diagnostic_observation(uuid, text) to authenticated, service_role;
grant execute on function public.explain_diagnostic_session(uuid) to authenticated, service_role;

select app.assert_schema_invariants();
