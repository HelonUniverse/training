-- =============================================================================
-- 0117  STEP 8 PHASE 2 CORRECTION - what happened is not a wish about next time
-- =============================================================================
-- THE PRODUCT DECISION THIS FIXES. The deployed app.learning_session_outcome
-- conflated two different questions into one six-label enum:
--
--   completed / partially_completed / explored / stopped   - what happened
--   child_wants_more / revisit_later                        - a wish about
--                                                              NEXT time
--
-- A morning that finished AND left her wanting more had no honest label: pick
-- `completed` and the wish disappears, pick `child_wants_more` and the record
-- no longer says the worksheet was actually finished. The approved model
-- keeps both truths: an outcome, which is exactly the four labels that
-- describe the occasion, and two independent follow-up flags that describe
-- what happens next. Neither flag is an outcome, and neither may move
-- anything about the child - the same guarantee end_learning_session already
-- gave the six-label version.
--
-- FORWARD ONLY, and the type has to be rebuilt rather than edited in place,
-- because Postgres will not let an enum value be dropped while anything
-- depends on it. The rebuild is defensive about data that does not exist yet:
-- at the time this was written, `select count(*) from
-- learning_activity_sessions` is zero on both local and the managed dev
-- project, verified before writing a single line here. The backfill and the
-- loud assertion below exist anyway, because a migration that would silently
-- invent a core outcome for a row it cannot actually account for is a worse
-- defect than one that fails loudly and asks a person to look.
-- =============================================================================

-- --- make room: the old type keeps its OID, just not this name ---------------
-- A rename is not a rewrite of history - nothing about what already happened
-- changes meaning. It just gets the name out of the way so the corrected type
-- can be created under the name code actually references.

alter type app.learning_session_outcome rename to learning_session_outcome_six_label_legacy;

create type app.learning_session_outcome as enum (
  'completed',
  'partially_completed',
  'explored',
  'stopped');

comment on type app.learning_session_outcome is
  'How one occasion went, and nothing else. Exactly these four labels, none '
  'of them a failure. A wish about what happens NEXT - more of this, or '
  'coming back to it later - is not an outcome and lives in '
  'learning_activity_sessions.wants_more / .revisit_later instead.';

-- --- the new column, backfilled truthfully or not at all ---------------------

alter table public.learning_activity_sessions
  add column outcome_next app.learning_session_outcome,
  add column wants_more    boolean not null default false,
  add column revisit_later boolean not null default false;

update public.learning_activity_sessions
   set outcome_next = case
         when outcome::text in ('completed', 'partially_completed', 'explored', 'stopped')
           then outcome::text::app.learning_session_outcome
         else null
       end,
       wants_more    = (outcome::text = 'child_wants_more'),
       revisit_later = (outcome::text = 'revisit_later')
 where outcome is not null;

-- THE LOUD FAILURE INSTEAD OF A GUESS. If this ever fires, a session ended
-- with a label the four-outcome model cannot represent and no core outcome
-- can be recovered from the data this migration has access to - exactly the
-- case the corrective spec says not to paper over. Per that spec: if this is
-- real historical data, stop and get a human decision; if it is only test or
-- demo data, delete those specific rows and recreate the fixture under the
-- new model, then re-run.
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.learning_activity_sessions
   where status = 'ended' and outcome_next is null;
  if v_bad > 0 then
    raise exception
      '% ended session(s) carried an outcome this migration cannot truthfully '
      'represent as one of the four labels, and this migration refuses to '
      'guess one. Inspect learning_activity_sessions.outcome for those rows '
      'before proceeding.', v_bad;
  end if;
end $$;

alter table public.learning_activity_sessions
  drop constraint las_ended_session_is_complete_ck;

alter table public.learning_activity_sessions
  drop column outcome;

alter table public.learning_activity_sessions
  rename column outcome_next to outcome;

alter table public.learning_activity_sessions
  add constraint las_ended_session_is_complete_ck check (
    (status <> 'ended' and ended_at is null and outcome is null and ended_by is null
       and wants_more = false and revisit_later = false)
    or (status = 'ended' and ended_at is not null and outcome is not null and ended_by is not null));

comment on column public.learning_activity_sessions.outcome is
  'How the occasion ended, observationally, as exactly one of four labels. '
  'There is no failure label here and there may not be one.';

comment on column public.learning_activity_sessions.wants_more is
  'The child or family would like another related learning experience. A '
  'wish about next time, not a fact about this occasion - it may not '
  'independently change skill state, create evidence, or create mastery.';

comment on column public.learning_activity_sessions.revisit_later is
  'The child or family intentionally wants to return to this learning area '
  'later. Also a wish about next time, and NOT the same mechanism as '
  'app.today_reason''s `revisit_requested` or the STEP 7 Phase 4 refresh '
  'advisory - those are an adult''s human-intent decision about a skill, made '
  'through request_skill_revisit. If this flag is ever meant to feed that '
  'mechanism, it is routed there explicitly; it does not reach it by itself.';

-- --- the function that used to take six labels now can only be given four ---
-- Dropped and recreated rather than replaced in place, because the parameter
-- type itself changed OID. The two new parameters are exactly the flags: the
-- caller reports an outcome AND, separately and optionally, a wish about next
-- time.

drop function if exists public.end_learning_session(
  uuid, app.learning_session_outcome_six_label_legacy, integer, text, text);

create or replace function public.end_learning_session(
  p_session       uuid,
  p_outcome       app.learning_session_outcome default 'completed',
  p_minutes       integer default null,
  p_child_note    text default null,
  p_educator_note text default null,
  p_wants_more    boolean default false,
  p_revisit_later boolean default false)
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
         educator_note = coalesce(p_educator_note, x.educator_note),
         wants_more = p_wants_more,
         revisit_later = p_revisit_later
   where x.id = p_session;

  select * into v from public.learning_activities a where a.id = s.activity_id;
  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (s.activity_id, s.student_id, 'session_ended', v.skill_id,
          coalesce(p_child_note, p_educator_note), auth.uid());

  -- The ACTIVITY is only marked completed when the occasion actually completed
  -- it, and only where the Phase 1 graph allows. Neither follow-up flag has
  -- any bearing on this - wanting more or wanting to come back later says
  -- nothing about whether THIS worksheet is finished.
  if p_outcome = 'completed'
     and app.learning_activity_transition_allowed(v.status, 'completed') then
    perform public.complete_activity(s.activity_id, 'session ' || p_session::text);
  end if;

  return jsonb_build_object(
    'session_id', p_session, 'ended', true, 'outcome', p_outcome,
    'wants_more', p_wants_more, 'revisit_later', p_revisit_later,
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

comment on function public.end_learning_session(
  uuid, app.learning_session_outcome, integer, text, text, boolean, boolean) is
  'Records how one occasion went, as exactly one of four outcome labels, and '
  'separately, optionally, whether the child wants more of this or wants to '
  'come back to it later. Neither flag is an outcome; no outcome and no flag '
  'is a failure; the duration is only what somebody reported.';

revoke all on function public.end_learning_session(
  uuid, app.learning_session_outcome, integer, text, text, boolean, boolean) from public, anon;
grant execute on function public.end_learning_session(
  uuid, app.learning_session_outcome, integer, text, text, boolean, boolean) to authenticated, service_role;

-- --- and the history function shows the flags it now reads back --------------
-- 0110a is not edited - this is the same correct, seq-ordered body it and
-- 20260930010000 have carried, with wants_more and revisit_later added to the
-- session shape so a reconstructed morning shows the whole truth about it.

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
        'wants_more', s.wants_more, 'revisit_later', s.revisit_later,
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
    'change_requests', (select coalesce(jsonb_agg(jsonb_build_object(
        'request_id', cr.id, 'requested_resource_id', cr.requested_resource_id,
        'status', cr.status, 'requested_by', cr.requested_by,
        'requested_at', cr.requested_at, 'decided_by', cr.decided_by,
        'decided_at', cr.decided_at, 'resulting_activity_id', cr.resulting_activity_id)
        order by cr.requested_at), '[]'::jsonb)
      from public.learning_activity_change_requests cr where cr.activity_id = p_activity),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
        'kind', e.kind, 'note', e.note, 'actor', e.actor, 'at', e.created_at,
        'seq', e.seq)
        order by e.seq), '[]'::jsonb)
      from public.learning_activity_events e where e.activity_id = p_activity),
    'evidence_created_by_doing_any_of_this', false,
    'skill_state_changed_by_doing_any_of_this', false);
end $fn$;

-- --- and the legacy type is gone once nothing depends on it anymore ---------

drop type app.learning_session_outcome_six_label_legacy;

-- NOTE: app.assert_schema_invariants() is NOT called here. Its own body still
-- expects the six-label enum and the now-retired
-- child_choose_alternative_activity until 20260930020300 redefines it in the
-- same forward style every prior invariants file has used. Calling it here
-- would fail against a check this migration is in the middle of correcting.
