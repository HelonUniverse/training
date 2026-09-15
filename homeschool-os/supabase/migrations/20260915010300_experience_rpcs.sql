-- =============================================================================
-- 0112  The calls a family makes on a Tuesday morning
-- =============================================================================
-- A child presses start. She works for a while. The baby wakes up. She comes
-- back on Thursday and finishes, and her mother takes a photo of the page.
-- Everything in this file exists to record that sequence truthfully.
--
-- THE SENTENCE EVERY RETURN VALUE CARRIES: nothing here has changed what Nestra
-- believes about the child. Not starting, not finishing, not the photo, not the
-- note. It is in the payload on purpose, so a screen built against these
-- functions is handed the honest wording instead of having to remember it.
--
-- AND THE ONE PLACE THE LINE COULD BE CROSSED is accept_evidence_proposal,
-- which is deliberately the only function here that touches anything outside
-- this phase. It calls public.confirm_skill_evidence - the STEP 5 function that
-- has always recorded "this work RELATES to this skill" - and stops. It does
-- not write student_skills. It does not write student_skill_events. Whether the
-- child has actually learned something is still a separate judgement a person
-- makes through the path that already existed, and 0113 refuses any code here
-- that tries to shortcut it.
-- =============================================================================

-- --- Today -------------------------------------------------------------------

create or replace function public.today(
  p_student uuid,
  p_on      date default current_date)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare r record; v jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not app.can_student_action(p_student, 'learning_activity', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  for r in select * from app.today_items(p_student, p_on) order by ord loop
    v := v || (app.today_card(r.activity_id, r.reason, r.open_session)
               || jsonb_build_object('pinned', r.pinned, 'position', r.ord));
  end loop;

  return jsonb_build_object(
    'student', p_student,
    'on', p_on,
    'items', v,
    'count', jsonb_array_length(v),
    'rule_version', app.today_rule_version(),
    -- Said out loud, in the payload, because the whole risk of a screen called
    -- Today is that it starts feeling like a register.
    'is_a_checklist', false,
    'anything_overdue', false,
    'membership_is_evidence', false,
    'note', case when jsonb_array_length(v) = 0
      then 'Nothing waiting. That is a perfectly ordinary day.'
      else 'Some things you could work on. None of it is owed, and you can '
           || 'choose something different whenever you like.' end);
end $fn$;

comment on function public.today(uuid, date) is
  'What this child could work on today, derived from the path and the '
  'activities. Not a timetable and not a checklist: nothing in it is late, '
  'nothing is owed, and being in Today is never evidence about anybody.';

create or replace function public.explain_today_item(p_activity uuid, p_on date default current_date)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_activities; r record; k record;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  select * into r from app.today_items(v.student_id, p_on) t where t.activity_id = p_activity;
  select sk.name, sk.code into k from public.skills sk where sk.id = v.skill_id;

  return jsonb_build_object(
    'activity_id', p_activity,
    'in_today', r.activity_id is not null,
    'why', r.reason,
    'pinned', coalesce(r.pinned, false),
    'position', r.ord,
    'path_position', r.path_position,
    'continuing_session', r.open_session,
    'skill', jsonb_build_object('id', v.skill_id, 'name', k.name),
    'activity_origin', v.origin,
    'chosen_by_a_person', v.origin in ('human_selected', 'human_created'),
    'rule_version', app.today_rule_version(),
    'standards_consulted', false,
    'grade_or_age_consulted', false,
    'membership_is_evidence', false);
end $fn$;

-- --- what a person decided about today ---------------------------------------

create or replace function app.today_decide(
  p_activity uuid, p_kind app.today_decision_kind, p_note text, p_on date)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; v_id uuid; v_event app.learning_activity_event_kind;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  insert into public.today_decisions (student_id, activity_id, on_date, kind, note, decided_by)
  values (v.student_id, p_activity, coalesce(p_on, current_date), p_kind, p_note, auth.uid())
  on conflict (student_id, activity_id, on_date)
    do update set kind = excluded.kind, note = excluded.note,
                  decided_by = excluded.decided_by, created_at = now()
  returning id into v_id;

  v_event := case p_kind when 'hidden_for_today' then 'today_hidden'
                         else 'today_pinned' end::app.learning_activity_event_kind;
  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, note, actor)
  values (p_activity, v.student_id, v_event, v.skill_id, p_note, auth.uid());

  return jsonb_build_object(
    'decision_id', v_id, 'activity_id', p_activity, 'kind', p_kind,
    'on', coalesce(p_on, current_date),
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'A decision about one day. It changes nothing about your child and '
            || 'it is not a mark against anybody.');
end $fn$;

create or replace function public.pin_for_today(p_activity uuid, p_note text default null,
                                                p_on date default current_date)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.today_decide(p_activity, 'pinned_for_today', p_note, p_on);
$fn$;

create or replace function public.hide_for_today(p_activity uuid, p_note text default null,
                                                 p_on date default current_date)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.today_decide(p_activity, 'hidden_for_today', p_note, p_on);
$fn$;

create or replace function public.choose_for_today(p_activity uuid, p_note text default null,
                                                   p_on date default current_date)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app.today_decide(p_activity, 'chosen_for_today', p_note, p_on);
$fn$;

create or replace function public.clear_today_decision(p_activity uuid,
                                                       p_on date default current_date)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; v_n int;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  delete from public.today_decisions d
   where d.activity_id = p_activity and d.on_date = coalesce(p_on, current_date);
  get diagnostics v_n = row_count;
  return jsonb_build_object('activity_id', p_activity, 'cleared', v_n,
                            'evidence_created', false, 'skill_state_changed', false);
end $fn$;

-- =============================================================================
-- Sessions: one occasion
-- =============================================================================

create or replace function public.start_learning_session(
  p_activity uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; v_open public.learning_activity_sessions; v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  -- Already going. Handing back the open one is what "Continue" means, and it
  -- is what makes reopening the screen safe.
  select * into v_open from public.learning_activity_sessions s
   where s.activity_id = p_activity and s.status in ('in_progress', 'paused') limit 1;
  if found then
    if v_open.status = 'paused' then
      update public.learning_activity_sessions s set status = 'in_progress'
       where s.id = v_open.id;
      insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, actor)
      values (p_activity, v.student_id, 'session_resumed', v.skill_id, auth.uid());
      return jsonb_build_object('session_id', v_open.id, 'status', 'in_progress',
        'resumed', true, 'evidence_created', false, 'skill_state_changed', false,
        'note', 'Picking up where you left off.');
    end if;
    return jsonb_build_object('session_id', v_open.id, 'status', v_open.status,
      'already_open', true, 'evidence_created', false, 'skill_state_changed', false,
      'note', 'This one is already open.');
  end if;

  insert into public.learning_activity_sessions (
      activity_id, student_id, initiated_by, child_note, rule_version)
  values (p_activity, v.student_id, auth.uid(), p_note, app.today_rule_version())
  returning id into v_id;

  -- The activity follows the session into `started`, where the Phase 1 graph
  -- allows it. Where it does not - a proposal that was never selected - the
  -- session still stands on its own, because what happened happened.
  if app.learning_activity_transition_allowed(v.status, 'started') then
    update public.learning_activities a
       set status = 'started', started_at = coalesce(a.started_at, now())
     where a.id = p_activity;
  end if;

  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (p_activity, v.student_id, 'session_started', v.skill_id, p_note, auth.uid());

  return jsonb_build_object(
    'session_id', v_id, 'activity_id', p_activity, 'status', 'in_progress',
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'Started. Nothing about your child has changed by starting.');
end $fn$;

create or replace function public.pause_learning_session(
  p_session uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare s public.learning_activity_sessions; v_skill uuid;
begin
  select * into s from public.learning_activity_sessions x where x.id = p_session;
  if not found or not app.can_student_action(s.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if s.status <> 'in_progress' then
    return jsonb_build_object('session_id', p_session, 'paused', false,
      'status', s.status, 'reason', 'this_session_is_not_running',
      'evidence_created', false, 'skill_state_changed', false);
  end if;
  update public.learning_activity_sessions x
     set status = 'paused', child_note = coalesce(p_note, x.child_note)
   where x.id = p_session;
  select a.skill_id into v_skill from public.learning_activities a where a.id = s.activity_id;
  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (s.activity_id, s.student_id, 'session_paused', v_skill, p_note, auth.uid());
  return jsonb_build_object('session_id', p_session, 'paused', true, 'status', 'paused',
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'Set down for now. Come back to it whenever you like.');
end $fn$;

-- ENDING A SESSION. The one parameter that matters is the outcome, and the list
-- it comes from contains no failure. `p_minutes` is passed in or left null: it
-- is never derived from the clock, because a session left open overnight did
-- not take fourteen hours and writing that down would be a false number in a
-- record a family may one day hand to an evaluator.
create or replace function public.end_learning_session(
  p_session  uuid,
  p_outcome  app.learning_session_outcome default 'completed',
  p_minutes  integer default null,
  p_child_note text default null,
  p_educator_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare s public.learning_activity_sessions; v public.learning_activities;
begin
  select * into s from public.learning_activity_sessions x where x.id = p_session;
  if not found or not app.can_student_action(s.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if s.status = 'ended' then
    return jsonb_build_object('session_id', p_session, 'ended', false,
      'reason', 'this_occasion_is_already_on_the_record',
      'note', 'That morning is already written down. Doing it again is a new '
              || 'session, not an edit to this one.',
      'evidence_created', false, 'skill_state_changed', false);
  end if;

  update public.learning_activity_sessions x
     set status = 'ended', ended_at = now(), ended_by = auth.uid(),
         outcome = p_outcome,
         duration_minutes = coalesce(p_minutes, x.duration_minutes),
         child_note = coalesce(p_child_note, x.child_note),
         educator_note = coalesce(p_educator_note, x.educator_note)
   where x.id = p_session;

  select * into v from public.learning_activities a where a.id = s.activity_id;
  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (s.activity_id, s.student_id, 'session_ended', v.skill_id,
          coalesce(p_child_note, p_educator_note), auth.uid());

  -- The ACTIVITY is only marked completed when the occasion actually completed
  -- it, and only where the Phase 1 graph allows. Exploring for ten minutes does
  -- not finish a worksheet, and saying it did would be the record lying.
  if p_outcome = 'completed'
     and app.learning_activity_transition_allowed(v.status, 'completed') then
    perform public.complete_activity(s.activity_id, 'session ' || p_session::text);
  end if;

  return jsonb_build_object(
    'session_id', p_session, 'ended', true, 'outcome', p_outcome,
    'duration_minutes', coalesce(p_minutes, s.duration_minutes),
    'duration_was_measured', coalesce(p_minutes, s.duration_minutes) is not null,
    'activity_id', s.activity_id,
    'evidence_created', false,
    'skill_state_changed', false,
    'mastery_implied', false,
    'failure_implied', false,
    'note', 'That is written down as what happened. It says nothing about what '
            || 'your child has learned - if you want to record evidence, that is '
            || 'a separate thing you choose to do.');
end $fn$;

comment on function public.end_learning_session(uuid, app.learning_session_outcome, integer, text, text) is
  'Records how one occasion went. `completed` means the session finished, never '
  'that anything was mastered; no outcome in the list is a failure; and the '
  'duration is only what somebody reported, never derived from the clock.';

create or replace function public.add_session_note(
  p_session uuid, p_child_note text default null, p_educator_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare s public.learning_activity_sessions; v_skill uuid;
begin
  select * into s from public.learning_activity_sessions x where x.id = p_session;
  if not found or not app.can_student_action(s.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  update public.learning_activity_sessions x
     set child_note = coalesce(p_child_note, x.child_note),
         educator_note = coalesce(p_educator_note, x.educator_note)
   where x.id = p_session;
  select a.skill_id into v_skill from public.learning_activities a where a.id = s.activity_id;
  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (s.activity_id, s.student_id, 'note_added', v_skill,
          coalesce(p_child_note, p_educator_note), auth.uid());
  return jsonb_build_object('session_id', p_session, 'noted', true,
    'evidence_created', false, 'skill_state_changed', false, 'mastery_implied', false,
    'note', 'Noted. A note is a note - nothing about the profile changes, and '
            || 'nothing reads it to decide what your child knows.');
end $fn$;

-- --- opening the material ----------------------------------------------------
-- Recorded because a family may want to know what was opened and when. It is
-- not progress, it is not evidence, and a provider's page telling Nestra
-- nothing afterwards is the normal case rather than a failure.

create or replace function public.open_activity_resource(p_activity uuid, p_session uuid default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; j jsonb;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  j := app.learning_activity_launch(p_activity);

  if app.can_student_action(v.student_id, 'learning_activity', 'update') then
    insert into public.learning_activity_events (
        activity_id, student_id, kind, skill_id, from_resource_id, detail, actor)
    values (p_activity, v.student_id, 'resource_opened', v.skill_id, v.resource_id, j, auth.uid());
  end if;

  -- A SEPARATE KEY, deliberately. jsonb `||` lets the right-hand side win, so
  -- adding another `note` here would have silently overwritten the launch
  -- description - the sentence that tells a family whose page they are about to
  -- open. Found by the test that asserts that sentence survives.
  return j || jsonb_build_object(
    'session_id', p_session,
    'evidence_created', false, 'skill_state_changed', false, 'mastery_implied', false,
    'evidence_note', 'Opening something is not progress and not evidence. What '
            || 'happens on somebody else''s page stays on somebody else''s page.');
end $fn$;

-- =============================================================================
-- Artifacts
-- =============================================================================
-- Points at a document or a portfolio item that already exists, through the
-- storage, scanning and sharing machinery that has protected a child's work
-- since STEP 2. Nothing is stored here.

create or replace function public.attach_activity_artifact(
  p_activity  uuid,
  p_document  uuid default null,
  p_portfolio uuid default null,
  p_session   uuid default null,
  p_note      text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if p_document is null and p_portfolio is null then
    raise exception 'an artifact has to point at a document or a portfolio item'
      using errcode = 'check_violation';
  end if;

  insert into public.learning_activity_artifacts (
      activity_id, session_id, student_id, document_id, portfolio_item_id, note, added_by)
  values (p_activity, p_session, v.student_id, p_document, p_portfolio, p_note, auth.uid())
  returning id into v_id;

  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (p_activity, v.student_id, 'artifact_added', v.skill_id, p_note, auth.uid());

  return jsonb_build_object(
    'artifact_id', v_id, 'activity_id', p_activity,
    'document_id', p_document, 'portfolio_item_id', p_portfolio,
    'evidence_created', false, 'skill_state_changed', false, 'mastery_implied', false,
    'note', 'Kept with the activity. Attaching a photo is not the same as '
            || 'saying it shows your child can do something - if you want to '
            || 'record that, you can, separately.');
end $fn$;

-- =============================================================================
-- The evidence offer
-- =============================================================================

create or replace function public.offer_activity_evidence(
  p_activity uuid,
  p_skill    uuid default null,
  p_session  uuid default null,
  p_artifact uuid default null,
  p_reason   text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v public.learning_activities; v_skill uuid; v_id uuid; v_open uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  -- The skill the ACTIVITY was for. Offering evidence against some other skill
  -- would be Nestra deciding what a piece of work shows, which is the thing a
  -- person is being asked.
  v_skill := coalesce(p_skill, v.skill_id);

  select id into v_open from public.learning_evidence_proposals p
   where p.activity_id = p_activity and p.skill_id = v_skill and p.status = 'offered';
  if found then
    return jsonb_build_object('proposal_id', v_open, 'offered', false,
      'reason', 'already_asked', 'evidence_created', false,
      'note', 'Already asked. Nothing has been decided.');
  end if;

  insert into public.learning_evidence_proposals (
      activity_id, session_id, artifact_id, student_id, skill_id, offered_reason)
  values (p_activity, p_session, p_artifact, v.student_id, v_skill, p_reason)
  returning id into v_id;

  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (p_activity, v.student_id, 'evidence_offered', v_skill, p_reason, auth.uid());

  return jsonb_build_object(
    'proposal_id', v_id, 'offered', true, 'status', 'offered',
    'skill_id', v_skill, 'activity_id', p_activity,
    'evidence_created', false, 'skill_state_changed', false,
    'is_a_question_not_a_record', true,
    'note', 'Would you like to keep this as evidence? Saying no is a perfectly '
            || 'good answer, and nothing has been recorded either way.');
end $fn$;

comment on function public.offer_activity_evidence(uuid, uuid, uuid, uuid, text) is
  'Asks whether work from this activity is worth keeping as evidence. An offer '
  'is a question, not a record: it creates no evidence, touches no profile, and '
  'is answered by a person or left alone.';

-- ACCEPTING. The only function in this phase that reaches outside it, and it
-- reaches exactly one place: the STEP 5 function that records "this work
-- RELATES to this skill". It does not write student_skills, it does not write
-- student_skill_events, and 0113 refuses it ever doing so.
create or replace function public.accept_evidence_proposal(
  p_proposal uuid,
  p_relation text default 'demonstrates',
  p_note     text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare p public.learning_evidence_proposals; a public.learning_activity_artifacts;
        v_evidence uuid; v_doc uuid; v_item uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into p from public.learning_evidence_proposals x where x.id = p_proposal;
  -- Deciding that work counts as evidence about a child is an `approve`, not an
  -- edit. A tutor may run the week; only a guardian with full access decides
  -- what enters the family's evidence record.
  if not found or not app.can_student_action(p.student_id, 'learning_activity', 'approve') then
    raise exception 'recording evidence about a child is a decision this account is not authorized to make'
      using errcode = 'insufficient_privilege';
  end if;
  if p.status <> 'offered' then
    return jsonb_build_object('proposal_id', p_proposal, 'accepted', false,
      'reason', 'already_answered', 'status', p.status,
      'evidence_created', false, 'skill_state_changed', false);
  end if;

  if p.artifact_id is not null then
    select * into a from public.learning_activity_artifacts x where x.id = p.artifact_id;
    v_doc := a.document_id; v_item := a.portfolio_item_id;
  end if;

  -- THE EXISTING ARCHITECTURE, called rather than reimplemented.
  v_evidence := public.confirm_skill_evidence(
    p.student_id, p.skill_id, coalesce(p_relation, 'demonstrates'),
    v_item, v_doc, null, current_date,
    coalesce(p_note, 'From a learning activity'));

  update public.learning_evidence_proposals x
     set status = 'accepted', decided_by = auth.uid(), decided_at = now(),
         learning_evidence_id = v_evidence
   where x.id = p_proposal;

  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (p.activity_id, p.student_id, 'evidence_accepted', p.skill_id, p_note, auth.uid());

  return jsonb_build_object(
    'proposal_id', p_proposal, 'accepted', true,
    'learning_evidence_id', v_evidence,
    'skill_id', p.skill_id,
    -- The distinction this whole phase is built around, stated in the payload.
    'evidence_recorded', true,
    'skill_state_changed', false,
    'mastery_implied', false,
    'profile_updated', false,
    'note', 'Kept as evidence that this work relates to that skill. It is not a '
            || 'statement that your child has learned it - what her profile says '
            || 'is still yours to decide, separately.');
end $fn$;

create or replace function public.decline_evidence_proposal(
  p_proposal uuid, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare p public.learning_evidence_proposals;
begin
  select * into p from public.learning_evidence_proposals x where x.id = p_proposal;
  if not found or not app.can_student_action(p.student_id, 'learning_activity', 'approve') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if p.status <> 'offered' then
    return jsonb_build_object('proposal_id', p_proposal, 'declined', false,
      'reason', 'already_answered', 'status', p.status);
  end if;
  update public.learning_evidence_proposals x
     set status = 'declined', decided_by = auth.uid(), decided_at = now(),
         decline_note = p_note
   where x.id = p_proposal;
  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (p.activity_id, p.student_id, 'evidence_declined', p.skill_id, p_note, auth.uid());
  return jsonb_build_object('proposal_id', p_proposal, 'declined', true,
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'Not kept. "That was just practice" is a perfectly good answer, and '
            || 'nothing about your child has changed.');
end $fn$;

-- =============================================================================
-- The whole story of one activity
-- =============================================================================

create or replace function public.activity_history(p_activity uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $fn$
declare v public.learning_activities;
begin
  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'read') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  return jsonb_build_object(
    'activity', public.explain_activity(p_activity),
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object(
        'session_id', s.id, 'started_at', s.started_at, 'ended_at', s.ended_at,
        'status', s.status, 'outcome', s.outcome,
        'duration_minutes', s.duration_minutes,
        'duration_was_measured', s.duration_minutes is not null,
        'initiated_by', s.initiated_by, 'ended_by', s.ended_by,
        'child_note', s.child_note, 'educator_note', s.educator_note)
        order by s.started_at), '[]'::jsonb)
      from public.learning_activity_sessions s where s.activity_id = p_activity),
    'artifacts', (select coalesce(jsonb_agg(jsonb_build_object(
        'artifact_id', ar.id, 'document_id', ar.document_id,
        'portfolio_item_id', ar.portfolio_item_id, 'session_id', ar.session_id,
        'note', ar.note, 'added_by', ar.added_by, 'at', ar.created_at)
        order by ar.created_at), '[]'::jsonb)
      from public.learning_activity_artifacts ar where ar.activity_id = p_activity),
    'evidence_proposals', (select coalesce(jsonb_agg(jsonb_build_object(
        'proposal_id', pr.id, 'skill_id', pr.skill_id, 'status', pr.status,
        'offered_at', pr.offered_at, 'decided_by', pr.decided_by,
        'decided_at', pr.decided_at,
        'learning_evidence_id', pr.learning_evidence_id)
        order by pr.offered_at), '[]'::jsonb)
      from public.learning_evidence_proposals pr where pr.activity_id = p_activity),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
        'kind', e.kind, 'note', e.note, 'actor', e.actor, 'at', e.created_at)
        order by e.created_at, e.id), '[]'::jsonb)
      from public.learning_activity_events e where e.activity_id = p_activity),
    'evidence_created_by_doing_any_of_this', false,
    'skill_state_changed_by_doing_any_of_this', false);
end $fn$;

comment on function public.activity_history(uuid) is
  'The whole story of one activity: what was chosen and why, every occasion it '
  'was worked on, what was attached, what was offered and what a person '
  'answered. Reconstructable without rewriting any of it.';

revoke all on function app.today_decide(uuid, app.today_decision_kind, text, date) from public, anon;
revoke all on function public.today(uuid, date) from public, anon;
revoke all on function public.explain_today_item(uuid, date) from public, anon;
revoke all on function public.pin_for_today(uuid, text, date) from public, anon;
revoke all on function public.hide_for_today(uuid, text, date) from public, anon;
revoke all on function public.choose_for_today(uuid, text, date) from public, anon;
revoke all on function public.clear_today_decision(uuid, date) from public, anon;
revoke all on function public.start_learning_session(uuid, text) from public, anon;
revoke all on function public.pause_learning_session(uuid, text) from public, anon;
revoke all on function public.end_learning_session(uuid, app.learning_session_outcome, integer, text, text) from public, anon;
revoke all on function public.add_session_note(uuid, text, text) from public, anon;
revoke all on function public.open_activity_resource(uuid, uuid) from public, anon;
revoke all on function public.attach_activity_artifact(uuid, uuid, uuid, uuid, text) from public, anon;
revoke all on function public.offer_activity_evidence(uuid, uuid, uuid, uuid, text) from public, anon;
revoke all on function public.accept_evidence_proposal(uuid, text, text) from public, anon;
revoke all on function public.decline_evidence_proposal(uuid, text) from public, anon;
revoke all on function public.activity_history(uuid) from public, anon;

grant execute on function app.today_decide(uuid, app.today_decision_kind, text, date) to authenticated, service_role;
grant execute on function public.today(uuid, date) to authenticated, service_role;
grant execute on function public.explain_today_item(uuid, date) to authenticated, service_role;
grant execute on function public.pin_for_today(uuid, text, date) to authenticated, service_role;
grant execute on function public.hide_for_today(uuid, text, date) to authenticated, service_role;
grant execute on function public.choose_for_today(uuid, text, date) to authenticated, service_role;
grant execute on function public.clear_today_decision(uuid, date) to authenticated, service_role;
grant execute on function public.start_learning_session(uuid, text) to authenticated, service_role;
grant execute on function public.pause_learning_session(uuid, text) to authenticated, service_role;
grant execute on function public.end_learning_session(uuid, app.learning_session_outcome, integer, text, text) to authenticated, service_role;
grant execute on function public.add_session_note(uuid, text, text) to authenticated, service_role;
grant execute on function public.open_activity_resource(uuid, uuid) to authenticated, service_role;
grant execute on function public.attach_activity_artifact(uuid, uuid, uuid, uuid, text) to authenticated, service_role;
grant execute on function public.offer_activity_evidence(uuid, uuid, uuid, uuid, text) to authenticated, service_role;
grant execute on function public.accept_evidence_proposal(uuid, text, text) to authenticated, service_role;
grant execute on function public.decline_evidence_proposal(uuid, text) to authenticated, service_role;
grant execute on function public.activity_history(uuid) to authenticated, service_role;

select app.assert_schema_invariants();
