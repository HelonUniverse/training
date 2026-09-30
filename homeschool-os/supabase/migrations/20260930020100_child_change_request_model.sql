-- =============================================================================
-- 0116  STEP 8 PHASE 2 CORRECTION - a request is not a replacement
-- =============================================================================
-- THE PRODUCT DECISION THIS FIXES. child_choose_alternative_activity, deployed
-- in 20260930010000, let a student directly replace her own activity with a
-- confirmed alternative for the same skill. That was never the approved
-- workflow, even though the restriction it enforced - only a resource already
-- confirmed for that skill - was and remains correct. The approved workflow is:
--
--   CHILD REQUESTS SOMETHING DIFFERENT
--   -> AUTHORIZED ADULT REVIEWS
--   -> ADULT APPROVES OR DECLINES
--   -> ONLY ADULT APPROVAL INVOKES EXPLICIT REPLACEMENT
--
-- A request is a question. It changes nothing about the activity, the
-- resource, or the candidate selector. Only an adult's approval - acting
-- through the one explicit-replacement mechanism a parent already had,
-- replace_activity_resource, called here rather than reimplemented - actually
-- swaps the material.
--
-- FORWARD ONLY. 20260930010000 is not edited: its table, its RLS widening, and
-- its invariants text all stay exactly as they shipped, in history, as the
-- record of what was deployed and then corrected. What follows retires the
-- function and narrows the widening back, going forward from here.
-- =============================================================================

-- =============================================================================
-- (1) Retire the direct-replacement authority
-- =============================================================================
-- Not repurposed under the same name: a function called "choose" that used to
-- replace directly and now only asks is exactly the kind of silent narrowing
-- nobody would notice reading a diff of call sites. A new name for a new
-- action. This one is dropped outright, and 20260930020200's invariants check
-- that it stays dropped by name.

drop function if exists public.child_choose_alternative_activity(uuid, uuid, text);

-- And the RLS widening that existed ONLY to let that function's insert
-- succeed is narrowed back to exactly what Phase 1 shipped: a child may never
-- insert a row into learning_activities, full stop. The request table below
-- is where her half of this workflow actually writes.
drop policy learning_activities_insert on public.learning_activities;
create policy learning_activities_insert on public.learning_activities
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'create'));

comment on policy learning_activities_insert on public.learning_activities is
  'Choosing curriculum is learning_plan:create, which a child never holds. '
  'Narrowed back to exactly this after 20260930010000''s widening turned out '
  'to have been in service of an authority a child should not have had.';

-- =============================================================================
-- (2) The request, and the decision
-- =============================================================================
-- Mirrors the shape learning_evidence_proposals already proved out: an OFFER
-- table with a status, a decision, and a decider - except here the "offer"
-- comes from the child and the "decision" is an adult's, which is the mirror
-- image of who offers and who decides evidence. Reusing a proven shape
-- instead of inventing a second one.

create table public.learning_activity_change_requests (
  id                    uuid primary key default gen_random_uuid(),
  activity_id           uuid not null references public.learning_activities(id) on delete cascade,
  student_id            uuid not null references public.students(id) on delete cascade,

  -- THE SAME RESTRICTION gate item b always meant, unchanged by this
  -- correction: only a resource already confirmed and eligible for the skill
  -- this activity is already for. request_different_activity enforces it and
  -- 20260930020200 checks by name that it still does.
  requested_resource_id uuid not null references public.learning_resources(id) on delete cascade,

  status                app.activity_change_request_status not null default 'pending',
  requested_by          uuid not null references public.profiles(id),
  requested_at          timestamptz not null default now(),
  request_note          text,

  decided_by            uuid references public.profiles(id),
  decided_at            timestamptz,
  decision_note         text,

  -- Set ONLY on approval, and only to the NEW activity replace_activity_resource
  -- actually created. A request never points at a replacement it did not
  -- cause.
  resulting_activity_id uuid references public.learning_activities(id) on delete set null,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

alter table public.learning_activity_change_requests
  add constraint lacr_decision_names_its_actor_ck check (
    (status = 'pending' and decided_by is null and decided_at is null)
    or (status <> 'pending' and decided_by is not null and decided_at is not null));

alter table public.learning_activity_change_requests
  add constraint lacr_result_only_on_approval_ck check (
    (status = 'approved' and resulting_activity_id is not null)
    or (status <> 'approved' and resulting_activity_id is null));

-- REPEATED RELOAD DOES NOT CREATE DUPLICATES. One live request at a time per
-- activity; asking again while one is already waiting just hands back the one
-- that exists.
create unique index lacr_one_pending_per_activity_idx
  on public.learning_activity_change_requests (activity_id)
  where status = 'pending';

create index lacr_student_idx on public.learning_activity_change_requests (student_id, status, requested_at desc);
create index lacr_activity_idx on public.learning_activity_change_requests (activity_id);

select app.attach_updated_at('public.learning_activity_change_requests');

comment on table public.learning_activity_change_requests is
  'A child''s request to work on something different, and the adult answer to '
  'it. The request is a question: it does not touch the activity, the '
  'resource, or the selector. Only approval does, and only by calling '
  'replace_activity_resource - the one mechanism that has always performed an '
  'explicit replacement, now reached from two doors instead of rewritten.';

comment on column public.learning_activity_change_requests.resulting_activity_id is
  'The new activity replace_activity_resource created on approval. Null for '
  'every other status, because nothing was created.';

-- --- who may move a request, and out of which state --------------------------
-- DEFENSE IN DEPTH, not the only check: request_different_activity,
-- withdraw_activity_change_request, approve_activity_change_request and
-- decline_activity_change_request each check the right capability themselves.
-- This trigger means that check is not merely convention - a direct table
-- write from anywhere, present or future, is held to the same rule: a child
-- may withdraw only what she herself asked, and only an approve-capable adult
-- may grant or refuse it. A request that has already been decided does not
-- move again.

create or replace function app.enforce_activity_change_request_transition()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  if new.activity_id is distinct from old.activity_id
     or new.student_id is distinct from old.student_id
     or new.requested_resource_id is distinct from old.requested_resource_id
     or new.requested_by is distinct from old.requested_by
     or new.requested_at is distinct from old.requested_at then
    raise exception 'what was requested, and by whom, are not editable';
  end if;

  if old.status <> 'pending' then
    if new.status is distinct from old.status
       or new.decided_by is distinct from old.decided_by
       or new.decided_at is distinct from old.decided_at
       or new.decision_note is distinct from old.decision_note
       or new.resulting_activity_id is distinct from old.resulting_activity_id then
      raise exception 'this request has already been decided and is not editable'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    return new;
  end if;

  if new.status = 'withdrawn' then
    if new.requested_by is distinct from auth.uid() then
      raise exception 'only the person who made this request may withdraw it'
        using errcode = 'insufficient_privilege';
    end if;
  elsif new.status in ('approved', 'declined') then
    if not app.can_student_action(new.student_id, 'learning_activity', 'approve') then
      raise exception 'deciding a request to change a child''s activity is not this account''s decision to make'
        using errcode = 'insufficient_privilege';
    end if;
  else
    raise exception 'not a recognized transition' using errcode = 'check_violation';
  end if;

  return new;
end $fn$;

revoke all on function app.enforce_activity_change_request_transition() from public, anon, authenticated;

create trigger lacr_transitions_are_guarded
  before update on public.learning_activity_change_requests
  for each row execute function app.enforce_activity_change_request_transition();

-- =============================================================================
-- RLS
-- =============================================================================
-- No new capability row anywhere: this reuses learning_activity's existing
-- read / update / approve exactly as they already stood. A child has update
-- and can ask; a guardian with full access has approve and can decide; a
-- view-only guardian has neither and the policy below blocks her from ever
-- reaching the trigger. No delete policy - a decided request stays on the
-- record, the same as a session or a proposal.

alter table public.learning_activity_change_requests enable row level security;

create policy lacr_select on public.learning_activity_change_requests
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_activity', 'read')));

create policy lacr_insert on public.learning_activity_change_requests
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));

create policy lacr_update on public.learning_activity_change_requests
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_activity', 'update')
         or app.can_student_action(student_id, 'learning_activity', 'approve'))
  with check (app.can_student_action(student_id, 'learning_activity', 'update')
              or app.can_student_action(student_id, 'learning_activity', 'approve'));

grant select, insert, update on public.learning_activity_change_requests to authenticated;

-- =============================================================================
-- The request
-- =============================================================================

create or replace function public.request_different_activity(
  p_activity uuid,
  p_resource uuid,
  p_note     text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v public.learning_activities;
  v_existing uuid;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_resource is null then
    raise exception 'requesting something different still needs a resource to ask for'
      using errcode = 'check_violation';
  end if;

  select * into v from public.learning_activities a where a.id = p_activity;
  if not found or not app.can_student_action(v.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;

  -- THE RESTRICTION, unchanged from gate item b: only a resource already an
  -- eligible, confirmed candidate for the skill this activity is already for.
  if not exists (
    select 1 from app.learning_activity_candidates(v.student_id, v.skill_id) c
     where c.resource_id = p_resource) then
    return jsonb_build_object(
      'requested', false,
      'activity_id', p_activity,
      'reason', 'not_one_of_the_confirmed_options_for_this_skill',
      'evidence_created', false, 'skill_state_changed', false,
      'note', 'That one is not among the confirmed options for this skill yet. '
              || 'Ask a parent if you think it should be.');
  end if;

  -- A morning that is already finished, replaced or set aside is not one you
  -- ask to change - you would add a new activity instead. Caught early with a
  -- friendly refusal; approve_activity_change_request checks the live state
  -- again regardless, because time can pass between asking and answering.
  if not app.learning_activity_transition_allowed(v.status, 'replaced') then
    return jsonb_build_object(
      'requested', false,
      'activity_id', p_activity,
      'from', v.status,
      'reason', app.learning_activity_transition_refusal(v.status, 'replaced'),
      'evidence_created', false, 'skill_state_changed', false,
      'note', 'This one is already part of the record.');
  end if;

  -- REPEATED RELOAD DOES NOT CREATE DUPLICATES, and the unique index would
  -- refuse it anyway; this just answers without making her ask twice to find
  -- out.
  select id into v_existing from public.learning_activity_change_requests x
   where x.activity_id = p_activity and x.status = 'pending';
  if found then
    return jsonb_build_object(
      'requested', false, 'request_id', v_existing, 'activity_id', p_activity,
      'reason', 'already_waiting', 'status', 'pending',
      'evidence_created', false, 'skill_state_changed', false,
      'note', 'Already asked. Nobody has answered yet.');
  end if;

  insert into public.learning_activity_change_requests (
      activity_id, student_id, requested_resource_id, requested_by, request_note)
  values (p_activity, v.student_id, p_resource, auth.uid(), p_note)
  returning id into v_id;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, from_resource_id, to_resource_id, note, actor)
  values (p_activity, v.student_id, 'change_requested', v.skill_id, v.resource_id, p_resource,
          p_note, auth.uid());

  return jsonb_build_object(
    'requested', true, 'request_id', v_id, 'activity_id', p_activity, 'status', 'pending',
    -- THE POINT OF THIS FUNCTION, stated in the payload as well as enforced
    -- structurally: nothing about the activity changed, and the candidate
    -- selector was never touched.
    'activity_unchanged', true, 'resource_unchanged', true, 'selector_rerun', false,
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'Asked. A parent or educator will see this and can say yes or no - '
            || 'nothing changes until they do.');
end $fn$;

comment on function public.request_different_activity(uuid, uuid, text) is
  'A child asks to work on something different. This is a question, not an '
  'action: it never touches learning_activities and the invariants check that '
  'it never will. Only approve_activity_change_request may actually replace '
  'anything, and only through replace_activity_resource.';

-- --- taking it back -----------------------------------------------------------

create or replace function public.withdraw_activity_change_request(
  p_request uuid,
  p_note    text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare r public.learning_activity_change_requests;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.learning_activity_change_requests x where x.id = p_request;
  if not found or not app.can_student_action(r.student_id, 'learning_activity', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  -- ONLY THE PERSON WHO ASKED, not any adult who happens to hold `update`. The
  -- trigger enforces this too, independent of this check.
  if r.requested_by is distinct from auth.uid() then
    raise exception 'only the person who made this request may withdraw it'
      using errcode = 'insufficient_privilege';
  end if;
  if r.status <> 'pending' then
    return jsonb_build_object('request_id', p_request, 'withdrawn', false,
      'reason', 'already_decided', 'status', r.status);
  end if;

  update public.learning_activity_change_requests x
     set status = 'withdrawn', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
   where x.id = p_request;

  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (r.activity_id, r.student_id, 'change_request_withdrawn', null, p_note, auth.uid());

  return jsonb_build_object('request_id', p_request, 'withdrawn', true,
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'Withdrawn. Nothing was waiting on it.');
end $fn$;

comment on function public.withdraw_activity_change_request(uuid, text) is
  'A child takes back her own pending request. Never touches '
  'learning_activities, and never anyone else''s request - the trigger holds '
  'that even if this check did not.';

-- =============================================================================
-- What an adult decides
-- =============================================================================

create or replace function public.approve_activity_change_request(
  p_request uuid,
  p_note    text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  r public.learning_activity_change_requests;
  v_result jsonb;
  v_new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.learning_activity_change_requests x where x.id = p_request;
  -- Deciding a request to change what a child is working on is an `approve`,
  -- not an `update` - the same distinction evidence decisions already draw. A
  -- tutor may run the week; only a guardian with full access decides whether
  -- the child's request is granted.
  if not found or not app.can_student_action(r.student_id, 'learning_activity', 'approve') then
    raise exception 'deciding a request to change a child''s activity is not this account''s decision to make'
      using errcode = 'insufficient_privilege';
  end if;
  if r.status <> 'pending' then
    return jsonb_build_object('request_id', p_request, 'approved', false,
      'reason', 'already_decided', 'status', r.status,
      'evidence_created', false, 'skill_state_changed', false);
  end if;

  -- THE ONLY PATH TO AN ACTUAL REPLACEMENT, and it is the one that already
  -- existed: replace_activity_resource, called by the deciding adult, not
  -- reimplemented here. Its own lifecycle check runs again, because time has
  -- passed since the request was made and the activity may no longer be
  -- replaceable.
  v_result := public.replace_activity_resource(r.activity_id, r.requested_resource_id, null,
                                                 coalesce(p_note, r.request_note));

  if (v_result ->> 'replaced') = 'false' then
    return jsonb_build_object(
      'request_id', p_request, 'approved', false,
      'reason', 'no_longer_replaceable',
      'activity_reason', v_result ->> 'reason',
      'evidence_created', false, 'skill_state_changed', false,
      'note', 'This one moved on before anyone answered. Decline the request '
              || 'to close it out, or ask her to open a new one.');
  end if;

  v_new_id := (v_result ->> 'activity_id')::uuid;

  update public.learning_activity_change_requests x
     set status = 'approved', decided_by = auth.uid(), decided_at = now(),
         decision_note = p_note, resulting_activity_id = v_new_id
   where x.id = p_request;

  insert into public.learning_activity_events (
      activity_id, student_id, kind, skill_id, from_resource_id, to_resource_id, note, actor)
  values (v_new_id, r.student_id, 'change_request_approved',
          nullif(v_result ->> 'skill_id', '')::uuid, null, r.requested_resource_id,
          p_note, auth.uid());

  return jsonb_build_object(
    'request_id', p_request, 'approved', true,
    'activity_id', v_new_id, 'replaces', r.activity_id,
    'evidence_created', false, 'skill_state_changed', false,
    'note', 'Granted. ' || (v_result ->> 'note'));
end $fn$;

comment on function public.approve_activity_change_request(uuid, text) is
  'The only way a child''s request actually becomes a replacement. Goes '
  'through replace_activity_resource - the one mechanism that has always '
  'performed an explicit replacement - and requires `approve`, which a child '
  'never holds.';

create or replace function public.decline_activity_change_request(
  p_request uuid,
  p_note    text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare r public.learning_activity_change_requests;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.learning_activity_change_requests x where x.id = p_request;
  if not found or not app.can_student_action(r.student_id, 'learning_activity', 'approve') then
    raise exception 'deciding a request to change a child''s activity is not this account''s decision to make'
      using errcode = 'insufficient_privilege';
  end if;
  if r.status <> 'pending' then
    return jsonb_build_object('request_id', p_request, 'declined', false,
      'reason', 'already_decided', 'status', r.status);
  end if;

  update public.learning_activity_change_requests x
     set status = 'declined', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
   where x.id = p_request;

  insert into public.learning_activity_events (activity_id, student_id, kind, skill_id, note, actor)
  values (r.activity_id, r.student_id, 'change_request_declined', null, p_note, auth.uid());

  return jsonb_build_object('request_id', p_request, 'declined', true,
    'evidence_created', false, 'skill_state_changed', false,
    'negative_record_created', false,
    'note', 'Not this time. Declining leaves the activity exactly as it was - '
            || 'nothing about her record changes because material stayed the same.');
end $fn$;

comment on function public.decline_activity_change_request(uuid, text) is
  'Refuses a request. Creates no evidence, moves no state, and leaves no '
  'negative record - the activity is simply unchanged, the same as it was '
  'before anyone asked.';

revoke all on function public.request_different_activity(uuid, uuid, text) from public, anon;
revoke all on function public.withdraw_activity_change_request(uuid, text) from public, anon;
revoke all on function public.approve_activity_change_request(uuid, text) from public, anon;
revoke all on function public.decline_activity_change_request(uuid, text) from public, anon;

grant execute on function public.request_different_activity(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.withdraw_activity_change_request(uuid, text) to authenticated, service_role;
grant execute on function public.approve_activity_change_request(uuid, text) to authenticated, service_role;
grant execute on function public.decline_activity_change_request(uuid, text) to authenticated, service_role;
