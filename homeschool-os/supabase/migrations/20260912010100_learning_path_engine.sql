-- =============================================================================
-- 0099  The path engine: deterministic, explainable, and unable to call a model
-- =============================================================================
-- Same graph, same profile, same evidence, same goals, same resources, same rule
-- version produces the same path. Every line of this file is arithmetic over
-- rows a family can see. No model is consulted and none could be: there is
-- nowhere in the path for one to be reached.
--
-- WHERE CANDIDATES COME FROM. Eight sources, each of which is a fact about this
-- child or this family, and none of which is a fact about children in general:
--
--   parent_goal                   a person set a goal naming this skill
--   revisit_requested             a person asked to come back to it
--   active_plan_priority          an active learning plan names it
--   diagnostic_frontier           the last session ended around here
--   uncertain_boundary            there is evidence and it does not settle it
--   continue_connected_skill      it follows from something characterized
--   curriculum_resource_available the family already has material for it
--   enrichment                    application of something a person confirmed
--
-- Age, grade, benchmarks and what other children are doing are absent, and 0101
-- refuses these functions if their source so much as mentions them.
--
-- HOW THEY ARE ORDERED. By that list, then by depth in the graph, then by skill
-- code. Three total orders, no score. The first key is the only judgement in the
-- engine and it says one thing: what a person asked for comes before what
-- Nestra noticed.
--
-- READINESS IS NOT A NUMBER. Each node carries a set of reasons - what its
-- prerequisites look like, what evidence exists, where the uncertainty is, who
-- named it. "Equivalent Fractions is reasonable to explore because the fraction
-- concepts under it have useful evidence and the diagnostic stopped near this
-- boundary" is a sentence built from those reasons. "72% ready" is not
-- expressible here, and 0101 makes sure it stays that way.
--
-- PREREQUISITES INFORM, THEY DO NOT GATE. A prerequisite does not have to be
-- `secure`; developing evidence is usually enough to explore what comes next. If
-- a direct prerequisite is not characterized at all, the path may propose ONE
-- support node before the skill it supports. One. There is no staircase, no
-- recursive descent, and a child is never walked back through five skills to
-- find a floor - the same rule Phase 5 settled for the diagnostic.
--
-- NOTHING HERE TOUCHES THE PROFILE. Generating, approving, reordering and
-- completing all leave student_skills, student_skill_events and
-- student_skill_overrides exactly as they were. Being on a path is not evidence.
-- =============================================================================

create or replace function app.learning_path_rule_version()
returns text language sql immutable set search_path = '' as $fn$
  select '2026-09-12.1'::text;
$fn$;

-- --- the branch --------------------------------------------------------------
-- Deliberately its own function rather than a call into Phase 5's
-- app.diagnostic_branch. The two engines answer different questions and must be
-- free to disagree later; sharing the function would silently couple a change in
-- one to the behaviour of the other.

create or replace function app.path_branch(p_root uuid)
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

-- --- what Nestra knows about one skill ---------------------------------------
-- The effective state, so a person's decision counts; the sufficiency, so "we
-- know a little" and "we know quite a lot" are different; and the date, so the
-- answer can be placed in time. Four facts, kept apart.

create or replace function app.path_skill_context(p_student uuid, p_skill uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v_ss public.student_skills;
begin
  -- The STORED profile, not a fresh recompute. Two reasons, and the second is
  -- the one that matters. A recompute here would be a second opinion running
  -- beside Phase 3's, and the moment the two disagreed the path would be
  -- reasoning from something other than what the parent can see on her own
  -- screen. And the stored row is where a person's override lives; recomputing
  -- would quietly route around her decision.
  select * into v_ss from public.student_skills ss
   where ss.student_id = p_student and ss.skill_id = p_skill;
  return jsonb_build_object(
    'effective_state',       coalesce(v_ss.skill_state::text, 'unknown'),
    'computed_state',        coalesce(v_ss.computed_state::text, 'unknown'),
    'evidence_sufficiency',  coalesce(v_ss.evidence_sufficiency::text, 'none'),
    'usable_evidence_count', coalesce(v_ss.usable_evidence_count, 0),
    'state_as_of',           v_ss.state_as_of,
    'human_confirmed',       (v_ss.active_override_id is not null),
    'conflicting_evidence',
      coalesce('conflicting_assertions_present' = any(v_ss.state_reasons), false),
    'unreviewed_ai_present',
      coalesce('excluded_unreviewed_ai_proposal' = any(v_ss.state_reasons), false));
end $fn$;

-- Characterized: Nestra can say something about it at all.
create or replace function app.path_characterized(p_student uuid, p_skill uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select coalesce((select ss.skill_state <> 'unknown'
                     from public.student_skills ss
                    where ss.student_id = p_student and ss.skill_id = p_skill), false);
$fn$;

-- Well characterized: enough that re-proposing it would be repeating work
-- already done. `emerging` deliberately does NOT qualify - early evidence is a
-- reason to keep exploring, not a reason to move on.
create or replace function app.path_well_characterized(p_student uuid, p_skill uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select coalesce((select (ss.skill_state in ('developing','secure')
                           and ss.evidence_sufficiency >= 'supported')
                          or (ss.skill_state = 'secure' and ss.active_override_id is not null)
                     from public.student_skills ss
                    where ss.student_id = p_student and ss.skill_id = p_skill), false);
$fn$;

create or replace function app.path_human_confirmed_secure(p_student uuid, p_skill uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select exists (
    select 1 from public.student_skills ss
      join public.student_skill_overrides o on o.id = ss.active_override_id
     where ss.student_id = p_student and ss.skill_id = p_skill
       and ss.skill_state = 'secure' and o.status = 'active'
       and o.decided_state = 'secure' and o.decided_by is not null);
$fn$;

-- --- where the last diagnostic ran out ---------------------------------------
-- The frontier is the skills the most recent finished session actually asked
-- about and did not settle. An unreviewed observation is NOT knowledge, so this
-- is about where the session STOPPED, never about what it guessed.

create or replace function app.path_diagnostic_frontier(p_student uuid, p_root uuid)
returns table (skill_id uuid)
language sql stable security invoker set search_path = '' as $fn$
  with last_session as (
    select s.id from public.diagnostic_sessions s
     where s.student_id = p_student
       and (p_root is null or s.branch_root_skill_id = p_root)
       and s.status in ('completed','stopped')
     order by s.completed_at desc nulls last, s.started_at desc, s.id desc
     limit 1)
  select distinct si.skill_id
    from public.diagnostic_session_items si
    join last_session ls on ls.id = si.session_id
   where not exists (
     select 1 from public.diagnostic_observations o
      where o.session_item_id = si.id and o.outcome = 'demonstrated');
$fn$;

-- --- what people have asked for ----------------------------------------------
-- Goals a person set, priorities in an active plan, and revisits somebody asked
-- for. All three are a human naming a skill; none of them is derivable from a
-- birthday.

create or replace function app.path_named_by_a_person(p_student uuid)
returns table (skill_id uuid, reason app.path_node_reason)
language sql stable security invoker set search_path = '' as $fn$
  select g.skill_id, 'parent_goal'::app.path_node_reason
    from public.learning_goals g
   where g.student_id = p_student and g.skill_id is not null
     and g.status in ('proposed','active')
  union
  select k, 'active_plan_priority'::app.path_node_reason
    from public.learning_plans p, unnest(p.priority_skill_ids) as k
   where p.student_id = p_student and p.status = 'active'
  union
  select d.skill_id, 'revisit_requested'::app.path_node_reason
    from public.student_skill_refresh_decisions d
   where d.student_id = p_student
     and d.kind = 'revisit_requested'
     and d.decided_at = (select max(d2.decided_at)
                           from public.student_skill_refresh_decisions d2
                          where d2.student_id = d.student_id and d2.skill_id = d.skill_id);
$fn$;

-- --- a resource, if one honestly exists --------------------------------------
-- Deterministic, and allowed to find nothing. A skill belongs on a path whether
-- or not anybody has material for it; the alternative is inventing content,
-- which is how a learning model quietly becomes a content catalogue.
--
-- Enrolled courses first, because material this family already has beats
-- material they do not; then a mapping a person confirmed over one nobody has
-- looked at; then the resource kind in its declared order; then title and id, so
-- two runs never disagree.

create or replace function app.path_resource_for(p_student uuid, p_skill uuid)
returns uuid language sql stable security invoker set search_path = '' as $fn$
  select r.id
    from public.resource_skills rs
    join public.learning_resources r on r.id = rs.resource_id
    left join public.courses c on c.id = r.course_id
   where rs.skill_id = p_skill
   order by
     case when exists (select 1 from public.student_course_enrollments e
                        where e.student_id = p_student and e.course_id = c.id)
          then 0 else 1 end,
     case when rs.confirmed then 0 else 1 end,
     r.kind,
     r.title,
     r.id
   limit 1;
$fn$;

-- =============================================================================
-- Candidates
-- =============================================================================
-- Every source, unioned, then reduced to one row per skill keeping the
-- strongest reason and the union of what makes it reasonable. The ordering keys
-- are three total orders - reason, depth, code - and there is no score anywhere.

create or replace function app.path_candidates(p_student uuid, p_root uuid)
returns table (
  skill_id uuid,
  reason_code app.path_node_reason,
  readiness_reasons app.path_readiness_reason[],
  reason_rank integer,
  depth integer,
  code text)
language sql stable security invoker set search_path = '' as $fn$
  with branch as (
    select b.skill_id, b.depth, b.code from app.path_branch(p_root) b
  ),
  named as (
    select n.skill_id, n.reason from app.path_named_by_a_person(p_student) n
  ),
  sourced as (
    -- a person named it
    select b.skill_id, n.reason as reason_code,
           'named_by_a_person'::app.path_readiness_reason as rr
      from branch b join named n on n.skill_id = b.skill_id

    union all
    -- the last diagnostic ended around here
    select b.skill_id, 'diagnostic_frontier'::app.path_node_reason,
           'diagnostic_stopped_near_here'::app.path_readiness_reason
      from branch b join app.path_diagnostic_frontier(p_student, p_root) f
        on f.skill_id = b.skill_id
     where not app.path_well_characterized(p_student, b.skill_id)

    union all
    -- there is evidence and it does not settle the question
    select b.skill_id, 'uncertain_boundary'::app.path_node_reason, x.rr
      from branch b
      cross join (values ('has_usable_evidence'::app.path_readiness_reason),
                         ('uncertainty_at_this_boundary'::app.path_readiness_reason)) as x(rr)
     where (app.path_skill_context(p_student, b.skill_id)->>'usable_evidence_count')::int > 0
       and not app.path_well_characterized(p_student, b.skill_id)

    union all
    -- it follows directly from something we can already say something about
    select b.skill_id, 'continue_connected_skill'::app.path_node_reason,
           'prerequisites_characterized'::app.path_readiness_reason
      from branch b
     where not app.path_well_characterized(p_student, b.skill_id)
       and exists (select 1 from public.skill_prerequisites sp
                    where sp.skill_id = b.skill_id
                      and app.path_well_characterized(p_student, sp.prerequisite_skill_id))

    union all
    -- or it is where this branch begins. Without this arm a child Nestra knows
    -- nothing about has no starting point at all: every other source needs
    -- something already characterized, and the very first path for a new family
    -- came back with whatever happened to have a resource attached, several
    -- skills up the graph. Found by the first smoke test.
    select b.skill_id, 'continue_connected_skill'::app.path_node_reason,
           'no_prerequisites_in_graph'::app.path_readiness_reason
      from branch b
     where not app.path_well_characterized(p_student, b.skill_id)
       and not exists (select 1 from public.skill_prerequisites sp
                        join branch b2 on b2.skill_id = sp.prerequisite_skill_id
                       where sp.skill_id = b.skill_id)

    union all
    -- the family already has material for it
    select b.skill_id, 'curriculum_resource_available'::app.path_node_reason,
           'no_evidence_yet'::app.path_readiness_reason
      from branch b
     where not app.path_well_characterized(p_student, b.skill_id)
       and app.path_resource_for(p_student, b.skill_id) is not null

    union all
    -- something a person confirmed, with real material to apply it. Offered only
    -- when such material exists: a category is never filled by inventing work.
    select b.skill_id, 'enrichment'::app.path_node_reason,
           'human_confirmed_secure'::app.path_readiness_reason
      from branch b
     where app.path_human_confirmed_secure(p_student, b.skill_id)
       and app.path_resource_for(p_student, b.skill_id) is not null
  ),
  ranked as (
    select s.skill_id,
           s.reason_code,
           case s.reason_code
             when 'parent_goal'                   then 1
             when 'revisit_requested'             then 2
             when 'active_plan_priority'          then 3
             when 'diagnostic_frontier'           then 4
             when 'uncertain_boundary'            then 5
             when 'continue_connected_skill'      then 6
             when 'curriculum_resource_available' then 7
             when 'enrichment'                    then 8
             else 9 end as reason_rank,
           s.rr
      from sourced s
  )
  select r.skill_id,
         (array_agg(r.reason_code order by r.reason_rank))[1],
         (select coalesce(array_agg(distinct x order by x), '{}')
            from unnest(array_agg(r.rr)) x)::app.path_readiness_reason[],
         min(r.reason_rank)::integer,
         b.depth,
         b.code
    from ranked r
    join branch b on b.skill_id = r.skill_id
   group by r.skill_id, b.depth, b.code
   order by min(r.reason_rank), b.depth, b.code;
$fn$;

-- --- the readiness account for one node --------------------------------------
-- Built from the graph and the profile, never from a sentence. This is what
-- "why is this here?" is answered with.

create or replace function app.path_readiness(p_student uuid, p_skill uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare
  r record; v_rr app.path_readiness_reason[] := '{}'; v_pre uuid[] := '{}';
  v_ctx jsonb; v_n int := 0;
begin
  v_ctx := app.path_skill_context(p_student, p_skill);

  for r in select sp.prerequisite_skill_id as pid from public.skill_prerequisites sp
            where sp.skill_id = p_skill
            order by sp.prerequisite_skill_id
  loop
    v_n := v_n + 1;
    v_pre := v_pre || r.pid;
    if app.path_well_characterized(p_student, r.pid) then
      v_rr := v_rr || 'prerequisites_characterized'::app.path_readiness_reason;
    elsif app.path_characterized(p_student, r.pid) then
      v_rr := v_rr || 'prerequisite_uncertain'::app.path_readiness_reason;
    else
      v_rr := v_rr || 'prerequisite_not_characterized'::app.path_readiness_reason;
    end if;
  end loop;
  if v_n = 0 then
    v_rr := v_rr || 'no_prerequisites_in_graph'::app.path_readiness_reason;
  end if;

  if (v_ctx->>'usable_evidence_count')::int > 0 then
    v_rr := v_rr || 'has_usable_evidence'::app.path_readiness_reason;
  else
    v_rr := v_rr || 'no_evidence_yet'::app.path_readiness_reason;
  end if;
  if app.path_human_confirmed_secure(p_student, p_skill) then
    v_rr := v_rr || 'human_confirmed_secure'::app.path_readiness_reason;
  end if;
  if exists (select 1 from public.learning_path_nodes n
              where n.student_id = p_student and n.skill_id = p_skill) then
    v_rr := v_rr || 'previously_on_a_path'::app.path_readiness_reason;
  end if;

  return jsonb_build_object(
    'readiness_reasons', to_jsonb((select coalesce(array_agg(distinct x order by x), '{}')
                                     from unnest(v_rr) x)),
    'prerequisites_considered', to_jsonb(v_pre),
    'evidence_context', v_ctx);
end $fn$;

-- --- the one support node a path is allowed ----------------------------------
-- A DIRECT prerequisite of the node, not characterized at all, not confirmed by
-- a person, not already on the path. Direct only, so there is no recursion; ties
-- break on skill code, never on a benchmark, a grade or an age. If nothing
-- qualifies there is no support node, and that is a complete answer.

create or replace function app.path_unmet_prerequisites(
  p_student uuid, p_root uuid, p_skill uuid, p_taken uuid[])
returns uuid[] language sql stable security invoker set search_path = '' as $fn$
  select coalesce(array_agg(k.id order by k.code), '{}')
    from public.skill_prerequisites sp
    join public.skills k on k.id = sp.prerequisite_skill_id
    join app.path_branch(p_root) b on b.skill_id = k.id
   where sp.skill_id = p_skill
     and k.active
     and not app.path_characterized(p_student, k.id)
     and not app.path_human_confirmed_secure(p_student, k.id)
     and not (k.id = any(p_taken));
$fn$;

comment on function app.path_unmet_prerequisites(uuid, uuid, uuid, uuid[]) is
  'Direct prerequisites, in this branch, that Nestra cannot say anything about '
  'yet and that are not already on the path. `emerging` deliberately does not '
  'count as unmet: early evidence is enough to explore what comes next, and '
  'requiring more would turn prerequisites into gates.';

-- The invariants refuse an app function the world can execute, and caught this
-- file the first time it was applied.

revoke all on function app.learning_path_rule_version() from public, anon;
revoke all on function app.path_branch(uuid) from public, anon;
revoke all on function app.path_skill_context(uuid, uuid) from public, anon;
revoke all on function app.path_characterized(uuid, uuid) from public, anon;
revoke all on function app.path_well_characterized(uuid, uuid) from public, anon;
revoke all on function app.path_human_confirmed_secure(uuid, uuid) from public, anon;
revoke all on function app.path_diagnostic_frontier(uuid, uuid) from public, anon;
revoke all on function app.path_named_by_a_person(uuid) from public, anon;
revoke all on function app.path_resource_for(uuid, uuid) from public, anon;
revoke all on function app.path_candidates(uuid, uuid) from public, anon;
revoke all on function app.path_readiness(uuid, uuid) from public, anon;
revoke all on function app.path_unmet_prerequisites(uuid, uuid, uuid, uuid[]) from public, anon;

grant execute on function app.learning_path_rule_version() to authenticated, service_role;
grant execute on function app.path_branch(uuid) to authenticated, service_role;
grant execute on function app.path_skill_context(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_characterized(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_well_characterized(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_human_confirmed_secure(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_diagnostic_frontier(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_named_by_a_person(uuid) to authenticated, service_role;
grant execute on function app.path_resource_for(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_candidates(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_readiness(uuid, uuid) to authenticated, service_role;
grant execute on function app.path_unmet_prerequisites(uuid, uuid, uuid, uuid[]) to authenticated, service_role;

select app.assert_schema_invariants();
