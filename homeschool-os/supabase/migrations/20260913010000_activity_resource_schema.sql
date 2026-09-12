-- =============================================================================
-- 0103  STEP 8 PHASE 1 - what a child can actually DO next
-- =============================================================================
-- STEP 7 answers "what would be reasonable to explore next". This is the layer
-- under it: given a skill the path proposes, what is there to actually do on
-- Monday morning. And the whole risk of this layer is one sentence:
--
--   the moment a resource becomes the unit of learning, the provider's
--   table of contents becomes the child's education.
--
-- So the skill is the model and the resource is one way to reach it. A skill
-- survives its resource disappearing. A family with no curriculum at all still
-- has a complete system, because "use measuring cups in the kitchen" is a first
-- class activity here and not a degraded one.
--
-- WHAT THIS LAYER MAY NOT DO, and each of these is enforced in 0107 rather than
-- asserted here:
--
--   1. It may not read the standards catalogue to choose anything.
--   2. It may not read grade or age to choose anything.
--   3. It may not write to the profile. Selecting is not evidence, starting is
--      not evidence, and completing an activity is not mastery.
--   4. It may not use an unconfirmed skill mapping to decide what a child gets.
--   5. It may not generate an activity from a goal_target node - that node is
--      where the family is heading, not a claim the child is ready.
--   6. It may not quietly reteach a skill a person has confirmed secure.
--
-- AND THE ONE THAT IS EASIEST TO GET WRONG: no eligible resource is a VALID
-- answer. Not an error, not an empty state to be filled with something invented,
-- and above all not a reason to move the child to a different skill. The
-- pedagogical model does not bend around what happens to be in the catalogue.
-- =============================================================================

-- --- 1. What kind of thing this is -------------------------------------------
-- The point of this list is its width. A schema whose only shapes are worksheet
-- and quiz has already decided what learning looks like in a homeschool, and it
-- has decided wrong: a great deal of real work in a real kitchen is a
-- manipulative activity that nobody will ever upload.
--
-- Phase 1 does not ship content for most of these, and does not need to. What
-- matters is that adding a movement activity later is data, not a migration and
-- an argument.

-- It is `learning_activity_kind` and not `activity_kind` because STEP 4 already
-- owns that name for a different vocabulary: app.activity_kind is what a family
-- DID (field trip, music, life skills) on an activity log. Collapsing the two
-- would force "manipulative" and "field trip" into one list and lose the
-- distinction between a log of a day and a piece of work for a skill.

create type app.learning_activity_kind as enum (
  'lesson',
  'practice',
  'question',                     -- a single problem or prompt
  'short_response',
  'reading',
  'video',
  'worksheet',
  'project',
  'experiment',
  'game',
  'demonstration',
  'movement',                     -- physical activity
  'manipulative',                 -- objects in hands: cups, blocks, coins
  'uploaded_work',
  'parent_led',
  'external_curriculum_lesson',
  'enrichment');

comment on type app.learning_activity_kind is
  'The shape of a piece of work. Deliberately wide so that nothing in this '
  'schema assumes all learning is a worksheet or a quiz. The declaration order '
  'carries no preference: ranking sorts on the text, so nobody can read a '
  'pedagogical claim into the position of a label.';

-- --- 2. Modality, which is a property of the ACTIVITY ------------------------
-- Not of the child. This distinction is the entire reason the vocabulary is
-- scoped to resources and activity instances and never appears on students.
--
-- "Visual learner" is a claim about a person that the evidence for does not
-- exist, and once a column says it, every future feature routes around it: the
-- child who was labelled at seven gets videos at eleven because a row said so.
-- What Nestra may eventually say is "they have chosen hands-on activities
-- recently", which is an observation about choices and stays true or becomes
-- false on its own. Phase 1 builds no preference learning at all.

create type app.learning_activity_modality as enum (
  'visual',
  'auditory',
  'reading_writing',
  'hands_on',
  'movement',
  'interactive',
  'mixed',
  'unspecified');

comment on type app.learning_activity_modality is
  'How an activity is done. A property of the material, never of the child: '
  'there is no learning-style column on a student and there may not be one. '
  'Modality is context for choosing a tool, not a diagnosis.';

-- --- 3. Language -------------------------------------------------------------
-- Explicit where known, because a Spanish-speaking family being handed English
-- material with no warning is a worse failure than being handed nothing.
-- `language_neutral` is a real answer - a set of fraction tiles has no language -
-- and it is not the same as `unknown`.

create type app.learning_resource_language as enum (
  'en', 'es', 'bilingual', 'language_neutral', 'unknown');

comment on type app.learning_resource_language is
  'The language of the material. language_neutral means the material genuinely '
  'has no language (manipulatives, some games); unknown means nobody has said. '
  'Nestra does not machine-translate a provider''s content to make a match.';

-- --- 4. Availability, which is NOT a pedagogical judgement -------------------
-- Kept deliberately separate from relevance. A resource behind a subscription
-- the family let lapse is exactly as educationally suitable as it was last
-- month; it is simply not openable today. Collapsing the two would let a
-- billing state quietly rewrite what a child is learning.

create type app.learning_resource_availability as enum (
  'available',
  'unavailable',
  'provider_disconnected',
  'requires_subscription',
  'archived',
  'unknown');

comment on type app.learning_resource_availability is
  'Whether this material can be opened today. Never a statement about whether '
  'it is the right material: unavailable is a fact about access, not about the '
  'child and not about the resource''s value.';

-- --- 5. Who owns the content -------------------------------------------------
-- Nestra does not claim rights it does not have. A link to a provider's page is
-- a link; it is not Nestra's curriculum, and the column exists so that no
-- screen, export or report can imply otherwise.

create type app.content_ownership as enum (
  'nestra_owned',
  'provider_owned',
  'family_created',
  'open_licensed',
  'public_link',
  'unknown');

comment on type app.content_ownership is
  'Who owns this material. Nestra claims nothing it does not own; provider '
  'content stays the provider''s and is labelled as such wherever it appears.';

-- --- 6. The life of one activity --------------------------------------------
-- Read `completed` carefully. It means the activity was worked through. It says
-- NOTHING about whether the child has learned the skill, and 0107 refuses any
-- code path that tries to make it say so.
--
-- And `skipped` / `not_today` are not failure. A morning that did not happen is
-- a morning that did not happen. Every product that turns those into a red mark
-- teaches a parent to stop being honest with it.

create type app.learning_activity_status as enum (
  'proposed',    -- Nestra put it forward; nobody has decided
  'selected',    -- it is the one for this skill right now
  'available',   -- ready to open
  'started',
  'completed',   -- the ACTIVITY was completed. Not the skill.
  'skipped',     -- the family moved past it. Not a failure.
  'not_today',   -- not today. Also not a failure.
  'replaced',    -- a person chose something else for the same skill
  'archived');

comment on type app.learning_activity_status is
  'The life of one activity instance. completed means the activity was worked '
  'through and says nothing at all about the skill; skipped and not_today are '
  'ordinary facts about a week, never failure and never a state change.';

-- --- 7. Where an activity came from ------------------------------------------
-- Five different sentences that a single "auto" flag would flatten into a lie.
-- In particular a deterministic ORDER BY is not a model, and labelling it AI
-- would misrepresent the one column somebody would read to find out how a child
-- came to be doing this.

create type app.learning_activity_origin as enum (
  'deterministic_system_selection',  -- an ORDER BY chose it. No model was asked.
  'human_selected',                  -- a person picked it from the catalogue
  'human_created',                   -- a person invented it
  'provider_imported',
  'ai_proposed_unreviewed');         -- may never be presented as chosen

comment on type app.learning_activity_origin is
  'How this activity came to exist. deterministic_system_selection is an '
  'ordering over confirmed mappings and is not AI; human_created is not system '
  'generated. Each is a different claim and they are kept apart.';

-- --- 8. Why THIS resource ----------------------------------------------------
-- Structured, so the answer survives translation and rewording. Prose is
-- presentation and is regenerated from these; it never replaces them.

create type app.learning_resource_reason as enum (
  'confirmed_skill_match',      -- a person confirmed this material teaches it
  'active_curriculum',          -- the family is enrolled in the course it belongs to
  'parent_provider_preference', -- reserved: no such preference is represented yet
  'modality_match',             -- the caller explicitly asked for this modality
  'language_match',             -- the caller explicitly required this language
  'deterministic_tiebreak');    -- more than one survived, and the order decided

create type app.learning_activity_event_kind as enum (
  'selected', 'created', 'replaced', 'started', 'completed',
  'skipped', 'not_today', 'archived');

-- =============================================================================
-- The catalogue grows the metadata it was always going to need
-- =============================================================================
-- STEP 5 shipped learning_resources with a title, a kind and a link, which was
-- the honest minimum at the time. Selecting between resources needs more, and
-- every column added here is a fact somebody can state rather than a score
-- somebody would have to invent.

alter table public.learning_resources
  add column provider_id       uuid references public.curriculum_providers(id) on delete set null,
  add column external_id       text,
  add column activity_kind     app.learning_activity_kind,
  add column modality          app.learning_activity_modality not null default 'unspecified',
  add column language          app.learning_resource_language not null default 'unknown',
  add column estimated_minutes integer,
  add column availability      app.learning_resource_availability not null default 'available',
  add column content_ownership app.content_ownership not null default 'unknown',
  add column integration_mode  app.integration_mode not null default 'manual',
  add column license_note      text;

alter table public.learning_resources
  add constraint learning_resource_minutes_is_time_not_a_score_ck
    check (estimated_minutes is null or estimated_minutes between 1 and 600);

-- The same provider row twice for the same external lesson is a duplicate, and
-- a family would see the same thing offered as two different options.
create unique index learning_resources_provider_external_idx
  on public.learning_resources (provider_id, external_id)
  where provider_id is not null and external_id is not null;

create index learning_resources_availability_idx
  on public.learning_resources (availability);

-- `activity_kind` is deliberately NULLABLE and deliberately NOT back-filled.
-- Every existing row has a coarse `kind`; nobody has said what finer shape it
-- is, and guessing "a link is an external curriculum lesson" would be Nestra
-- inventing metadata and then ranking on it. Null means nobody has said.
comment on column public.learning_resources.activity_kind is
  'The finer shape of this material, where somebody has said. Null means '
  'nobody has - it is never inferred from the coarse kind.';

-- `availability` defaults to `available`, and that is a faithful statement of
-- what the schema already meant rather than a new claim: before this migration
-- every catalogue row was openable as far as the system was concerned. The
-- other labels are POSITIVE statements that something is in the way, and only
-- those make a resource ineligible. `unknown` is for integrations that report
-- an indeterminate state.
comment on column public.learning_resources.availability is
  'Whether this can be opened today. Defaults to available because that is what '
  'every pre-existing catalogue row already meant; the other labels are '
  'positive statements that access is blocked.';

comment on column public.learning_resources.integration_mode is
  'How work with this material is ACTUALLY tracked today. `integrated` may only '
  'be set where a live integration exists. Nothing in Phase 1 is integrated.';

comment on column public.learning_resources.license_note is
  'What Nestra is permitted to do with this material. Nestra claims no rights '
  'it does not possess, and an empty note is not permission.';

-- =============================================================================
-- Learning activities: one particular use, by one particular child
-- =============================================================================
-- The resource is the reusable definition; this is the instance. They are
-- separate because the same worksheet used by two children on two paths for two
-- reasons is two different facts, and because an activity does not need a
-- resource at all.
--
-- skill_id is NOT NULL and resource_id is nullable, and that asymmetry is the
-- whole architecture in two lines: the skill is what the child is exploring and
-- the resource is one way to explore it.

create table public.learning_activities (
  id                  uuid primary key default gen_random_uuid(),
  student_id          uuid not null references public.students(id) on delete cascade,
  family_id           uuid references public.families(id) on delete set null,
  organization_id     uuid references public.organizations(id) on delete set null,

  -- The target. Always present, and it does not move: replacing a resource
  -- keeps this exactly as it was.
  skill_id            uuid not null references public.skills(id) on delete cascade,

  -- Where it came from in the plan. Both optional: a parent may create an
  -- activity for a skill with no path at all.
  path_id             uuid references public.learning_paths(id) on delete set null,
  path_node_id        uuid references public.learning_path_nodes(id) on delete set null,

  -- Optional, and honestly optional. No resource is a valid activity.
  resource_id         uuid references public.learning_resources(id) on delete set null,
  provider_id         uuid references public.curriculum_providers(id) on delete set null,

  activity_kind       app.learning_activity_kind,
  modality            app.learning_activity_modality not null default 'unspecified',
  language            app.learning_resource_language not null default 'unknown',

  title               text not null,
  parent_instructions text,
  child_instructions  text,
  estimated_minutes   integer,

  status              app.learning_activity_status not null default 'proposed',
  origin              app.learning_activity_origin not null,
  record_provenance   app.record_provenance not null,

  -- Why this one. Structured; the sentence on the screen is generated from it.
  selection_reasons   app.learning_resource_reason[] not null default '{}',
  -- Everything the selector looked at, frozen. Read two years later, "why this
  -- worksheet" is answerable without re-deriving a catalogue that has moved on.
  selection_context   jsonb not null default '{}'::jsonb,
  rule_version        text,

  -- Replacement history. Resource A was not wrong and the child did not fail;
  -- a person preferred something else, and both directions are kept so the
  -- record reads the same from either end.
  replaces_activity_id    uuid references public.learning_activities(id) on delete set null,
  replaced_by_activity_id uuid references public.learning_activities(id) on delete set null,
  replacement_note        text,

  selected_by         uuid references public.profiles(id),
  created_by          uuid references public.profiles(id),
  started_at          timestamptz,
  completed_at        timestamptz,
  completed_by        uuid references public.profiles(id),
  closed_at           timestamptz,   -- skipped / not_today / replaced / archived
  closed_by           uuid references public.profiles(id),

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- A deterministic selection is not a person and must not name one; a person's
-- choice must name her. Both halves matter: the first stops the system taking
-- credit for a decision nobody made, the second stops a decision appearing from
-- nowhere.
alter table public.learning_activities
  add constraint la_selection_names_its_actor_ck check (
    case origin
      when 'deterministic_system_selection'
        then selected_by is null and rule_version is not null
      when 'human_selected' then selected_by is not null
      when 'human_created'  then created_by  is not null
      else true
    end);

-- A human-created activity is the family's own idea. It has no catalogue
-- resource by definition - a person choosing something from the catalogue is
-- `human_selected`, which is a different sentence.
alter table public.learning_activities
  add constraint la_human_created_has_no_catalogue_resource_ck check (
    origin <> 'human_created' or resource_id is null);

-- Provenance restates origin in the vocabulary the rest of the schema audits
-- on, and the two may never disagree. A deterministic ORDER BY labelled as an
-- AI proposal would be a false statement in the column an evaluator reads.
alter table public.learning_activities
  add constraint la_provenance_matches_origin_ck check (
    (origin = 'deterministic_system_selection' and record_provenance = 'system_computed')
    or (origin = 'human_selected'  and record_provenance = 'human_entered')
    or (origin = 'human_created'   and record_provenance = 'human_entered')
    or (origin = 'provider_imported' and record_provenance = 'provider_import')
    or (origin = 'ai_proposed_unreviewed' and record_provenance = 'ai_proposed_unreviewed'));

alter table public.learning_activities
  add constraint la_minutes_is_time_not_a_score_ck
    check (estimated_minutes is null or estimated_minutes between 1 and 600);

-- Each ending names its moment, and the ones a person caused name the person.
alter table public.learning_activities
  add constraint la_lifecycle_is_attributed_ck check (
    (status <> 'started'   or started_at is not null)
    and (status <> 'completed' or (completed_at is not null and completed_by is not null))
    and (status not in ('skipped', 'not_today', 'replaced', 'archived')
         or closed_at is not null));

-- Only something that was replaced names a successor. Deliberately one-way
-- rather than an iff: the replacement is written as three statements (set the
-- old one aside, insert the new one, then link them), because the one-live-per-
-- node index means the new row cannot exist while the old one is still live.
-- An iff would fail in the gap, and loosening the index instead would allow two
-- live activities on one node - which is the thing worth preventing. The
-- authoritative link is `replaces_activity_id` on the new row, set at insert.
alter table public.learning_activities
  add constraint la_only_a_replaced_activity_names_a_successor_ck check (
    replaced_by_activity_id is null or status = 'replaced');

alter table public.learning_activities
  add constraint la_does_not_replace_itself_ck check (
    replaces_activity_id is distinct from id
    and replaced_by_activity_id is distinct from id);

-- One live activity per path node. Live is proposed/selected/available/started:
-- once something is completed, skipped, put off or replaced, the slot is free
-- again, because a parent choosing something different after a skip is ordinary
-- and refusing it would be the index telling her how to run her week.
create unique index la_one_live_per_node_idx
  on public.learning_activities (path_node_id)
  where path_node_id is not null
    and status in ('proposed', 'selected', 'available', 'started');

create index la_student_idx on public.learning_activities (student_id, status, created_at desc);
create index la_skill_idx   on public.learning_activities (student_id, skill_id);
create index la_path_idx    on public.learning_activities (path_id);
create index la_resource_idx on public.learning_activities (resource_id);

select app.attach_updated_at('public.learning_activities');

comment on table public.learning_activities is
  'One particular use of one piece of material - or of no material at all - by '
  'one child for one skill. Creating it is not evidence, starting it is not '
  'evidence, and completing it is not mastery. The skill is the model; the '
  'resource is one way to reach it, and the row is valid without one.';

comment on column public.learning_activities.resource_id is
  'Optional, and honestly optional. "Practise with measuring cups in the '
  'kitchen" is a complete activity. No eligible resource is a valid answer and '
  'is never filled in with something invented.';

comment on column public.learning_activities.skill_id is
  'The target, and it does not move. Replacing the resource keeps this '
  'unchanged: that is what makes replacement a change of material rather than a '
  'change of what the child is working on.';

comment on column public.learning_activities.selection_reasons is
  'The structured answer to "why this one". Generated prose is presentation '
  'only and never the source of truth.';

-- =============================================================================
-- What happened to it
-- =============================================================================
-- Append-only, for the same reason the path events are: a parent's decision to
-- replace a resource, or to put a morning off, is a fact about her week and the
-- next selection does not get to erase it.

create table public.learning_activity_events (
  id               uuid primary key default gen_random_uuid(),
  activity_id      uuid not null references public.learning_activities(id) on delete cascade,
  student_id       uuid not null references public.students(id) on delete cascade,
  kind             app.learning_activity_event_kind not null,
  skill_id         uuid references public.skills(id) on delete set null,
  from_resource_id uuid references public.learning_resources(id) on delete set null,
  to_resource_id   uuid references public.learning_resources(id) on delete set null,
  reasons          app.learning_resource_reason[] not null default '{}',
  detail           jsonb not null default '{}'::jsonb,
  note             text,
  actor            uuid references public.profiles(id),
  created_at       timestamptz not null default now()
);

create index learning_activity_events_activity_idx
  on public.learning_activity_events (activity_id, created_at);
create index learning_activity_events_student_idx
  on public.learning_activity_events (student_id, created_at desc);

create trigger learning_activity_events_append_only
  before update or delete on public.learning_activity_events
  for each row execute function app.forbid_mutation();

comment on table public.learning_activity_events is
  'Every decision a person made about an activity, kept. A skip is recorded '
  'because it happened, not because it means anything about the child.';

-- =============================================================================
-- RLS
-- =============================================================================
-- The catalogue is shared vocabulary and stays readable exactly as STEP 5 left
-- it. A child's activity instances are not: they are learning-plan rows about
-- one student, and the two-question capability model already knows what that
-- means. SECURITY INVOKER throughout, so nothing here can see further than the
-- person who called it.

alter table public.learning_activities        enable row level security;
alter table public.learning_activity_events   enable row level security;

create policy learning_activities_select on public.learning_activities
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_plan', 'read')));

create policy learning_activities_insert on public.learning_activities
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'create'));

create policy learning_activities_update on public.learning_activities
  for update to authenticated
  using (app.can_student_action(student_id, 'learning_plan', 'update'))
  with check (app.can_student_action(student_id, 'learning_plan', 'update'));

create policy learning_activity_events_select on public.learning_activity_events
  for select to authenticated
  using (student_id in (select app.my_student_ids_for('learning_plan', 'read')));

create policy learning_activity_events_insert on public.learning_activity_events
  for insert to authenticated
  with check (app.can_student_action(student_id, 'learning_plan', 'update'));

-- No DELETE policy on either. An activity is retired by archiving it, and the
-- events behind it are not removable at all.

grant select, insert, update on public.learning_activities to authenticated;
grant select, insert on public.learning_activity_events to authenticated;

select app.assert_schema_invariants();
