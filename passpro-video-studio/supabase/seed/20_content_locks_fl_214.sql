-- ============================================================================
-- Content Locks for Video 0 (scope FL-2-14). Idempotent.
--
-- Values are COPIED FROM PassPro's own public.exams row (the source of truth
-- the question bank already uses), never typed here. If the row is missing,
-- nothing is inserted.
--
-- Status per owner decision 2026-09-29:
--   scored questions, pretest questions, exam time  -> VERIFIED
--   passing score 70%                               -> UNVERIFIED (awaiting
--     confirmation from the current official Florida / Pearson VUE source)
-- source_url is still NULL: fill it when the official document link is recorded.
-- ============================================================================

with ex as (
  select e.id, e.scored_questions, e.pretest_questions, e.time_minutes, e.pass_score,
         e.jurisdiction,
         b.source as blueprint_source, b.effective_date
  from public.exams e
  left join public.exam_blueprints b on b.exam_id = e.id and b.is_current
  where e.code = 'FL-2-14'
)
insert into public.vs_content_locks
  (scope_key, exam_id, concept, statement, value_numeric, unit, jurisdiction,
   effective_date, verified_date, verified_by, source_name, source_url, source_reference,
   verification_status, match_rules)
select 'FL-2-14', ex.id, v.concept, v.statement, v.value, v.unit, ex.jurisdiction,
       ex.effective_date, v.verified_date, v.verified_by,
       coalesce(ex.blueprint_source, 'PassPro exams table (FL-2-14)'), null,
       'public.exams.' || v.column_name || ' (code FL-2-14)',
       v.status, v.rules
from ex
cross join lateral (values
  ('exam.scored_questions',
   format('El examen 2-14 de Florida tiene %s preguntas que cuentan para la nota.', ex.scored_questions),
   ex.scored_questions::numeric, 'questions', 'scored_questions',
   'VERIFIED', date '2026-09-29', 'owner (Video Studio plan approval)',
   jsonb_build_object(
     'require_any', jsonb_build_array('puntuad', 'que cuentan', 'cuentan para', 'calificad', 'scored', 'cuentan'),
     'forbid_any',  jsonb_build_array('no (se )?cuentan', 'no (se )?califican', 'no puntúan', 'pretest', 'de prueba', 'experimental', 'sin (puntuaci|valor|nota)', 'unscored', 'no cuenta'))),
  ('exam.pretest_questions',
   format('El examen 2-14 de Florida incluye %s preguntas de prueba que no cuentan para la nota.', ex.pretest_questions),
   ex.pretest_questions::numeric, 'questions', 'pretest_questions',
   'VERIFIED', date '2026-09-29', 'owner (Video Studio plan approval)',
   jsonb_build_object(
     'require_any', jsonb_build_array('no (se )?cuentan', 'no (se )?califican', 'no puntúan', 'pretest', 'de prueba', 'experimental', 'sin (puntuaci|valor|nota)', 'unscored', 'no cuenta'),
     'forbid_any',  jsonb_build_array())),
  ('exam.time_limit_minutes',
   format('El examen 2-14 de Florida da %s minutos.', ex.time_minutes),
   ex.time_minutes::numeric, 'minutes', 'time_minutes',
   'VERIFIED', date '2026-09-29', 'owner (Video Studio plan approval)',
   jsonb_build_object(
     'require_any', jsonb_build_array('examen', 'exam', 'prueba', 'tiempo', 'dura', 'tienes', 'te dan'),
     'forbid_any',  jsonb_build_array())),
  ('exam.passing_score_percent',
   format('Se necesita %s%% para aprobar el examen 2-14 de Florida.', ex.pass_score),
   ex.pass_score::numeric, 'percent', 'pass_score',
   'UNVERIFIED', null::date, null::text,
   jsonb_build_object(
     'require_any', jsonb_build_array('aprobar', 'pasar', 'nota', 'puntuación', 'passing', 'pass'),
     'forbid_any',  jsonb_build_array()))
) as v(concept, statement, value, unit, column_name, status, verified_date, verified_by, rules)
where v.value is not null
on conflict (scope_key, concept) do nothing;
