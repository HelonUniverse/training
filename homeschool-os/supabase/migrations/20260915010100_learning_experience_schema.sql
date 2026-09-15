-- =============================================================================
-- 0110  STEP 8 PHASE 2 - what actually happened on a Tuesday morning
-- =============================================================================
-- Phase 1 answered "what could support this skill". This is the layer where a
-- nine-year-old opens it, works for eleven minutes, gets interrupted, comes
-- back on Thursday, and finishes. Everything here exists to record that
-- truthfully without turning any of it into a claim about her.
--
-- THE FOUR THINGS THIS FILE ADDS, and why each is separate:
--
--   today_decisions        what a PERSON said about today. Not what Today is -
--                          Today is derived - only the handful of explicit
--                          decisions that cannot be derived from anything else.
--   sessions               one OCCASION of working on an activity. An activity
--                          is the thing; a session is a morning.
--   artifacts              a photo of the worksheet, pointed at the document
--                          store that already exists. Not a second one.
--   evidence proposals     an OFFER to record something as evidence, and the
--                          human answer to it. The offer is not evidence and
--                          accepting it does not touch the profile.
--
-- AND THE LINE THAT RUNS UNDER ALL OF IT: nothing here writes to
-- student_skills, student_skill_events or student_skill_overrides. Not a
-- session, not a completion, not an artifact, not a note, not an accepted
-- proposal. Accepting a proposal calls the STEP 5 function that records "this
-- work RELATES to this skill" and stops there. What a child has learned is
-- still decided by a person, through the path that already existed, and 0112
-- refuses any code here that tries to shortcut it.
-- =============================================================================

-- --- 1. Why something is in Today --------------------------------------------
-- Factual, structured, and a closed list. Every one of these is a record that
-- already exists somewhere else; Today is a reading of them, not a new opinion.

create type app.today_reason as enum (
  'approved_learning_path',        -- an actionable node on the live path
  'parent_chose_it',               -- she picked it from the catalogue
  'parent_created_it',             -- she wrote it herself
  'revisit_requested',             -- a person asked to come back to this skill
  'continuing_something_started'); -- it is already open

comment on type app.today_reason is
  'Why an item is in Today, as a fact rather than a sentence. Grade, age, '
  'pacing and standards are deliberately absent and may not be added: Today is '
  'what this family is doing, never what a child of this age is supposed to be '
  'doing by now.';

-- --- 2. The few things about today a person decides --------------------------
-- Everything else in Today is derived. These three cannot be: "put this at the
-- front today", "not this one today", and "I picked this one for today" are
-- decisions, and a derived view cannot invent them.

create type app.today_decision_kind as enum (
  'pinned_for_today',
  'hidden_for_today',
  'chosen_for_today');

-- --- 3. A session is an occasion, not a verdict ------------------------------

create type app.learning_session_status as enum (
  'in_progress',
  'paused',
  'ended');

-- HOW THE OCCASION ENDED. Observational and non-punitive by construction:
-- there is no `failed`, no `passed`, no `below_level`, and 0112 refuses one
-- being added. `stopped` is not a judgement - a morning that stopped is a
-- morning that stopped, and the most common reason is a doorbell.
--
-- NOTE ON THE VOCABULARY. These are exactly the six labels the specification
-- listed, used as given rather than invented. Two of them - child_wants_more
-- and revisit_later - read as a wish about NEXT time rather than as how this
-- occasion ended, so a morning that was finished AND left her wanting more
-- currently has to pick one. That tension is reported at the decision gate
-- rather than resolved here by inventing a second column.
create type app.learning_session_outcome as enum (
  'completed',
  'partially_completed',
  'explored',
  'stopped',
  'child_wants_more',
  'revisit_later');

-- --- 4. How a resource is actually opened ------------------------------------
-- Named honestly, because the difference between "we link to their page" and
-- "we are integrated with them" is the difference between a true sentence and a
-- false one. Nothing in Nestra is `provider_integrated` today.

create type app.resource_launch_kind as enum (
  'nestra_hosted',        -- material Nestra owns and serves
  'external_link',        -- we open their page. That is all it is.
  'provider_integrated',  -- a real live integration. Nothing is this yet.
  'offline',              -- paper, objects, a walk. No launch at all.
  'no_digital_resource'); -- the activity has no resource, and works anyway

comment on type app.resource_launch_kind is
  'How a piece of material is actually opened today. `provider_integrated` may '
  'only be used where a live integration exists; `external_link` is a link and '
  'nothing more. Nestra does not claim an integration it does not have.';

-- --- 5. The offer, and the answer to it --------------------------------------

create type app.evidence_proposal_status as enum (
  'offered',    -- Nestra asked. Nothing has been decided.
  'accepted',   -- a person said yes, and named the skill
  'declined');  -- a person said no, which is also information

-- =============================================================================
-- What a person decided about today
-- =============================================================================
-- Deliberately tiny. The temptation here is to build a second learning plan -
-- a daily schedule table with its own ordering, its own status, its own
-- lifecycle - and within a year the plan and the schedule disagree and nobody
-- can say which is true. So this table holds ONLY what cannot be derived.

create table public.today_decisions (
  id           uuid primary key default gen_random_uuid(),
  student_id   uuid not null references public.students(id) on delete cascade,
  activity_id  uuid not null references public.learning_activities(id) on delete cascade,
  on_date      date not null default current_date,
  kind         app.today_decision_kind not null,
  note         text,
  decided_by   uuid not null references public.profiles(id),
  created_at   timestamptz not null default now()
);

-- One decision per activity per day. Changing her mind replaces the decision
-- rather than accumulating contradictory ones.
create unique index today_decisions_one_per_day_idx
  on public.today_decisions (student_id, activity_id, on_date);

create index today_decisions_day_idx on public.today_decisions (student_id, on_date);

comment on table public.today_decisions is
  'The handful of things about today that a person decided and nothing else '
  'could tell us: pin it, hide it, or "I picked this one". Today itself is '
  'derived from the learning path and the activities; this is not a second '
  'plan, and being in Today is never evidence about a child.';

-- =============================================================================
-- Sessions: one occasion of working on something
-- =============================================================================
-- The distinction that makes repeated work honest. An ACTIVITY is the thing to
-- do. A SESSION is a morning. She can start on Tuesday, stop when the baby
-- wakes, come back on Thursday and finish - and Tuesday stays on the record as
-- a real thing that happened rather than being overwritten by Thursday.

create table public.learning_activity_sessions (
  id              uuid primary key default gen_random_uuid(),
  activity_id     uuid not null references public.learning_activities(id) on delete cascade,
  student_id      uuid not null references public.students(id) on delete cascade,

  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  status          app.learning_session_status not null default 'in_progress',
  outcome         app.learning_session_outcome,

  -- Who set this occasion going. A child pressing start and a parent starting
  -- it with her are different facts and are kept apart.
  initiated_by    uuid not null references public.profiles(id),
  ended_by        uuid references public.profiles(id),

  -- NEVER COMPUTED, NEVER GUESSED. Null means nobody knows how long it took,
  -- which is the ordinary case for a walk or a conversation. 0112 refuses any
  -- function that derives it from the timestamps: a session left open overnight
  -- did not take fourteen hours, and recording that it did would put a false
  -- number in a record a parent may one day hand to an evaluator.
  duration_minutes integer,

  -- Optional, both of them, and never required to end a session.
  child_note      text,
  educator_note   text,

  rule_version    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

alter table public.learning_activity_sessions
  add constraint las_ended_session_is_complete_ck check (
    (status <> 'ended' and ended_at is null and outcome is null and ended_by is null)
    or (status = 'ended' and ended_at is not null and outcome is not null
        and ended_by is not null));

alter table public.learning_activity_sessions
  add constraint las_ends_after_it_starts_ck check (
    ended_at is null or ended_at >= started_at);

alter table public.learning_activity_sessions
  add constraint las_duration_is_time_not_a_score_ck check (
    duration_minutes is null or duration_minutes between 1 and 1440);

-- One open session per activity. Two live sessions on one activity is not a
-- richer record, it is a bug that makes "is she working on this" unanswerable.
create unique index las_one_open_session_idx
  on public.learning_activity_sessions (activity_id)
  where status in ('in_progress', 'paused');

create index las_activity_idx on public.learning_activity_sessions (activity_id, started_at desc);
create index las_student_idx  on public.learning_activity_sessions (student_id, started_at desc);

select app.attach_updated_at('public.learning_activity_sessions');

comment on table public.learning_activity_sessions is
  'One occasion of working on one activity. Ending a session records how the '
  'morning went and nothing whatever about the child: no evidence is created, '
  'no state moves, and `completed` here means the session finished, not that '
  'anything has been learned.';

comment on column public.learning_activity_sessions.duration_minutes is
  'How long it took, where a person said or a timer measured. Null means '
  'nobody knows, which is normal. It is never derived from the timestamps - a '
  'session left open overnight did not take fourteen hours.';

comment on column public.learning_activity_sessions.outcome is
  'How the occasion ended, observationally. There is no failure label here and '
  'there may not be one: stopping is not failing, and a product that says '
  'otherwise teaches a family to stop telling it the truth.';

-- =============================================================================
-- Artifacts: the photo of the worksheet
-- =============================================================================
-- This table stores NOTHING. It points at the document and portfolio machinery
-- that has existed since STEP 2, because a second file store would mean a
-- second set of scan gates, a second set of sharing rules, and a second place
-- for a child's work to leak from.

create table public.learning_activity_artifacts (
  id                uuid primary key default gen_random_uuid(),
  activity_id       uuid not null references public.learning_activities(id) on delete cascade,
  session_id        uuid references public.learning_activity_sessions(id) on delete set null,
  student_id        uuid not null references public.students(id) on delete cascade,

  document_id       uuid references public.documents(id) on delete cascade,
  portfolio_item_id uuid references public.portfolio_items(id) on delete cascade,

  note              text,
  added_by          uuid not null references public.profiles(id),
  created_at        timestamptz not null default now()
);

-- An artifact that points at nothing is not an artifact.
alter table public.learning_activity_artifacts
  add constraint laa_points_at_something_ck check (
    document_id is not null or portfolio_item_id is not null);

create unique index laa_one_link_per_document_idx
  on public.learning_activity_artifacts (activity_id, document_id)
  where document_id is not null;

create index laa_activity_idx on public.learning_activity_artifacts (activity_id, created_at);
create index laa_session_idx  on public.learning_activity_artifacts (session_id);

comment on table public.learning_activity_artifacts is
  'Associates work a family already stored - a document, a portfolio item - '
  'with the activity it came out of. It holds no files of its own: the scan '
  'gate, the sharing rules and the retention policy that protect a child''s '
  'work all live in the document store, and a second one would mean a second '
  'place for them to be got wrong.';

-- =============================================================================
-- The evidence offer, and the answer
-- =============================================================================
-- THE MOST DANGEROUS TABLE IN THE PHASE, and the one the rest of the design
-- exists to keep honest.
--
-- A proposal means: "work associated with this activity might be worth
-- recording against this skill - would you like to?"
--
-- It does NOT mean "this activity proves this skill", and accepting one does
-- not make it mean that. Acceptance calls public.confirm_skill_evidence, which
-- has recorded "this work RELATES to this skill" since STEP 5 and deliberately
-- does not touch student_skills. Whether the child has actually learned
-- anything is still a separate judgement a person makes through the profile
-- path that already exists.
--
-- Declining is kept, because "no, that was just practice" is information about
-- how a family reads their own week, and throwing it away would mean asking
-- them the same question forever.

create table public.learning_evidence_proposals (
  id             uuid primary key default gen_random_uuid(),
  activity_id    uuid not null references public.learning_activities(id) on delete cascade,
  session_id     uuid references public.learning_activity_sessions(id) on delete set null,
  artifact_id    uuid references public.learning_activity_artifacts(id) on delete set null,
  student_id     uuid not null references public.students(id) on delete cascade,
  skill_id       uuid not null references public.skills(id) on delete cascade,

  status         app.evidence_proposal_status not null default 'offered',
  offered_at     timestamptz not null default now(),
  offered_reason text,

  decided_by     uuid references public.profiles(id),
  decided_at     timestamptz,
  decline_note   text,

  -- Set ONLY on acceptance, and it points at the STEP 5 record that the
  -- existing function created. Phase 2 does not write evidence itself.
  learning_evidence_id uuid references public.learning_evidence(id) on delete set null,

  created_at     timestamptz not null default now()
);

alter table public.learning_evidence_proposals
  add constraint lep_decision_names_its_actor_ck check (
    (status = 'offered' and decided_by is null and decided_at is null)
    or (status <> 'offered' and decided_by is not null and decided_at is not null));

-- An accepted proposal points at the evidence a person actually created;
-- an offered or declined one points at nothing, because nothing was created.
alter table public.learning_evidence_proposals
  add constraint lep_only_acceptance_produces_evidence_ck check (
    (status = 'accepted' and learning_evidence_id is not null)
    or (status <> 'accepted' and learning_evidence_id is null));

create unique index lep_one_live_offer_per_skill_idx
  on public.learning_evidence_proposals (activity_id, skill_id)
  where status = 'offered';

create index lep_student_idx on public.learning_evidence_proposals (student_id, status, offered_at desc);
create index lep_activity_idx on public.learning_evidence_proposals (activity_id);

comment on table public.learning_evidence_proposals is
  'An OFFER to record work from an activity as evidence, and the human answer. '
  'The offer is not evidence. Accepting it records that the work RELATES to a '
  'skill, through the STEP 5 function that has always done so, and still says '
  'nothing about what the child has learned - that remains a separate judgement '
  'a person makes.';

comment on column public.learning_evidence_proposals.learning_evidence_id is
  'The STEP 5 evidence row a person created by accepting. Phase 2 never writes '
  'evidence itself and never writes to the profile at all.';

-- =============================================================================
-- Capability rows for the new resource
-- =============================================================================
-- A CHILD MAY RUN HER OWN MORNING WITHOUT RUNNING HER OWN CURRICULUM.
--
-- That sentence is the whole reason `learning_activity` is a separate resource
-- from `learning_plan`. Granting a child `learning_plan: update` so she could
-- press start would also let her reorder the path and mark steps finished as a
-- matter of record, and those are her mother's decisions. Splitting the
-- resource lets the matrix say yes to one and no to the other.
--
-- WHAT EACH RELATIONSHIP GETS, and every line of this is a product decision
-- that is reported at the gate rather than buried here:
--
--   student_self          read, update. She can open it, start, pause, come
--                         back, add a note and say she has finished. She cannot
--                         CREATE an activity (that is choosing her own
--                         curriculum) and cannot delete one.
--   guardian_full         everything, including approve - the evidence offer is
--                         an `approve`, because deciding that work counts as
--                         evidence about your child is not an edit.
--   guardian_standard     read, create, update. No approve: she may run the
--                         week and may not decide what becomes evidence.
--   guardian_view_only    read.
--   staff_assigned_write  read, create, update. An assigned teacher may set
--                         work and record how it went, and may not decide what
--                         enters the family's evidence record.
--   staff_assigned_read,
--   class_staff,
--   grant_evaluator,
--   grant_provider,
--   platform_support      read.
--   org_admin             read, create, update.

insert into app.capabilities (relationship, resource, action, requires_section, notes)
select r.relationship::app.relationship_kind, 'learning_activity'::app.resource_type,
       a.action::app.resource_action, r.requires_section, r.note
  from (values
    ('student_self',         array['read','update'],                                false,
     'a child may run her own morning: start, pause, come back, note, finish. She may not choose her own curriculum or delete the record'),
    ('guardian_full',        array['read','create','update','delete','approve'],     false, null),
    ('guardian_standard',    array['read','create','update'],                        false,
     'may run the week; may not decide what becomes evidence'),
    ('guardian_view_only',   array['read'],                                          false, null),
    ('staff_assigned_write', array['read','create','update'],                        false,
     'may set work and record how it went; evidence stays the family''s decision'),
    ('staff_assigned_read',  array['read'],                                          false, null),
    ('class_staff',          array['read'],                                          false, null),
    ('org_admin',            array['read','create','update'],                        false, null),
    ('grant_evaluator',      array['read'],                                          true,  null),
    ('grant_provider',       array['read'],                                          true,  null),
    ('platform_support',     array['read'],                                          false, null)
  ) as r(relationship, actions, requires_section, note)
  cross join lateral unnest(r.actions) as a(action);

-- =============================================================================
-- RLS
-- =============================================================================
-- Sessions, artifacts, Today decisions and evidence proposals are all rows
-- about one child. SECURITY INVOKER throughout, nothing sees further than the
-- person who called it, and no DELETE policy anywhere: a morning that happened
-- is not removed from the record.

alter table public.today_decisions                enable row level security;
alter table public.learning_activity_sessions     enable row level security;
alter table public.learning_activity_artifacts    enable row level security;
alter table public.learning_evidence_proposals    enable row level security;

create policy today_decisions_select on public.today_decisions
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_activity', 'read')));
create policy today_decisions_insert on public.today_decisions
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));
create policy today_decisions_update on public.today_decisions
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_activity', 'update'))
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));
-- A pin or a hide is about one day, and a person may take it back.
create policy today_decisions_delete on public.today_decisions
  for delete to authenticated
  using (app.can_student_action(student_id, 'learning_activity', 'update'));

create policy las_select on public.learning_activity_sessions
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_activity', 'read')));
create policy las_insert on public.learning_activity_sessions
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));
create policy las_update on public.learning_activity_sessions
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_activity', 'update'))
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));

create policy laa_select on public.learning_activity_artifacts
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_activity', 'read')));
create policy laa_insert on public.learning_activity_artifacts
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));

-- Offering is an ordinary part of running the week. DECIDING is not: an
-- evidence decision about a child is an `approve`, which the matrix gives to a
-- guardian with full access and to nobody else.
create policy lep_select on public.learning_evidence_proposals
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_activity', 'read')));
create policy lep_insert on public.learning_evidence_proposals
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_activity', 'update'));
create policy lep_update on public.learning_evidence_proposals
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_activity', 'approve'))
  with check (app.can_student_action(student_id, 'learning_activity', 'approve'));

grant select, insert, update, delete on public.today_decisions to authenticated;
grant select, insert, update on public.learning_activity_sessions to authenticated;
grant select, insert on public.learning_activity_artifacts to authenticated;
grant select, insert, update on public.learning_evidence_proposals to authenticated;

select app.assert_schema_invariants();
