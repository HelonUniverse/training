-- =============================================================================
-- 0108  One definition of "the curriculum this family is using"
-- =============================================================================
-- FORWARD ALIGNMENT, not a rewrite. 0099 is deployed; its text stays exactly as
-- it shipped, and this migration replaces the one function body that disagreed.
--
-- THE DISAGREEMENT. Phase 6's app.path_resource_for prefers material from a
-- course the child has ANY enrolment row for. STEP 8's selector prefers
-- material from a course the child is ACTIVELY enrolled in. Both were
-- defensible in isolation; together they are a bug, because a family would see
-- the Learning Path attach a worksheet from the maths book they finished in
-- May while the activity engine, looking at the same child and the same
-- catalogue, offered something else. Two functions answering "what are you
-- using" with different answers is not a preference, it is a defect.
--
-- The canonical answer is ACTIVE. A course that was completed, paused, dropped
-- or withdrawn is a fact about last year; treating it as the family's current
-- material is how a product starts recommending from a book that is back in the
-- cupboard.
--
-- WHAT THIS DOES NOT CHANGE, and 19_step8_activity.sql section F proves each:
--
--   * which skills reach a path, or in what order. This function runs AFTER
--     candidate selection and only decides what to attach to a node that was
--     already chosen.
--   * whether a node gets a resource at all, except where the only eligible
--     material sat behind a dead enrolment - and the ordering there was already
--     a preference, not a filter.
--   * path versioning, approval, or anything a parent decided.
--   * standards, grade and age independence.
--
-- Only confirmed mappings, still. Only the ordering key changed.
-- =============================================================================

create or replace function app.path_resource_for(p_student uuid, p_skill uuid)
returns uuid language sql stable security invoker set search_path = '' as $fn$
  select r.id
    from public.resource_skills rs
    join public.learning_resources r on r.id = rs.resource_id
    left join public.courses c on c.id = r.course_id
   where rs.skill_id = p_skill
     and rs.confirmed
   order by
     -- ACTIVE enrolment, matching app.learning_activity_candidates exactly. A
     -- course the family finished, paused or dropped is not what they are using.
     case when exists (select 1 from public.student_course_enrollments e
                        where e.student_id = p_student and e.course_id = c.id
                          and e.status = 'active')
          then 0 else 1 end,
     r.kind,
     r.title,
     r.id
   limit 1;
$fn$;

comment on function app.path_resource_for(uuid, uuid) is
  'The resource to attach to a node, or nothing. Only mappings a person has '
  'confirmed are eligible: an unreviewed guess about what a worksheet teaches '
  'may not quietly enter a child''s plan. "No resource available" is a valid '
  'and honest answer. Enrolment means ACTIVE enrolment, the same definition the '
  'activity engine uses - two functions answering "what are you using" '
  'differently is a defect, not a preference.';

-- The invariant that keeps the two definitions from drifting apart again lives
-- in 0107, which redefines app.assert_schema_invariants() a few minutes after
-- this file runs. It has to be that way round: the check reads the source of
-- app.path_resource_for, so the alignment must already have happened before the
-- check exists, or the very migration that adds the guard would trip it.
select app.assert_schema_invariants();
