-- =============================================================================
-- 0111  Today is a reading of the record, not another copy of it
-- =============================================================================
-- The failure this file exists to avoid is specific and extremely common: a
-- product grows a "daily plan" table beside its learning plan, the two disagree
-- within a year, and nobody can say which one is true. So Today has no table of
-- its own. It is a SELECT over the learning path, the activities and the
-- handful of explicit decisions a person made about today, and if those records
-- change, Today changes with them because there is nothing else for it to be.
--
-- WHAT TODAY IS NOT. Not a timetable, not a checklist a family owes, not a
-- pacing system, and not a screen that tells a mother what her daughter has not
-- done. There is no due date in this file, nothing is late, and the word
-- `overdue` does not appear because there is no concept for it to name.
--
-- THE ORDER, and every key is a fact somebody stated:
--
--   1. she pinned it for today
--   2. it is already open - finish what was started before starting more
--   3. it is a step on the path she approved, in the order she approved
--   4. she chose it or wrote it herself
--   5. somebody asked to come back to this skill
--   6. then the activity's own creation time, then its id
--
-- Grade, age, pacing and standards are absent, and 0112 refuses them coming
-- back. A child who is nine and a child who is fourteen with the same evidence
-- and the same approved path get the same Today.
-- =============================================================================

create or replace function app.today_rule_version()
returns text language sql immutable set search_path = '' as $fn$
  select '2026-09-15.1'::text;
$fn$;

-- --- the derivation ----------------------------------------------------------
-- One query, so the ordering is visible in one place and cannot drift between
-- the list and the explanation of the list.

create or replace function app.today_items(
  p_student uuid,
  p_on      date default current_date)
returns table (
  activity_id   uuid,
  reason        app.today_reason,
  reason_rank   integer,
  pinned        boolean,
  open_session  uuid,
  path_position integer,
  ord           integer)
language sql stable security invoker set search_path = '' as $fn$
  with
  -- what a person said about today
  decided as (
    select d.activity_id, d.kind
      from public.today_decisions d
     where d.student_id = p_student and d.on_date = p_on
  ),
  -- everything live for this child. `not_today` is out for today by definition
  -- and comes back tomorrow, which is the whole point of the label.
  live as (
    select a.id, a.created_at, a.origin, a.skill_id, a.path_node_id, a.status
      from public.learning_activities a
     where a.student_id = p_student
       and a.status in ('proposed', 'selected', 'available', 'started')
  ),
  sess as (
    select s.activity_id, s.id as session_id
      from public.learning_activity_sessions s
     where s.student_id = p_student
       and s.status in ('in_progress', 'paused')
  ),
  -- a step on a path a person actually approved, in the order she approved
  on_path as (
    select n.id as node_id, n.position
      from public.learning_path_nodes n
      join public.learning_paths lp on lp.id = n.path_id
     where n.student_id = p_student
       and n.node_kind = 'actionable'          -- a goal is not this week's work
       and n.status in ('proposed', 'approved')
       and lp.status in ('approved', 'paused')
  ),
  -- somebody asked to come back to this skill
  revisit as (
    select distinct d.skill_id
      from public.student_skill_refresh_decisions d
     where d.student_id = p_student
       and d.kind = 'revisit_requested'
  ),
  scored as (
    select l.id,
           (select dd.kind from decided dd where dd.activity_id = l.id) as decision,
           (select s.session_id from sess s where s.activity_id = l.id) as session_id,
           p.position as path_position,
           exists (select 1 from revisit r where r.skill_id = l.skill_id) as is_revisit,
           l.origin, l.created_at
      from live l
      left join on_path p on p.node_id = l.path_node_id
  ),
  classified as (
    select s.id,
           coalesce(s.decision = 'pinned_for_today', false) as pinned,
           s.session_id,
           s.path_position,
           s.created_at,
           case
             when s.session_id is not null      then 'continuing_something_started'
             when s.decision = 'chosen_for_today' then 'parent_chose_it'
             when s.path_position is not null   then 'approved_learning_path'
             when s.origin = 'human_created'    then 'parent_created_it'
             when s.origin = 'human_selected'   then 'parent_chose_it'
             when s.is_revisit                  then 'revisit_requested'
             else null
           end::app.today_reason as reason,
           s.decision
      from scored s
  )
  select c.id, c.reason,
         (case c.reason
            when 'continuing_something_started' then 2
            when 'approved_learning_path'       then 3
            when 'parent_chose_it'              then 4
            when 'parent_created_it'            then 4
            when 'revisit_requested'            then 5
          end)::integer as reason_rank,
         c.pinned, c.session_id, c.path_position,
         (row_number() over (
            order by c.pinned desc,
                     (case c.reason
                        when 'continuing_something_started' then 2
                        when 'approved_learning_path'       then 3
                        when 'parent_chose_it'              then 4
                        when 'parent_created_it'            then 4
                        when 'revisit_requested'            then 5
                      end),
                     coalesce(c.path_position, 2147483647),
                     c.created_at,
                     c.id))::integer as ord
    from classified c
   -- an item nobody can give a reason for is not shown. "It exists" is not a
   -- reason to put something in front of a child.
   where c.reason is not null
     -- and not today means not today
     and (c.decision is distinct from 'hidden_for_today')
   order by ord;
$fn$;

comment on function app.today_items(uuid, date) is
  'Today, derived from the learning path, the activities and what a person '
  'decided about today. There is no Today table and no due date: nothing here '
  'is late, nothing is owed, and an item with no factual reason to be shown is '
  'not shown.';

-- --- how a resource is actually opened ---------------------------------------
-- Honest by construction. An external link is called an external link, and
-- `provider_integrated` is reachable only where a provider genuinely reports a
-- live integration - which, in this product, today, nothing does.

create or replace function app.learning_activity_launch(p_activity uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_activities; r public.learning_resources; v_kind app.resource_launch_kind;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found then
    return jsonb_build_object('launch_kind', 'no_digital_resource');
  end if;

  if v.resource_id is null then
    -- A complete activity with nothing to open. Measuring cups are not a
    -- degraded worksheet.
    return jsonb_build_object(
      'launch_kind', 'no_digital_resource',
      'opens', null,
      'parent_instructions', v.parent_instructions,
      'child_instructions', v.child_instructions,
      'note', 'Nothing to open - this one happens away from a screen.');
  end if;

  select * into r from public.learning_resources lr where lr.id = v.resource_id;

  v_kind := case
    when r.integration_mode = 'integrated' then 'provider_integrated'
    when r.external_url is null            then 'offline'
    when r.content_ownership = 'nestra_owned' and r.external_url is null then 'nestra_hosted'
    else 'external_link'
  end::app.resource_launch_kind;

  return jsonb_build_object(
    'launch_kind', v_kind,
    'opens', r.external_url,
    'title', r.title,
    'availability', r.availability,
    'openable_now', r.availability = 'available',
    'content_ownership', r.content_ownership,
    'license_note', r.license_note,
    'is_demo', r.is_demo,
    'provider_id', r.provider_id,
    'parent_instructions', v.parent_instructions,
    'child_instructions', v.child_instructions,
    'note', case v_kind
      when 'external_link' then
        'This opens the provider''s own page. Nestra links to it; it is not '
        || 'part of Nestra and Nestra does not track what happens there.'
      when 'provider_integrated' then 'A live integration with this provider.'
      when 'offline' then 'This one happens away from a screen.'
      else 'Material Nestra owns and serves.' end);
end $fn$;

comment on function app.learning_activity_launch(uuid) is
  'How this activity is actually opened, said plainly. An external link is '
  'described as a link to somebody else''s page, because that is what it is; '
  'Nestra does not claim an integration it does not have, and an activity with '
  'no resource is a complete activity rather than a broken one.';

-- --- what the child sees -----------------------------------------------------
-- Deliberately free of the vocabulary this schema uses about itself. A child
-- does not need to know what evidence sufficiency is, what a diagnostic
-- frontier is, or what `human_confirmed_system_observation` means in order to
-- do some fractions with measuring cups.

create or replace function app.today_card(p_activity uuid, p_reason app.today_reason,
                                          p_session uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_activities; k record; s public.learning_activity_sessions;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  select sk.name, sk.code into k from public.skills sk where sk.id = v.skill_id;
  if p_session is not null then
    select * into s from public.learning_activity_sessions x where x.id = p_session;
  end if;

  return jsonb_build_object(
    'activity_id',       v.id,
    'title',             v.title,
    'skill',             jsonb_build_object('id', v.skill_id, 'name', k.name),
    'instructions',      v.child_instructions,
    'parent_instructions', v.parent_instructions,
    'activity_kind',     v.activity_kind,
    'modality',          v.modality,
    'language',          v.language,
    'about_minutes',     v.estimated_minutes,
    'status',            v.status,
    'why',               p_reason,
    'chosen_by_a_person', v.origin in ('human_selected', 'human_created'),
    'open_session',      p_session,
    'session_status',    s.status,
    'launch',            app.learning_activity_launch(v.id),
    -- said in the payload so that no screen has to remember it
    'finishing_this_is_not_a_test', true);
end $fn$;

comment on function app.today_card(uuid, app.today_reason, uuid) is
  'One Today item as a child meets it. Carries no standards code, no evidence '
  'sufficiency and no provenance vocabulary: a nine-year-old should not have to '
  'understand this schema to do some fractions with measuring cups.';

revoke all on function app.today_rule_version() from public, anon;
revoke all on function app.today_items(uuid, date) from public, anon;
revoke all on function app.learning_activity_launch(uuid) from public, anon;
revoke all on function app.today_card(uuid, app.today_reason, uuid) from public, anon;

grant execute on function app.today_rule_version() to authenticated, service_role;
grant execute on function app.today_items(uuid, date) to authenticated, service_role;
grant execute on function app.learning_activity_launch(uuid) to authenticated, service_role;
grant execute on function app.today_card(uuid, app.today_reason, uuid) to authenticated, service_role;

select app.assert_schema_invariants();
