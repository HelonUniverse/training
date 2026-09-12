-- =============================================================================
-- Legacy catalogue rows, written before STEP 8 existed
-- =============================================================================
-- 0103 adds availability, ownership, language and modality to a table that has
-- been in production since STEP 5. Every row already in it was written by
-- somebody who was never asked any of those questions, and the migration has to
-- do something defensible with all of them.
--
-- The two answers being checked in 0081_0083_assert.sql are:
--
--   availability defaults to `available`, because that is what the schema
--   already meant - before this migration every catalogue row was openable as
--   far as the system was concerned, and a backfill that changed that would
--   silently remove material from families who are using it today;
--
--   activity_kind stays NULL, because nobody has said. Deriving "a link is an
--   external curriculum lesson" would be Nestra inventing metadata and then
--   ranking on it.
-- =============================================================================

insert into public.courses (id, provider_id, scope, name, active)
select '0aaaaaaa-0000-4000-8000-00000000c001', p.id, 'catalog',
       'Legacy course written before STEP 8', true
  from public.curriculum_providers p where p.slug = 'nestra';

insert into public.learning_resources (id, course_id, kind, title, external_url)
values ('0aaaaaaa-0000-4000-8000-00000000e001', '0aaaaaaa-0000-4000-8000-00000000c001',
        'link', 'Legacy link resource', 'https://example.invalid/legacy'),
       ('0aaaaaaa-0000-4000-8000-00000000e002', '0aaaaaaa-0000-4000-8000-00000000c001',
        'worksheet', 'Legacy worksheet resource', null);

insert into public.resource_skills (resource_id, skill_id, source_type, confirmed)
select '0aaaaaaa-0000-4000-8000-00000000e001', k.id, 'manual', false
  from public.skills k where k.code = 'NST.FR.1';
