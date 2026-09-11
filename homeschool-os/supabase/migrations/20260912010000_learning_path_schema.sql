-- =============================================================================
-- 0098  The Learning Path: a proposal a parent can argue with
-- =============================================================================
-- Student -> Skills -> Evidence -> Readiness -> Learning Path. This is the last
-- arrow, and it is the one where every education product turns back into a
-- school. The failure is always the same shape: the path stops being "what could
-- we explore next" and becomes "what a child of this age is supposed to have
-- finished by now", and a mother opens the app to find a list of what her son
-- has not done.
--
-- SO THE PATH IS A PROPOSAL AND NOTHING ELSE.
--
-- Nothing here writes to student_skills, student_skill_events or
-- student_skill_overrides. 0101 adds a structural check that refuses the path
-- functions if their source so much as contains an INSERT or UPDATE against any
-- of them. Being on a path is not evidence. Approving a path is not evidence.
-- Finishing a node is not mastery. Those three sentences are the whole design,
-- and each of them is enforced rather than asserted.
--
-- WHAT IS STORED, and why each piece is separate:
--
--   A. what Nestra knows about the child      evidence_context on each node
--   B. what the family wants to explore       reason_code + the goals snapshot
--   C. what skills logically connect          prerequisites_considered
--   D. what resources are available           resource_id, or an honest null
--
-- They are deliberately four columns and not one number. The moment they are
-- collapsed into a score, the score becomes "readiness: 72%", and a percentage
-- about a child is the thing this entire step exists to prevent.
--
-- VERSIONS, NOT EDITS. An approved path is never rewritten. New evidence
-- produces a NEW version, proposed, that a parent can read beside the old one -
-- and the old one stays exactly as she approved it. A path that silently changed
-- under her is a path she cannot trust, and a record that cannot be
-- reconstructed two years later is not a record.
-- =============================================================================

-- --- 1. Why a skill is on the path -------------------------------------------
-- The structured code is the source of truth. Prose is presentation: a sentence
-- generated for a screen can be regenerated, translated, or improved, and none
-- of that may change what the system actually did.

create type app.path_node_reason as enum (
  'parent_goal',                   -- a person said this is what they want to work on
  'active_plan_priority',          -- named in an active learning plan's priority skills
  'revisit_requested',             -- a person asked to come back to it
  'diagnostic_frontier',           -- the diagnostic stopped near this boundary
  'uncertain_boundary',            -- there is some evidence and it is not settled
  'continue_connected_skill',      -- it follows directly from something characterized
  'prerequisite_support',          -- it underpins a node above, and is not characterized
  'curriculum_resource_available', -- a resource the family already has covers it
  'enrichment',                    -- application or extension of something confirmed
  'human_added');                  -- a parent put it there herself

comment on type app.path_node_reason is
  'The complete list of ways a skill can arrive on a path. Grade level, age, '
  'benchmark expectations and cohort norms are deliberately absent and may not '
  'be added: a path is what this family is doing next, never what a child of '
  'this age is supposed to be doing.';

-- --- 2. What made this skill reasonable to explore ---------------------------
-- Readiness is a set of reasons, not a number. There is no percentage here, no
-- rank, and no global level, because a child does not have one.

create type app.path_readiness_reason as enum (
  'prerequisites_characterized',   -- what it builds on has useful evidence
  'prerequisite_uncertain',        -- one of them is thin, and that is said out loud
  'prerequisite_not_characterized',-- one of them Nestra knows nothing about yet
  'no_prerequisites_in_graph',     -- nothing is known to come before it
  'has_usable_evidence',           -- there is evidence about this skill itself
  'no_evidence_yet',               -- there is not, and that is a fact about Nestra
  'uncertainty_at_this_boundary',  -- evidence exists but does not settle it
  'named_by_a_person',             -- a goal, a plan or a request put it here
  'diagnostic_stopped_near_here',  -- the last session ended around this skill
  'human_confirmed_secure',        -- a person has already confirmed it
  'previously_on_a_path');         -- it has been proposed before

-- --- 3. The life of a path ---------------------------------------------------

create type app.path_status as enum (
  'proposed',   -- Nestra suggested it; nobody has decided
  'approved',   -- a person said yes. This version is now the live one
  'paused',     -- approved, and set down for now
  'rejected',   -- a person said no. Kept, because "no" is information
  'archived');  -- retired, or superseded by a version she approved instead

create type app.path_node_status as enum (
  'proposed', 'approved', 'removed', 'completed');

create type app.path_event_kind as enum (
  'generated', 'regenerated', 'approved', 'rejected', 'paused', 'resumed',
  'archived', 'node_added', 'node_removed', 'node_reordered', 'node_completed');

create type app.path_regeneration_reason as enum (
  'parent_requested',
  'new_confirmed_evidence',
  'diagnostic_completed',
  'goals_changed',
  'refresh_advisory');

-- --- 4. Things Nestra says out loud rather than deciding quietly -------------
-- A parent may put a skill anywhere she likes. When she puts one before
-- something it usually builds on, Nestra neither refuses nor pretends the two
-- orders are equivalent - it says what it knows and lets her decide.

create type app.path_warning_code as enum (
  'prerequisite_usually_comes_first',
  'no_resource_available_yet',
  'already_confirmed_by_a_person');

-- =============================================================================
-- The path
-- =============================================================================

create table public.learning_paths (
  id                    uuid primary key default gen_random_uuid(),
  student_id            uuid not null references public.students(id) on delete cascade,
  organization_id       uuid references public.organizations(id) on delete set null,
  family_id             uuid references public.families(id) on delete set null,

  -- what this path is about. Both optional: a path may be scoped to a branch of
  -- the skill graph, to a subject, or to neither.
  subject_id            uuid references public.subjects(id) on delete set null,
  branch_root_skill_id  uuid references public.skills(id) on delete set null,

  version               integer not null default 1,
  supersedes_id         uuid references public.learning_paths(id) on delete set null,
  status                app.path_status not null default 'proposed',

  rule_version          text not null,
  node_horizon          integer not null,

  -- Everything the engine looked at, frozen. Read two years later, "why did it
  -- suggest equivalent fractions" is answerable without re-deriving a profile
  -- that has long since moved on - the same reason Phase 5 stores its starting
  -- context.
  generation_inputs     jsonb not null default '{}'::jsonb,

  regeneration_reason   app.path_regeneration_reason,
  regeneration_note     text,
  parent_context        text,

  record_provenance     app.record_provenance not null default 'system_computed',

  proposed_at           timestamptz not null default now(),
  approved_by           uuid references public.profiles(id),
  approved_at           timestamptz,
  rejected_by           uuid references public.profiles(id),
  rejected_at           timestamptz,
  paused_at             timestamptz,
  archived_at           timestamptz,

  created_at            timestamptz not null default now(),
  created_by            uuid references public.profiles(id),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.profiles(id)
);

-- A path is a proposal until a person says otherwise, and the person is named.
alter table public.learning_paths
  add constraint learning_paths_approval_names_its_actor_ck check (
    (status <> 'approved' and status <> 'paused')
    or (approved_by is not null and approved_at is not null));

alter table public.learning_paths
  add constraint learning_paths_rejection_names_its_actor_ck check (
    status <> 'rejected' or (rejected_by is not null and rejected_at is not null));

-- The horizon is small on purpose. This answers "what should we explore next",
-- not "generate the school year", and the bound is structural so that a future
-- change to it is a migration somebody has to justify.
alter table public.learning_paths
  add constraint learning_paths_horizon_is_small_ck
    check (node_horizon between 3 and 5);

-- One live path per branch per child. Versions accumulate; only one of them is
-- the one in force.
create unique index learning_paths_one_live_idx
  on public.learning_paths (student_id, coalesce(branch_root_skill_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('approved', 'paused');

create index learning_paths_student_idx
  on public.learning_paths (student_id, status, version desc);

comment on table public.learning_paths is
  'A proposed sequence of skills to explore next. Never a curriculum, never a '
  'grade sequence, never a list of what a child has not done. Generating one '
  'changes nothing about the child; only a person approving it makes it the '
  'plan, and even then it is a plan, not a record of learning.';

comment on column public.learning_paths.node_horizon is
  'How many skills this path proposes. Small deliberately: the question is what '
  'to explore next, not what the year looks like.';

-- =============================================================================
-- The nodes
-- =============================================================================

create table public.learning_path_nodes (
  id                       uuid primary key default gen_random_uuid(),
  path_id                  uuid not null references public.learning_paths(id) on delete cascade,
  student_id               uuid not null references public.students(id) on delete cascade,
  skill_id                 uuid not null references public.skills(id) on delete cascade,

  position                 integer not null,
  reason_code              app.path_node_reason not null,

  -- STRUCTURED, and the source of truth. A sentence on a screen is generated
  -- from these; it never replaces them.
  reason_detail            jsonb not null default '{}'::jsonb,
  readiness_reasons        app.path_readiness_reason[] not null default '{}',
  prerequisites_considered uuid[] not null default '{}',

  -- What Nestra knew about this skill when the node was made. Separate from the
  -- reason, because "why it is here" and "what we know" are different questions
  -- and a parent asks both.
  evidence_context         jsonb not null default '{}'::jsonb,

  -- Optional, and honestly optional. A skill belongs on a path whether or not
  -- anybody has material for it, and an empty resource is represented rather
  -- than filled with something invented.
  resource_id              uuid references public.learning_resources(id) on delete set null,
  resource_note            text,
  estimated_minutes        integer,

  status                   app.path_node_status not null default 'proposed',
  supports_node_id         uuid references public.learning_path_nodes(id) on delete cascade,

  added_by_human           boolean not null default false,
  added_by                 uuid references public.profiles(id),
  removed_by               uuid references public.profiles(id),
  removed_at               timestamptz,
  completed_by             uuid references public.profiles(id),
  completed_at             timestamptz,

  created_at               timestamptz not null default now()
);

alter table public.learning_path_nodes
  add constraint lpn_position_is_positive_ck check (position > 0);

alter table public.learning_path_nodes
  add constraint lpn_estimated_minutes_is_time_not_a_score_ck
    check (estimated_minutes is null or estimated_minutes between 1 and 600);

-- A node a person added says so, and names her.
alter table public.learning_path_nodes
  add constraint lpn_human_added_names_its_actor_ck
    check (not added_by_human or added_by is not null);

alter table public.learning_path_nodes
  add constraint lpn_removal_names_its_actor_ck
    check (status <> 'removed' or (removed_by is not null and removed_at is not null));

-- One node per skill per path. A path that proposes the same skill twice is a
-- bug, and a parent who adds a skill already present should be told so.
create unique index lpn_one_node_per_skill_idx
  on public.learning_path_nodes (path_id, skill_id);

-- Deferrable, because reordering swaps positions inside one statement and a
-- swap is momentarily a duplicate.
alter table public.learning_path_nodes
  add constraint lpn_position_is_unique_ck unique (path_id, position)
  deferrable initially deferred;

create index lpn_path_idx on public.learning_path_nodes (path_id, position);

comment on column public.learning_path_nodes.reason_detail is
  'The structured account of why this skill is here. Generated prose is '
  'presentation only and is never the source of truth.';
comment on column public.learning_path_nodes.resource_id is
  'Optional. A skill can sit on a path with nothing attached; that is said '
  'plainly in resource_note rather than filled with invented material.';
comment on column public.learning_path_nodes.supports_node_id is
  'Set when this node exists to support the one it points at. One level only - '
  'there is no remediation staircase.';

-- =============================================================================
-- What people did to it
-- =============================================================================
-- Append-only. A parent's decision to remove a skill is not undone by the next
-- regeneration, and the only way to guarantee that is to keep the decision.

create table public.learning_path_events (
  id              uuid primary key default gen_random_uuid(),
  path_id         uuid not null references public.learning_paths(id) on delete cascade,
  student_id      uuid not null references public.students(id) on delete cascade,
  kind            app.path_event_kind not null,
  node_id         uuid references public.learning_path_nodes(id) on delete set null,
  skill_id        uuid references public.skills(id) on delete set null,
  from_position   integer,
  to_position     integer,
  note            text,
  warnings        jsonb not null default '[]'::jsonb,
  actor           uuid references public.profiles(id),
  created_at      timestamptz not null default now()
);

create index learning_path_events_path_idx
  on public.learning_path_events (path_id, created_at);

create trigger learning_path_events_append_only
  before update or delete on public.learning_path_events
  for each row execute function app.forbid_mutation();

comment on table public.learning_path_events is
  'Every human decision about a path, kept. Regeneration reads this so a skill '
  'a parent removed does not quietly come back, and so a warning she was shown '
  'is still on the record afterwards.';

-- =============================================================================
-- RLS: a path is a learning plan, and the capability matrix already knows what
-- that means. Approval is guardian_full only, which is why the RPC checks
-- 'approve' and not 'update'.
-- =============================================================================

alter table public.learning_paths        enable row level security;
alter table public.learning_path_nodes   enable row level security;
alter table public.learning_path_events  enable row level security;

create policy learning_paths_select on public.learning_paths
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_plan', 'read')));

create policy learning_paths_insert on public.learning_paths
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'create'));

create policy learning_paths_update on public.learning_paths
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_plan', 'update'))
  with check (app.can_student_action(student_id, 'learning_plan', 'update'));

create policy lpn_select on public.learning_path_nodes
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_plan', 'read')));

create policy lpn_insert on public.learning_path_nodes
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'create'));

create policy lpn_update on public.learning_path_nodes
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_plan', 'update'))
  with check (app.can_student_action(student_id, 'learning_plan', 'update'));

create policy learning_path_events_select on public.learning_path_events
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_plan', 'read')));

create policy learning_path_events_insert on public.learning_path_events
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'update'));

-- No DELETE policy on any of the three. A path is retired by archiving it, and
-- the events behind it are not removable at all.

grant select, insert, update on public.learning_paths to authenticated;
grant select, insert, update on public.learning_path_nodes to authenticated;
grant select, insert on public.learning_path_events to authenticated;

select app.assert_schema_invariants();
