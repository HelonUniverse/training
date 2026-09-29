// TEST FIXTURE mirroring supabase/seed/20_content_locks_fl_214.sql. In the
// application, locks are loaded from vs_content_locks; this copy exists only
// so unit tests and the offline demo run without a database.

import type { ContentLock } from '../src/education/content-locks.ts';

const PRETEST_TERMS = ['no (se )?cuentan', 'no (se )?califican', 'no puntúan', 'pretest', 'de prueba', 'experimental', 'sin (puntuaci|valor|nota)', 'unscored', 'no cuenta'];

const base = {
  scope_key: 'FL-2-14',
  exam_id: null,
  value_text: null,
  jurisdiction: 'FL',
  effective_date: '2026-01-01',
  source_name: 'Pearson VUE FL Life & Annuity (incl. Variable Contracts) 0214 content outline, 2026',
  source_url: null,
};

export function fixtureLocks(): ContentLock[] {
  return [
    { ...base, id: 'lock-scored', concept: 'exam.scored_questions', statement: 'El examen 2-14 de Florida tiene 85 preguntas que cuentan para la nota.',
      value_numeric: 85, unit: 'questions', verified_date: '2026-09-29', verified_by: 'owner', source_reference: 'public.exams.scored_questions',
      verification_status: 'VERIFIED', match_rules: { require_any: ['puntuad', 'que cuentan', 'cuentan para', 'calificad', 'scored', 'cuentan'], forbid_any: PRETEST_TERMS } },
    { ...base, id: 'lock-pretest', concept: 'exam.pretest_questions', statement: 'El examen 2-14 de Florida incluye 10 preguntas de prueba que no cuentan para la nota.',
      value_numeric: 10, unit: 'questions', verified_date: '2026-09-29', verified_by: 'owner', source_reference: 'public.exams.pretest_questions',
      verification_status: 'VERIFIED', match_rules: { require_any: PRETEST_TERMS, forbid_any: [] } },
    { ...base, id: 'lock-time', concept: 'exam.time_limit_minutes', statement: 'El examen 2-14 de Florida da 120 minutos.',
      value_numeric: 120, unit: 'minutes', verified_date: '2026-09-29', verified_by: 'owner', source_reference: 'public.exams.time_minutes',
      verification_status: 'VERIFIED', match_rules: { require_any: ['examen', 'exam', 'prueba', 'tiempo', 'dura', 'tienes', 'te dan'], forbid_any: [] } },
    { ...base, id: 'lock-pass', concept: 'exam.passing_score_percent', statement: 'Se necesita 70% para aprobar el examen 2-14 de Florida.',
      value_numeric: 70, unit: 'percent', verified_date: null, verified_by: null, source_reference: 'public.exams.pass_score',
      verification_status: 'UNVERIFIED', match_rules: { require_any: ['aprobar', 'pasar', 'nota', 'puntuación', 'passing', 'pass'], forbid_any: [] } },
  ];
}
