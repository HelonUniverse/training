-- =============================================================================
-- 0110a  Two things Phase 1 could not have known it needed
-- =============================================================================
-- FORWARD FIXES to the deployed Phase 1 tables and functions. Neither is a
-- rewrite: 0103 and 0105 stay as they shipped, and this replaces what has to
-- change for a child to run a morning and for that morning to read back in the
-- order it happened.
-- =============================================================================

-- =============================================================================
-- (1) A child can write her own morning into her own history
-- =============================================================================
-- FORWARD WIDENING, not a rewrite. 0103 is deployed and its text stays as it
-- shipped; this replaces two policies that were written before there was any
-- such thing as a child acting for herself.
--
-- THE PROBLEM, found by the test where Lucas presses start. Phase 1 gated every
-- write on `learning_plan: update`, which was right at the time: the only
-- people touching activities were the adults who plan them. Phase 2 introduces
-- `learning_activity` precisely so that a child can run a morning without
-- gaining authority over her curriculum - and then her session RPC failed,
-- because starting a session updates the activity and appends to its event log,
-- and both were still asking for the planning capability she does not have.
--
-- THE FIX IS A WIDENING AND ONLY A WIDENING. Either capability now suffices.
-- Nobody who could write before loses anything, and the child gains exactly the
-- rows that are about her own morning. What she still cannot do is unchanged
-- and is enforced elsewhere: she has no `create` (she may not choose her own
-- curriculum), no `delete`, and no `approve` (she may not decide what counts as
-- evidence about herself).
-- =============================================================================

drop policy learning_activities_update on public.learning_activities;
create policy learning_activities_update on public.learning_activities
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_plan', 'update')
         or app.can_student_action(student_id, 'learning_activity', 'update'))
  with check (app.can_student_action(student_id, 'learning_plan', 'update')
              or app.can_student_action(student_id, 'learning_activity', 'update'));

drop policy learning_activity_events_insert on public.learning_activity_events;
create policy learning_activity_events_insert on public.learning_activity_events
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'update')
              or app.can_student_action(student_id, 'learning_activity', 'update'));

comment on policy learning_activity_events_insert on public.learning_activity_events is
  'Either the planning capability or the activity capability. A child may write '
  'what happened in her own morning into her own history; she still cannot '
  'choose her own curriculum or decide what becomes evidence about her.';

-- --- and the calls that run a morning ----------------------------------------
-- app.learning_activity_transition is what start / complete / skip / not today
-- / reopen / archive all go through, and it asked for the planning capability
-- for the same historical reason. Widened the same way, and the body is
-- otherwise byte-identical to the one 0105 shipped.
--
-- DELIBERATELY NOT WIDENED: select_activity_for_node, choose_activity_resource,
-- create_custom_activity and replace_activity_resource. Those are all ways of
-- CHOOSING material, which is a parent's decision and stays on `learning_plan`.
-- Whether a child should be able to choose something different for herself, or
-- only ask for something different, is a real product question and is reported
-- at the gate rather than answered here.

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
  if not found
     or not (app.can_student_action(v.student_id, 'learning_plan', 'update')
             or app.can_student_action(v.student_id, 'learning_activity', 'update')) then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  -- HISTORY IS NOT REWRITTEN. A morning that was put off can be picked back up;
  -- a morning that happened cannot be un-happened. The refusal is structured so
  -- a screen can say "that already happened - add another go instead" rather
  -- than showing a constraint name.
  if not app.learning_activity_transition_allowed(v.status, p_status) then
    return jsonb_build_object(
      'moved', false,
      'activity_id', p_activity,
      'from', v.status,
      'to', p_status,
      'reason', app.learning_activity_transition_refusal(v.status, p_status),
      'allowed_next', to_jsonb(app.learning_activity_next_states(v.status)),
      'evidence_created', false,
      'skill_state_changed', false,
      'note', 'Nothing changed. Doing something again is a new activity, so '
              || 'that what already happened stays on the record.');
  end if;

  -- Picking something back up needs the step to be free. Two live activities on
  -- one step is the thing the index refuses, and telling her why beats handing
  -- her a unique-violation.
  if p_status in ('selected', 'available', 'started')
     and v.status in ('skipped', 'not_today')
     and v.path_node_id is not null
     and exists (select 1 from public.learning_activities o
                  where o.path_node_id = v.path_node_id and o.id <> v.id
                    and o.status in ('proposed','selected','available','started')) then
    return jsonb_build_object(
      'moved', false,
      'activity_id', p_activity,
      'from', v.status,
      'to', p_status,
      'reason', 'another_activity_is_already_live_on_this_step',
      'evidence_created', false,
      'skill_state_changed', false,
      'note', 'There is already something chosen for this step. Set that one '
              || 'down first if you would rather come back to this.');
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
    'moved', true,
    'activity_id', p_activity,
    'status', p_status,
    'from', v.status,
    'skill_id', v.skill_id,
    'evidence_created', false,
    'skill_state_changed', false,
    'mastery_implied', false,
    'failure_implied', false,
    'note', app.learning_activity_note(p_status::text));
end $fn$;

-- =============================================================================
-- (2) An event log that can actually be read back in order
-- =============================================================================
-- FOUND BY THE HISTORY TEST, and it is the kind of defect that only shows up
-- when you try to use the thing. Every row written inside one transaction got
-- the same created_at, because `now()` is the transaction's start time, not the
-- moment of the statement. So a morning where a child opened the resource,
-- started, paused, resumed, attached a photo and finished - all in one call
-- chain - came back in an order decided by random uuids.
--
-- An audit trail that cannot be read in order is not an audit trail. Two
-- changes, both forward:
--
--   created_at now defaults to clock_timestamp(), which is the moment the row
--   was actually appended rather than the moment the transaction opened. That
--   is simply a truer answer to "when did this happen".
--
--   `seq` gives a total order that does not depend on clock resolution at all.
--   Two events in the same microsecond still have an order, and it is the order
--   they were written in.
--
-- Existing rows keep their timestamps and get sequence numbers in insertion
-- order, so nothing already recorded changes meaning.

alter table public.learning_activity_events
  alter column created_at set default clock_timestamp();

alter table public.learning_activity_events
  add column seq bigint generated by default as identity;

create index learning_activity_events_seq_idx
  on public.learning_activity_events (activity_id, seq);

comment on column public.learning_activity_events.seq is
  'The order these were appended, independent of clock resolution. Read a '
  'morning back with `order by seq`: created_at answers when, seq answers in '
  'what order, and inside one transaction only seq can.';

-- and the history function reads it that way.
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
        'kind', e.kind, 'note', e.note, 'actor', e.actor, 'at', e.created_at,
        'seq', e.seq)
        order by e.seq), '[]'::jsonb)
      from public.learning_activity_events e where e.activity_id = p_activity),
    'evidence_created_by_doing_any_of_this', false,
    'skill_state_changed_by_doing_any_of_this', false);
end $fn$;

select app.assert_schema_invariants();
