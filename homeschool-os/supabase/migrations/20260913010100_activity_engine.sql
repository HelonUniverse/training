-- =============================================================================
-- 0104  Choosing material: an ORDER BY, and nothing cleverer
-- =============================================================================
-- No model chooses what a child does. This file is a filter and a sort, and
-- that is the point: given the same student, the same skill and the same
-- catalogue, it returns the same resource today, next March and on the managed
-- database, and a parent asking "why this one" gets an answer made of facts
-- rather than an apology for a black box.
--
-- ELIGIBILITY - all four must hold:
--
--   1. a person has CONFIRMED that this material teaches this skill. An
--      unreviewed guess may sit in the catalogue and may be shown to somebody
--      for review; it may never decide what a child receives.
--   2. it can be opened today (availability = 'available'), and its course and
--      provider are still active.
--   3. if the caller explicitly required a language, it satisfies it. Material
--      whose language nobody has stated does NOT satisfy an explicit
--      requirement - "we don't know" is not Spanish.
--   4. nothing else. Not grade, not age, not a standard, not a benchmark.
--
-- ORDERING - §8's list, minus the criteria the data model does not represent:
--
--   1. material the family is actually enrolled in
--   2. parent provider preference       -- NOT REPRESENTED. Skipped, not invented.
--   3. modality, when the caller asked for one explicitly
--   4. kind, as text
--   5. title
--   6. id
--
-- Key 2 is skipped rather than guessed at, the same way Phase 6 skipped it.
-- Key 3 fires only on an EXPLICIT request from the caller: there is no stored
-- "this child is a hands-on learner", because that is a claim about a person
-- that nothing here is entitled to make.
--
-- Key 4 sorts on the TEXT of the kind, not the enum position, so that nobody
-- can read a pedagogical ranking into the order the labels were declared in. A
-- tiebreak is supposed to be arbitrary and stable; it is not supposed to be a
-- quiet opinion about whether a video beats a worksheet.
--
-- AND NO ELIGIBLE RESOURCE IS AN ANSWER. app.activity_select_resource returns a
-- structured `resource_available: false` with what it looked at and what got in
-- the way. It does not widen the filter, walk down the skill graph, reach for an
-- unconfirmed mapping, or touch the path. The model does not bend around the
-- catalogue.
-- =============================================================================

create or replace function app.learning_activity_rule_version()
returns text language sql immutable set search_path = '' as $fn$
  select '2026-09-13.1'::text;
$fn$;

comment on function app.learning_activity_rule_version() is
  'The version of the selection rules. Stamped on every activity the system '
  'selects so that a choice made today stays explainable after the rules change.';

-- --- what could be offered, and in what order --------------------------------
-- One SELECT, so that the ordering is visible in one place and cannot drift
-- between the selector and the explanation.

create or replace function app.learning_activity_candidates(
  p_student  uuid,
  p_skill    uuid,
  p_language app.learning_resource_language default null,
  p_modality app.learning_activity_modality default null)
returns table (
  resource_id           uuid,
  from_active_curriculum boolean,
  modality_matched      boolean,
  kind_text             text,
  title                 text,
  rank                  integer)
language sql stable security invoker set search_path = '' as $fn$
  with eligible as (
    select r.id,
           -- KEY 1. Material this family is already working in comes first:
           -- a child with a maths book should be pointed at the page in the
           -- book she has, not at a stranger's worksheet.
           exists (select 1
                     from public.student_course_enrollments e
                    where e.student_id = p_student
                      and e.course_id = r.course_id
                      and e.status = 'active') as from_active_curriculum,
           -- KEY 3. Only when the caller asked. Never inferred, never stored.
           (p_modality is not null and r.modality = p_modality) as modality_matched,
           r.kind::text as kind_text,
           r.title
      from public.learning_resources r
      join public.resource_skills rs on rs.resource_id = r.id
      left join public.courses c on c.id = r.course_id
      left join public.curriculum_providers pr on pr.id = r.provider_id
     where rs.skill_id = p_skill
       -- (1) a PERSON said this material teaches this skill
       and rs.confirmed
       -- (2) it can be opened, and its home is still live
       and r.availability = 'available'
       and (c.id is null or c.active)
       and (pr.id is null or pr.active)
       -- (3) an explicit language requirement, satisfied honestly
       and (p_language is null
            or r.language = p_language
            or r.language in ('bilingual', 'language_neutral'))
     group by r.id, r.kind, r.title, r.course_id, r.modality
  )
  select e.id, e.from_active_curriculum, e.modality_matched, e.kind_text, e.title,
         (row_number() over (
            order by e.from_active_curriculum desc,
                     e.modality_matched desc,
                     e.kind_text,
                     e.title,
                     e.id))::integer
    from eligible e
   order by e.from_active_curriculum desc, e.modality_matched desc,
            e.kind_text, e.title, e.id;
$fn$;

comment on function app.learning_activity_candidates(uuid, uuid, app.learning_resource_language, app.learning_activity_modality) is
  'Every resource that could honestly be offered for this skill, in the order '
  'the selector uses. Only mappings a person confirmed are here; an AI guess '
  'about what a worksheet teaches never reaches a child through this function.';

-- --- what got in the way, when nothing survived ------------------------------
-- The difference between "there is nothing for this skill" and "there are two
-- things and the subscription lapsed" is the difference between a dead end and
-- a five-minute fix, and a parent deserves to be told which one she is looking
-- at. None of these counts changes what is selected; they are reported.

create or replace function app.learning_activity_supply(p_student uuid, p_skill uuid)
returns jsonb language sql stable security invoker set search_path = '' as $fn$
  select jsonb_build_object(
    'confirmed_mappings',
      count(*) filter (where rs.confirmed),
    'awaiting_confirmation',
      count(*) filter (where not rs.confirmed),
    'blocked_by_availability',
      count(*) filter (where rs.confirmed and r.availability <> 'available'),
    'blocked_by_inactive_home',
      count(*) filter (where rs.confirmed and r.availability = 'available'
                         and ((c.id is not null and not c.active)
                              or (pr.id is not null and not pr.active))))
    from public.resource_skills rs
    join public.learning_resources r on r.id = rs.resource_id
    left join public.courses c on c.id = r.course_id
    left join public.curriculum_providers pr on pr.id = r.provider_id
   where rs.skill_id = p_skill;
$fn$;

comment on function app.learning_activity_supply(uuid, uuid) is
  'What exists for this skill and what is in the way. Reported so a family can '
  'tell a dead end from a lapsed subscription; it never widens eligibility, and '
  'awaiting_confirmation is a review queue, not a source of selections.';

-- --- the selection -----------------------------------------------------------

create or replace function app.learning_activity_select_resource(
  p_student  uuid,
  p_skill    uuid,
  p_language app.learning_resource_language default null,
  p_modality app.learning_activity_modality default null)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare
  v_win record;
  v_tied integer;
  v_total integer;
  v_reasons text[] := '{}';
begin
  select * into v_win
    from app.learning_activity_candidates(p_student, p_skill, p_language, p_modality)
   where rank = 1;

  if not found then
    -- A VALID ANSWER. Not an error, not an empty slot to be filled with
    -- something invented, and above all not a reason to move the child.
    return jsonb_build_object(
      'resource_available', false,
      'skill_id',    p_skill,
      'reason',      'no_eligible_confirmed_resource',
      'considered',  app.learning_activity_supply(p_student, p_skill),
      'rule_version', app.learning_activity_rule_version());
  end if;

  select count(*) into v_total
    from app.learning_activity_candidates(p_student, p_skill, p_language, p_modality);

  -- How many were still level with the winner when the preference keys ran out.
  -- If more than one, the decision came down to the arbitrary-but-stable keys,
  -- and saying so is more honest than implying the material was preferred.
  select count(*) into v_tied
    from app.learning_activity_candidates(p_student, p_skill, p_language, p_modality) c
   where c.from_active_curriculum = v_win.from_active_curriculum
     and c.modality_matched = v_win.modality_matched;

  v_reasons := v_reasons || 'confirmed_skill_match'::text;
  if v_win.from_active_curriculum then
    v_reasons := v_reasons || 'active_curriculum'::text;
  end if;
  if p_modality is not null and v_win.modality_matched then
    v_reasons := v_reasons || 'modality_match'::text;
  end if;
  if p_language is not null then
    v_reasons := v_reasons || 'language_match'::text;
  end if;
  if v_tied > 1 then
    v_reasons := v_reasons || 'deterministic_tiebreak'::text;
  end if;

  return jsonb_build_object(
    'resource_available', true,
    'skill_id',     p_skill,
    'resource_id',  v_win.resource_id,
    'reasons',      to_jsonb(v_reasons),
    'considered',   jsonb_build_object(
                      'eligible', v_total,
                      'level_with_the_chosen_one', v_tied,
                      'supply', app.learning_activity_supply(p_student, p_skill)),
    'requested',    jsonb_build_object(
                      'language', p_language, 'modality', p_modality),
    'rule_version', app.learning_activity_rule_version());
end $fn$;

comment on function app.learning_activity_select_resource(uuid, uuid, app.learning_resource_language, app.learning_activity_modality) is
  'The resource for this skill, or an honest structured nothing. Deterministic: '
  'the same student, skill and catalogue give the same answer every time, and '
  'no model is consulted at any point.';

-- --- what the path says about this node --------------------------------------
-- Two questions the automatic selector must ask before it does anything, and
-- both of them are about respecting a decision somebody already made.

create or replace function app.learning_activity_node_is_actionable(p_node uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select exists (select 1 from public.learning_path_nodes n
                  where n.id = p_node
                    and n.node_kind = 'actionable'
                    and n.status in ('proposed', 'approved'));
$fn$;

comment on function app.learning_activity_node_is_actionable(uuid) is
  'A goal_target is where the family is heading, not a claim the child is ready '
  'for it. Automatic selection runs on actionable nodes only; a parent may still '
  'choose to work on a goal directly, and that is a human action with a human '
  'provenance, not the system deciding she meant it.';

-- --- secure stays secure -----------------------------------------------------
-- A skill a person has confirmed is not quietly reopened because a worksheet
-- exists for it. "Resources are available" is not a reason to reteach a child
-- something she has already shown you she can do.

create or replace function app.learning_activity_revisit_is_invited(
  p_student uuid, p_skill uuid, p_node uuid)
returns boolean language sql stable security invoker set search_path = '' as $fn$
  select not app.path_human_confirmed_secure(p_student, p_skill)
      or exists (select 1 from public.learning_path_nodes n
                  where n.id = p_node
                    and n.status <> 'removed'
                    and (n.reason_code in ('revisit_requested', 'parent_goal', 'human_added')
                         or n.added_by_human));
$fn$;

comment on function app.learning_activity_revisit_is_invited(uuid, uuid, uuid) is
  'True unless this would be automatic reteaching of something a person already '
  'confirmed. An explicit revisit, a parent goal or a node she added herself is '
  'an invitation; the mere existence of material is not.';

-- --- what the material was, at the moment it was attached ---------------------
-- A provider can retitle a lesson, let a subscription lapse, or withdraw
-- content entirely. None of that may make "why was my daughter doing this in
-- March" unanswerable, so the answer is frozen when the activity is made rather
-- than reconstructed later from a row that has moved on.

create or replace function app.learning_activity_resource_snapshot(p_resource uuid)
returns jsonb language sql stable security invoker set search_path = '' as $fn$
  select case when p_resource is null then '{}'::jsonb else
    coalesce((select jsonb_build_object(
      'resource_id',       r.id,
      'title',             r.title,
      'kind',              r.kind,
      'activity_kind',     r.activity_kind,
      'modality',          r.modality,
      'language',          r.language,
      'availability',      r.availability,
      'content_ownership', r.content_ownership,
      'integration_mode',  r.integration_mode,
      'license_note',      r.license_note,
      'is_demo',           r.is_demo,
      'external_url',      r.external_url,
      'provider_id',       r.provider_id,
      'provider_name',     pr.name,
      'provider_is_first_party', pr.is_first_party,
      'course_id',         r.course_id,
      'captured_at',       now())
      from public.learning_resources r
      left join public.curriculum_providers pr on pr.id = r.provider_id
     where r.id = p_resource), '{}'::jsonb) end;
$fn$;

comment on function app.learning_activity_resource_snapshot(uuid) is
  'The material as it was when it was attached, frozen. The live row is still '
  'joined for anything current; this is the historical account, and it is the '
  'only one that survives a provider renaming or withdrawing its content.';

-- =============================================================================
-- The lifecycle graph
-- =============================================================================
-- Flexible where a homeschool week is flexible, and firm where the record has
-- to stay true. A morning that was put off can be picked back up; a morning
-- that happened cannot be un-happened.
--
--   proposed   -> selected available skipped not_today replaced archived
--   selected   -> available started skipped not_today replaced archived
--   available  -> selected started skipped not_today replaced archived
--   started    -> completed skipped not_today replaced archived
--   not_today  -> selected available started replaced archived
--   skipped    -> selected available started replaced archived
--   completed  -> archived
--   replaced   -> (nothing)
--   archived   -> (nothing)
--
-- `completed` is terminal but for archiving, and that is the whole point of
-- having a graph at all. "Do it again" is a NEW activity with lineage, not an
-- edit that quietly removes a morning from the record. A family that can
-- rewrite what already happened does not have a record; it has a draft.
--
-- `skipped` and `not_today` reopen freely, because they are not verdicts. A
-- week that went sideways on Tuesday and came back on Thursday is an ordinary
-- week, and a lifecycle that made her create a second row to say so would be
-- teaching her to work around it.

create or replace function app.learning_activity_next_states(
  p_from app.learning_activity_status)
returns app.learning_activity_status[] language sql immutable set search_path = '' as $fn$
  select (case p_from
    when 'proposed'  then array['selected','available','skipped','not_today','replaced','archived']
    when 'selected'  then array['available','started','skipped','not_today','replaced','archived']
    when 'available' then array['selected','started','skipped','not_today','replaced','archived']
    when 'started'   then array['completed','skipped','not_today','replaced','archived']
    when 'not_today' then array['selected','available','started','replaced','archived']
    when 'skipped'   then array['selected','available','started','replaced','archived']
    when 'completed' then array['archived']
    else array[]::text[]
  end)::app.learning_activity_status[];
$fn$;

create or replace function app.learning_activity_transition_allowed(
  p_from app.learning_activity_status, p_to app.learning_activity_status)
returns boolean language sql immutable set search_path = '' as $fn$
  select p_from = p_to
      or p_to = any(app.learning_activity_next_states(p_from));
$fn$;

-- A stable code rather than a sentence, for the same reason the selection
-- reasons are codes: a screen renders it in the family's language, and a
-- refusal a caller cannot branch on is an opaque error with extra steps.
create or replace function app.learning_activity_transition_refusal(
  p_from app.learning_activity_status, p_to app.learning_activity_status)
returns text language sql immutable set search_path = '' as $fn$
  select case
    when app.learning_activity_transition_allowed(p_from, p_to) then null
    when p_from = 'completed' then 'a_completed_activity_is_not_undone'
    when p_from = 'replaced'  then 'a_replaced_activity_stays_replaced'
    when p_from = 'archived'  then 'an_archived_activity_stays_archived'
    else 'not_a_step_this_activity_can_take_from_here'
  end;
$fn$;

comment on function app.learning_activity_transition_refusal(app.learning_activity_status, app.learning_activity_status) is
  'Why a transition is refused, as a code a screen can render. "Do it again" '
  'after a completion is a new activity with lineage, never an edit that '
  'removes a morning that happened from the record.';

revoke all on function app.learning_activity_rule_version() from public, anon;
revoke all on function app.learning_activity_candidates(uuid, uuid, app.learning_resource_language, app.learning_activity_modality) from public, anon;
revoke all on function app.learning_activity_supply(uuid, uuid) from public, anon;
revoke all on function app.learning_activity_select_resource(uuid, uuid, app.learning_resource_language, app.learning_activity_modality) from public, anon;
revoke all on function app.learning_activity_node_is_actionable(uuid) from public, anon;
revoke all on function app.learning_activity_revisit_is_invited(uuid, uuid, uuid) from public, anon;
revoke all on function app.learning_activity_resource_snapshot(uuid) from public, anon;
revoke all on function app.learning_activity_next_states(app.learning_activity_status) from public, anon;
revoke all on function app.learning_activity_transition_allowed(app.learning_activity_status, app.learning_activity_status) from public, anon;
revoke all on function app.learning_activity_transition_refusal(app.learning_activity_status, app.learning_activity_status) from public, anon;

grant execute on function app.learning_activity_rule_version() to authenticated, service_role;
grant execute on function app.learning_activity_candidates(uuid, uuid, app.learning_resource_language, app.learning_activity_modality) to authenticated, service_role;
grant execute on function app.learning_activity_supply(uuid, uuid) to authenticated, service_role;
grant execute on function app.learning_activity_select_resource(uuid, uuid, app.learning_resource_language, app.learning_activity_modality) to authenticated, service_role;
grant execute on function app.learning_activity_node_is_actionable(uuid) to authenticated, service_role;
grant execute on function app.learning_activity_revisit_is_invited(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function app.learning_activity_resource_snapshot(uuid) to authenticated, service_role;
grant execute on function app.learning_activity_next_states(app.learning_activity_status) to authenticated, service_role;
grant execute on function app.learning_activity_transition_allowed(app.learning_activity_status, app.learning_activity_status) to authenticated, service_role;
grant execute on function app.learning_activity_transition_refusal(app.learning_activity_status, app.learning_activity_status) to authenticated, service_role;

select app.assert_schema_invariants();
