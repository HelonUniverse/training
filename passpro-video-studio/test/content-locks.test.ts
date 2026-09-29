import { test } from 'node:test';
import assert from 'node:assert/strict';
import { findNumericMentions } from '../src/education/numbers-es.ts';
import { validateTextAgainstLocks, relevantVerifiedLocks, type ContentLock } from '../src/education/content-locks.ts';
import { PassProEducationLayer } from '../src/education/passpro-layer.ts';
import { fixtureLocks } from '../fixtures/content-locks.fixture.ts';
import type { Clip, Series } from '../src/core/types.ts';

const locks = fixtureLocks();
const v = (text: string, l: ContentLock[] = locks) => validateTextAgainstLocks(text, l, { where: 't' });
const codes = (text: string, l?: ContentLock[]) => v(text, l).map((i) => i.code);

test('numbers: digits, Spanish words, hours→minutes, percent', () => {
  const m = (s: string) => findNumericMentions(s).map((x) => [x.value, x.unit]);
  assert.deepEqual(m('85 preguntas'), [[85, 'questions']]);
  assert.deepEqual(m('ochenta y cinco preguntas'), [[85, 'questions']]);
  assert.deepEqual(m('ciento veinte minutos'), [[120, 'minutes']]);
  assert.deepEqual(m('tienes dos horas'), [[120, 'minutes']]);
  assert.deepEqual(m('una hora y media'), [[90, 'minutes']]);
  assert.deepEqual(m('necesitas 70% o setenta por ciento'), [[70, 'percent'], [70, 'percent']]);
  assert.deepEqual(m('diez de las preguntas'), [[10, 'questions']]);
  assert.deepEqual(m('Te hago una pregunta'), [], 'article "una" is not a claim');
  assert.deepEqual(m('un café y medio, número uno'), []);
});

test('VERIFIED match → FACT_CONFIRMED; wrong number → CONTENT CONFLICT (not corrected)', () => {
  assert.deepEqual(codes('El examen tiene 85 preguntas que cuentan.'), ['FACT_CONFIRMED']);
  const text = 'El examen tiene 90 preguntas que cuentan.';
  const issues = v(text);
  assert.equal(issues[0].code, 'CONTENT_CONFLICT');
  assert.equal(issues[0].severity, 'conflict');
  assert.equal(issues[0].expected, '85 questions');
  assert.match(issues[0].message, /⚠ CONTENT CONFLICT/);
  assert.equal(text, 'El examen tiene 90 preguntas que cuentan.', 'validator never rewrites text');
});

test('scored vs pretest are told apart by qualifiers', () => {
  assert.deepEqual(codes('Trae diez preguntas de prueba que no cuentan.'), ['FACT_CONFIRMED']);
  assert.deepEqual(codes('Trae doce preguntas de prueba que no cuentan.'), ['CONTENT_CONFLICT']);
  assert.deepEqual(codes('Hay 10 preguntas que cuentan para la nota.'), ['CONTENT_CONFLICT']);
});

test('time lock accepts equivalent units and flags wrong ones', () => {
  assert.deepEqual(codes('Y tienes dos horas.'), ['FACT_CONFIRMED']);
  assert.deepEqual(codes('El examen dura 120 minutos.'), ['FACT_CONFIRMED']);
  assert.deepEqual(codes('El examen dura 90 minutos.'), ['CONTENT_CONFLICT']);
});

test('UNVERIFIED lock (70%) is never authoritative → review', () => {
  const i = v('Para aprobar necesitas 70%.');
  assert.equal(i[0].code, 'UNVERIFIED_FACT');
  assert.equal(i[0].severity, 'review');
  const wrong = v('Para aprobar necesitas 75%.');
  assert.equal(wrong[0].code, 'UNVERIFIED_FACT', 'no conflict can be asserted from an unverified source either');
});

test('unlocked numeric claims need review; unrelated text is clean', () => {
  assert.deepEqual(codes('Son noventa y cinco preguntas en total.'), ['UNLOCKED_NUMERIC_CLAIM']);
  assert.deepEqual(codes('Siéntate, que esto se explica mejor con un pastelillo.'), []);
});

test('STALE and CONFLICT lock statuses', () => {
  const stale = locks.map((l) => (l.id === 'lock-scored' ? { ...l, verification_status: 'STALE' as const } : l));
  assert.deepEqual(codes('85 preguntas que cuentan', stale), ['STALE_FACT']);
  const conf = locks.map((l) => (l.id === 'lock-scored' ? { ...l, verification_status: 'CONFLICT' as const } : l));
  assert.deepEqual(codes('85 preguntas que cuentan', conf), ['LOCK_IN_CONFLICT']);
});

test('a VERIFIED lock without provenance is not authoritative', () => {
  const noSource = locks.map((l) => (l.id === 'lock-scored' ? { ...l, source_name: null } : l));
  assert.deepEqual(codes('85 preguntas que cuentan', noSource), ['UNVERIFIED_FACT']);
});

test('forbidden term variants are conflicts', () => {
  const termLock: ContentLock = { ...locks[0], id: 'term', concept: 'term.regulator', value_numeric: null, unit: null,
    value_text: 'Departamento de Servicios Financieros', match_rules: { forbidden_variants: ['Departamento de Seguros de Florida'] } };
  assert.deepEqual(codes('Lo regula el Departamento de Seguros de Florida.', [termLock]), ['CONTENT_CONFLICT']);
});

const clip = (text: string): Clip => ({
  id: 'c1', episode_id: 'e', scene_id: 's', ord: 1, duration_estimate_s: 8, location_asset_id: null, character_ids: [],
  dialogue: [{ speaker_character_id: null, speaker_label: 'X', text, source_line: 1, est_start_s: 0, est_end_s: 3 }],
  action: '', camera_direction: '', visual_prompt: '', audio_requirements: { mode: 'native', notes: [] }, reference_asset_ids: [],
  continuity: { from_previous: '', into_next: '' }, estimated_cost_usd: 1, pricing_verified: true, status: 'PLANNED', issues: [],
  versions: [], selected_version: null, edited_by_human: false,
});

test('fact context: only VERIFIED locks, only when relevant', () => {
  assert.deepEqual(relevantVerifiedLocks(clip('Tienes 85 preguntas que cuentan'), locks).map((l) => l.id), ['lock-scored', 'lock-pretest']);
  assert.deepEqual(relevantVerifiedLocks(clip('Necesitas 70% para aprobar'), locks), [], 'unverified never injected');
  assert.deepEqual(relevantVerifiedLocks(clip('Hola, siéntate'), locks), []);
});

test('layer loads facts from the loader by series scope (DB is the source of truth)', async () => {
  const asked: string[][] = [];
  const layer = new PassProEducationLayer(async (scopes) => {
    asked.push(scopes);
    return locks;
  });
  const series = { bible: { content_lock_scopes: ['FL-2-14'] } } as unknown as Series;
  const facts = await layer.factsForClip(clip('El examen tiene 85 preguntas que cuentan'), series);
  assert.deepEqual(asked, [['FL-2-14']]);
  assert.ok(facts.some((f) => f.statement.includes('85')));
  const none = await layer.factsForClip(clip('85 preguntas'), { bible: {} } as unknown as Series);
  assert.deepEqual(none, [], 'series without lock scopes gets no facts');
});
