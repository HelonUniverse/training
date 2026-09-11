-- =============================================================================
-- 0101  Two demo resources, marked as demo, and deliberately not enough
-- =============================================================================
-- The path engine must work when there is nothing to attach, because that is the
-- normal case for a family that has not bought a curriculum. So this seeds TWO
-- resources across a five-skill branch and leaves the rest empty on purpose: the
-- tests then prove both halves - that a resource is selected deterministically
-- when one exists, and that a skill still belongs on the path when none does.
--
-- They are marked. `is_demo` exists so that nothing in this repository can be
-- mistaken for a provider's material, and so a family looking at their own
-- library can tell what came from Nestra's test seed. Nestra owns the learning
-- model; providers own their content, and the boundary is a column rather than
-- a convention.
-- =============================================================================

alter table public.learning_resources
  add column is_demo boolean not null default false;

comment on column public.learning_resources.is_demo is
  'A Nestra test or demonstration resource. Never provider content, never '
  'presented to a family as curriculum they own.';

-- A resource has to hang off a course or a lesson, so the demo ones hang off a
-- demo course under Nestra's own first-party provider. It is named for what it
-- is, and no family is enrolled in it, so the "material this family already
-- has" key in app.path_resource_for never prefers it for the wrong reason.
insert into public.courses (id, provider_id, scope, name, description, active)
select 'dddddddd-0000-4000-8000-0000000000ff', p.id, 'catalog',
       'Nestra demonstration content (not curriculum)',
       'Holds the demo resources used to exercise the Learning Path engine.', true
  from public.curriculum_providers p where p.slug = 'nestra';

insert into public.learning_resources (id, course_id, kind, title, description, is_demo)
values ('dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-0000000000ff', 'practice',
        'Demo: equivalent fractions with paper strips',
        'A Nestra demonstration resource used to exercise the Learning Path '
        'engine. Not curriculum, not provider content.', true),
       ('dddddddd-0000-4000-8000-000000000002', 'dddddddd-0000-4000-8000-0000000000ff', 'practice',
        'Demo: comparing two fractions',
        'A Nestra demonstration resource used to exercise the Learning Path '
        'engine. Not curriculum, not provider content.', true);

-- `confirmed` is false, and that is not an oversight: nobody has confirmed
-- these mappings, because nobody made them - they are a seed. The constraint on
-- resource_skills requires a named person behind a confirmation, and inventing
-- one to make a seed look authoritative is exactly the kind of small lie this
-- schema is built to refuse.
insert into public.resource_skills (resource_id, skill_id, source_type, confirmed)
select 'dddddddd-0000-4000-8000-000000000001', k.id, 'manual', false
  from public.skills k where k.code = 'NST.FR.3';

insert into public.resource_skills (resource_id, skill_id, source_type, confirmed)
select 'dddddddd-0000-4000-8000-000000000002', k.id, 'manual', false
  from public.skills k where k.code = 'NST.FR.5';

do $check$
declare v_n int;
begin
  select count(*) into v_n from public.learning_resources where is_demo;
  if v_n <> 2 then
    raise exception 'expected 2 demo resources, got %', v_n;
  end if;
  select count(*) into v_n from public.resource_skills rs
    join public.learning_resources r on r.id = rs.resource_id where r.is_demo;
  if v_n <> 2 then
    raise exception 'expected 2 demo resource mappings, got %', v_n;
  end if;
end $check$;

select app.assert_schema_invariants();
