-- =============================================================================
-- 0119  STEP 8 PHASE 3 - adaptive replanning, and the record of why
-- =============================================================================
-- Student -> Skills -> Evidence -> Readiness -> Learning Path -> Activity ->
-- Session -> Artifact / Optional Evidence -> Human Review -> Updated Skill
-- Profile -> Adaptive Replanning. This file is the last arrow, and the one
-- most products get backwards by letting a SESSION OUTCOME stand in for the
-- HUMAN REVIEW that is supposed to precede it.
--
-- THE LOOP THIS BUILDS, and the one it refuses to build:
--
--   legitimate evidence or human intent -> profile/context change -> replan
--
--   NEVER: session outcome -> mastery
--   NEVER: activity completed -> next skill automatically
--   NEVER: resource opened -> advance
--
-- WHAT ALREADY EXISTED AND IS REUSED, NOT REBUILT. STEP 7 Phase 6 already gave
-- this project exactly the two-step proposal/approval shape a replan needs:
-- regenerate_learning_path creates a new PROPOSED version and leaves the
-- approved one exactly as it was; approve_learning_path / reject_learning_path
-- are the only way a proposal becomes - or stops being a candidate to become -
-- the plan. Phase 3 does not reimplement any of that. It adds exactly one new
-- thing: a deterministic answer to WHEN an automatic regeneration attempt is
-- even warranted, and a structured, explainable RECORD of why it happened,
-- because "the engine quietly regenerated a path" is not an answer a parent
-- can audit two years later.
--
-- TWO KINDS OF ADAPTATION, and only one of them touches this table:
--
--   SAME-SKILL (offer a different confirmed resource or modality for the
--   skill a child is already working on) is computed fresh every time it is
--   asked for, the same way the STEP 7 Phase 4 refresh advisory is - never
--   stored, because a stored suggestion is a value that can drift out of
--   agreement with the candidates that produced it. It never touches a path.
--
--   PATH-LEVEL (the candidate skill set for a branch might legitimately be
--   different now) is the only kind recorded here, because it is the only
--   kind where "why did this change" needs to survive the session that
--   triggered it.
-- =============================================================================

-- --- 1. The closed list of legitimate reasons --------------------------------
-- Every member is a canonical fact that already has its own home elsewhere in
-- this schema: confirmed evidence, a human's override, a goal, a confirmed
-- revisit, a resource's own availability, an approved child request, an
-- enrollment's own status, or where a diagnostic stopped. None of them is an
-- operational session event, and none of them is derivable from a grade, an
-- age, or a standard.

create type app.replan_trigger_reason as enum (
  'confirmed_evidence_changed_profile',
  'human_confirmed_secure',
  'parent_goal_changed',
  'approved_revisit',
  'resource_unavailable',
  'child_change_request_approved',
  'active_enrollment_changed',
  'diagnostic_frontier_changed');

comment on type app.replan_trigger_reason is
  'The complete list of things that may legitimately prompt Nestra to look at '
  'a plan again. A session outcome, an activity completion, a note, an '
  'artifact, time spent or a count of anything is deliberately absent and may '
  'not be added: every member here is a canonical fact, not an operational '
  'event.';

-- --- 2. The vocabulary of what Nestra can recommend --------------------------
-- Planning decisions, not skill states and not verdicts. There is no `failed`,
-- no `behind`, no `deficient`, no `remediation` and no `catch_up` here, and
-- there may not be: those words describe a child against an external
-- expectation, and nothing in this phase measures one.

create type app.replan_outcome as enum (
  'no_change',
  'continue_current_skill',
  'offer_alternative_resource',
  'offer_alternative_modality',
  'revisit_later',
  'refresh_current_path',
  'advance_to_connected_skill',
  'return_to_prerequisite',
  'await_human_review');

comment on type app.replan_outcome is
  'What Nestra is suggesting, never what a child is. The first four plus '
  '`revisit_later` are same-skill or informational and are never written to '
  'this table; the last four describe a path-level candidate that may be '
  'worth a person''s attention, and every one of them still waits on '
  'approve_learning_path before anything about the live plan actually moves.';

-- =============================================================================
-- 3. The record of a path-level recommendation
-- =============================================================================
-- Deliberately thin, and deliberately NOT the authority on whether it was
-- approved. `resulting_path_id` points at an ordinary learning_paths row, and
-- that row's own status - proposed, approved, rejected, archived - is read
-- live rather than copied here, for the same reason app.refresh_advisory
-- computes instead of storing: a copied status is a value that can disagree
-- with the row it was copied from. Explainability is one query away:
-- explain_replan_recommendation joins to it.

create table public.learning_path_replan_recommendations (
  id                     uuid primary key default gen_random_uuid(),
  student_id             uuid not null references public.students(id) on delete cascade,
  skill_id               uuid references public.skills(id) on delete set null,
  branch_root_skill_id   uuid references public.skills(id) on delete set null,

  trigger_reason         app.replan_trigger_reason not null,
  -- The id of whatever canonical record made this legitimate: an evidence
  -- proposal, an override, a refresh decision, a change request, an
  -- enrollment, a diagnostic session, a goal. Deliberately not a foreign key -
  -- which table it names depends on trigger_reason, and a replan explanation
  -- is not the place to invent a polymorphic reference scheme the rest of the
  -- schema does not otherwise use.
  trigger_record_id      uuid,

  outcome                app.replan_outcome not null,
  requires_review        boolean not null default true,

  prior_path_id          uuid references public.learning_paths(id) on delete set null,
  resulting_path_id      uuid references public.learning_paths(id) on delete set null,

  -- What was actually consulted, frozen, so "why did it suggest this" is
  -- answerable without re-deriving a profile that has long since moved on -
  -- the same reason learning_paths.generation_inputs exists.
  skill_states_consulted jsonb not null default '[]'::jsonb,
  explanation            jsonb not null default '{}'::jsonb,
  rule_version           text not null,

  created_at             timestamptz not null default now(),
  created_by             uuid not null references public.profiles(id)
);

-- Every path-level outcome here changes what a child is next asked to do, and
-- 0121 checks by name that this stays true rather than quietly growing a
-- "safe automatic" branch nobody reviewed.
alter table public.learning_path_replan_recommendations
  add constraint lprr_requires_review_ck check (requires_review);

create index lprr_student_idx
  on public.learning_path_replan_recommendations (student_id, created_at desc);
create index lprr_resulting_path_idx
  on public.learning_path_replan_recommendations (resulting_path_id);

comment on table public.learning_path_replan_recommendations is
  'Why Nestra proposed a new path version, recorded once and never edited. '
  'Approving or declining it is not a separate decision from approving or '
  'rejecting resulting_path_id - that is the SAME decision, made through the '
  'same approve_learning_path / reject_learning_path every other path change '
  'already goes through.';

comment on column public.learning_path_replan_recommendations.trigger_record_id is
  'The id of the canonical record that made this legitimate. Which table it '
  'points at depends on trigger_reason; this column is not a foreign key on '
  'purpose.';

create trigger lprr_append_only
  before update or delete on public.learning_path_replan_recommendations
  for each row execute function app.forbid_mutation();

-- =============================================================================
-- RLS - the same scope as the path it explains
-- =============================================================================

alter table public.learning_path_replan_recommendations enable row level security;

create policy lprr_select on public.learning_path_replan_recommendations
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_plan', 'read')));

-- Insert matches what the RPC itself requires: a path-level recommendation
-- only ever comes from a call that already holds learning_plan:create, the
-- same capability regenerate_learning_path has always required.
create policy lprr_insert on public.learning_path_replan_recommendations
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'create'));

-- No UPDATE or DELETE policy, and the trigger above refuses both anyway.

grant select, insert on public.learning_path_replan_recommendations to authenticated;

select app.assert_schema_invariants();
