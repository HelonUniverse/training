-- =============================================================================
-- 0106  A demonstration library, marked as one, and deliberately full of gaps
-- =============================================================================
-- Enough material to exercise the selector along the fractions branch STEP 7
-- already uses, and not one row more. This is NOT a curriculum and must never
-- be presented as one: every row is `is_demo`, owned by Nestra, and named so
-- that nobody reading a screen could mistake it for something a provider wrote
-- or something the family bought.
--
-- THE GAPS ARE THE POINT. NST.FR.4 gets nothing at all, so the tests can prove
-- that a skill with no material is still a perfectly good skill and that the
-- honest empty answer is returned rather than the engine walking sideways to
-- find something. NST.FR.2 gets material that is deliberately blocked, so
-- "there is nothing" and "there are two and the subscription lapsed" can be
-- told apart.
--
-- AND NOTHING HERE IS CONFIRMED. Every mapping lands with confirmed = false,
-- exactly as 0101's did, because nobody has confirmed them - they are a seed,
-- and inventing a confirming person to make seed data authoritative is the
-- precise lie this schema exists to refuse. A seeded confirmation would also
-- mean that deploying this migration silently started choosing material for
-- real children.
--
-- So the tests confirm what they need, as a named fixture guardian, and that is
-- a better proof than a pre-confirmed seed would have been: it exercises the
-- whole "a person decides" loop rather than assuming its outcome.
-- =============================================================================

-- A second demo course, so that "material the family is enrolled in" has
-- something to be true OF. Enrolment is never seeded - a test enrols a child
-- when it wants to prove that key of the ordering fires.
insert into public.courses (id, provider_id, scope, name, description, active)
select 'dddddddd-0000-4000-8000-0000000000fe', p.id, 'catalog',
       'Nestra demonstration workbook (not curriculum)',
       'A second demo container, so that enrolment can be represented in tests '
       'without any of this becoming curriculum.', true
  from public.curriculum_providers p where p.slug = 'nestra';

-- --- the two resources 0101 already seeded -----------------------------------
-- They predate the metadata, so they are described now rather than left with
-- defaults that would quietly say something untrue about them.
update public.learning_resources
   set activity_kind     = 'manipulative',
       modality          = 'hands_on',
       language          = 'language_neutral',
       estimated_minutes = 20,
       availability      = 'available',
       content_ownership = 'nestra_owned',
       integration_mode  = 'manual',
       license_note      = 'Nestra demonstration material. Not licensed provider content.'
 where id = 'dddddddd-0000-4000-8000-000000000001';

update public.learning_resources
   set activity_kind     = 'practice',
       modality          = 'visual',
       language          = 'en',
       estimated_minutes = 15,
       availability      = 'available',
       content_ownership = 'nestra_owned',
       integration_mode  = 'manual',
       license_note      = 'Nestra demonstration material. Not licensed provider content.'
 where id = 'dddddddd-0000-4000-8000-000000000002';

-- --- NST.FR.3: several, on purpose ------------------------------------------
-- The skill that has to be able to produce a tie, an enrolment preference and a
-- language requirement all from the same catalogue.

insert into public.learning_resources (
    id, course_id, kind, title, description, is_demo,
    activity_kind, modality, language, estimated_minutes,
    availability, content_ownership, integration_mode, license_note)
values
  -- English, in the OTHER course, so enrolling a child there changes the answer
  -- and nothing else does.
  ('dddddddd-0000-4000-8000-000000000003', 'dddddddd-0000-4000-8000-0000000000fe',
   'practice', 'Demo: equivalent fractions, workbook page',
   'A Nestra demonstration resource. Not curriculum, not provider content.', true,
   'worksheet', 'reading_writing', 'en', 20,
   'available', 'nestra_owned', 'manual',
   'Nestra demonstration material. Not licensed provider content.'),

  -- Spanish, so an explicitly Spanish-speaking family can be served without
  -- anything being machine-translated to fake a match.
  ('dddddddd-0000-4000-8000-000000000004', 'dddddddd-0000-4000-8000-0000000000ff',
   'practice', 'Demo: fracciones equivalentes con tiras de papel',
   'Recurso de demostracion de Nestra. No es curriculo ni contenido de un proveedor.', true,
   'manipulative', 'hands_on', 'es', 20,
   'available', 'nestra_owned', 'manual',
   'Nestra demonstration material. Not licensed provider content.'),

  -- Bilingual, which satisfies an explicit requirement in either language and
  -- is a different fact from "we do not know what language this is".
  ('dddddddd-0000-4000-8000-000000000005', 'dddddddd-0000-4000-8000-0000000000ff',
   'video', 'Demo: equivalent fractions / fracciones equivalentes',
   'A bilingual Nestra demonstration resource. Not curriculum, not provider content.', true,
   'video', 'visual', 'bilingual', 8,
   'available', 'nestra_owned', 'manual',
   'Nestra demonstration material. Not licensed provider content.'),

  -- Language unstated. Eligible when nobody asked for a language, and NOT
  -- eligible against an explicit requirement, because "unknown" is not Spanish.
  ('dddddddd-0000-4000-8000-000000000006', 'dddddddd-0000-4000-8000-0000000000ff',
   'reading', 'Demo: fractions reading page',
   'A Nestra demonstration resource whose language nobody has recorded.', true,
   'reading', 'reading_writing', 'unknown', 10,
   'available', 'nestra_owned', 'manual',
   'Nestra demonstration material. Not licensed provider content.'),

  -- --- NST.FR.2: present, and out of reach ----------------------------------
  -- Educationally exactly as suitable as it was yesterday. Simply not openable,
  -- which is a fact about access and says nothing about the child.
  ('dddddddd-0000-4000-8000-000000000007', 'dddddddd-0000-4000-8000-0000000000ff',
   'practice', 'Demo: representing fractions (subscription lapsed)',
   'A Nestra demonstration resource used to exercise availability. Not curriculum.', true,
   'practice', 'visual', 'en', 15,
   'requires_subscription', 'nestra_owned', 'manual',
   'Nestra demonstration material. Not licensed provider content.'),

  -- --- NST.FR.1: good material, unreviewed mapping --------------------------
  -- The resource is fine. Nobody has confirmed that it teaches FR.1, and until
  -- somebody does it may be reviewed and may be shown for review, but it may
  -- not decide what a child receives.
  ('dddddddd-0000-4000-8000-000000000008', 'dddddddd-0000-4000-8000-0000000000ff',
   'worksheet', 'Demo: parts of a whole (mapping not yet reviewed)',
   'A Nestra demonstration resource whose skill mapping nobody has confirmed.', true,
   'worksheet', 'visual', 'en', 12,
   'available', 'nestra_owned', 'manual',
   'Nestra demonstration material. Not licensed provider content.');

-- --- the mappings, every one of them unconfirmed -----------------------------

insert into public.resource_skills (resource_id, skill_id, source_type, confirmed)
select v.rid::uuid, k.id, 'manual', false
  from (values
    ('dddddddd-0000-4000-8000-000000000003', 'NST.FR.3'),
    ('dddddddd-0000-4000-8000-000000000004', 'NST.FR.3'),
    ('dddddddd-0000-4000-8000-000000000005', 'NST.FR.3'),
    ('dddddddd-0000-4000-8000-000000000006', 'NST.FR.3'),
    ('dddddddd-0000-4000-8000-000000000007', 'NST.FR.2'),
    ('dddddddd-0000-4000-8000-000000000008', 'NST.FR.1')
  ) as v(rid, code)
  join public.skills k on k.code = v.code;

-- NST.FR.4 is left with nothing at all, and that is the most important row in
-- this file - the one that is not here.

do $check$
declare v_n int;
begin
  select count(*) into v_n from public.learning_resources where is_demo;
  if v_n <> 8 then
    raise exception 'expected 8 demo resources, got %', v_n;
  end if;

  select count(*) into v_n
    from public.resource_skills rs
    join public.learning_resources r on r.id = rs.resource_id
   where r.is_demo and rs.confirmed;
  if v_n <> 0 then
    raise exception
      'a demo mapping arrived pre-confirmed (%). Nobody confirmed these, and a '
      'seed that says somebody did would start choosing material for real children', v_n;
  end if;

  select count(*) into v_n
    from public.resource_skills rs
    join public.skills k on k.id = rs.skill_id
   where k.code = 'NST.FR.4';
  if v_n <> 0 then
    raise exception
      'NST.FR.4 now has material. The empty skill is deliberate: it is what '
      'proves a skill survives having nothing attached to it';
  end if;

  select count(*) into v_n from public.learning_resources
   where is_demo and (content_ownership <> 'nestra_owned' or license_note is null);
  if v_n <> 0 then
    raise exception 'a demo resource does not say who owns it (%)', v_n;
  end if;
end $check$;

select app.assert_schema_invariants();
