import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseScript, canonicalDialogue } from '../src/core/planner/script-parser.ts';
import { RuleBasedPlanner, checkDialogueFidelity, computePlanHash, splitAtSentences, DEFAULT_TIMING } from '../src/core/planner/planner.ts';
import { MockVideoProvider } from '../src/core/providers/mock-video-provider.ts';
import { loadSeriesBible, readFixture } from '../fixtures/load-series.ts';
import { fixturePricing } from '../fixtures/pricing.fixture.ts';

const bible = loadSeriesBible();
const script = readFixture('test-script.fixture.txt');
const mock = new MockVideoProvider();
const provider = { id: mock.id, model: mock.model, paid: false, capabilities: mock.capabilities() };
const plan = (s = script, pricing = fixturePricing(), p = provider) =>
  new RuleBasedPlanner().plan({ episode_id: 'ep', script: s, ...bible, pricing, provider: p, resolution: '2K' });

test('parser: scenes, speakers, actions, camera, breaks — verbatim dialogue', () => {
  const p = parseScript(script, bible.characters);
  assert.equal(p.title, 'FIXTURE — synthetic test script. NOT the canonical Video 0 script.');
  assert.equal(p.scenes.length, 3);
  const d = canonicalDialogue(p);
  assert.equal(d.length, 8);
  assert.equal(d[0].text, '¿Tú también vienes por el examen? Siéntate, que esto se explica mejor con un pastelillo.');
  assert.ok(p.scenes[1].beats.some((b) => b.kind === 'camera'));
  assert.ok(p.scenes[1].beats.some((b) => b.kind === 'break'));
  assert.equal(p.warnings.filter((w) => w.code === 'UNKNOWN_SPEAKER').length, 0);
});

test('parser: screenplay blocks, delivery notes, unknown speakers', () => {
  const p = parseScript('ESCENA 1\nDOÑA PÓLIZA\n(susurrando)\n“Ven acá.”\n\nKEVIN: Hola.\nNota: esto es acción', bible.characters);
  const beats = p.scenes[0].beats;
  assert.deepEqual(beats[0], { kind: 'dialogue', speaker_label: 'DOÑA PÓLIZA', character_id: bible.characters[0].id, text: 'Ven acá.', delivery: 'susurrando', source_line: 4 });
  assert.equal(beats[1].kind, 'dialogue');
  assert.equal(p.warnings.find((w) => w.code === 'UNKNOWN_SPEAKER')?.source_line, 6);
  assert.equal(beats[2].kind, 'action', 'lowercase "Nota:" is not a speaker');
});

test('planner: clips are integer 5–15 s, ordered, located, costed', async () => {
  const d = await plan();
  assert.equal(d.scenes.length, 3);
  assert.ok(d.clips.length >= 4);
  d.clips.forEach((c, i) => {
    assert.equal(c.ord, i + 1);
    assert.ok(Number.isInteger(c.duration_estimate_s) && c.duration_estimate_s >= 5 && c.duration_estimate_s <= 15, `clip ${c.ord} ${c.duration_estimate_s}s`);
    assert.equal(c.location_asset_id, bible.assets.find((a) => a.slug === 'casa-de-dona-poliza')!.id);
    assert.equal(c.estimated_cost_usd, Math.round(c.duration_estimate_s * 0.1 * 10000) / 10000);
    assert.equal(c.status, 'PLANNED');
  });
  assert.equal(d.summary.clip_count, d.clips.length);
  assert.ok(d.summary.estimated_cost_usd! > 0);
  // forced break --- splits clip in scene 2
  const s2 = d.clips.filter((c) => c.scene_id === d.scenes[1].id);
  assert.ok(s2.some((c) => c.dialogue.some((x) => x.text.includes('beneficiary'))) && s2.length >= 2);
  // camera direction captured
  assert.equal(s2[0].camera_direction, 'primer plano de la bandeja');
});

test('planner: dialogue fidelity holds (no paraphrase)', async () => {
  const d = await plan();
  assert.deepEqual(d.warnings.filter((w) => w.source === 'fidelity'), []);
  const tampered = structuredClone(d.clips);
  tampered[1].dialogue[0].text = 'El examen tiene muchas preguntas.';
  const issues = checkDialogueFidelity(d.parsed, tampered);
  assert.equal(issues[0].code, 'DIALOGUE_MISMATCH');
  assert.equal(issues[0].severity, 'conflict');
  tampered[1].edited_by_human = true;
  assert.equal(checkDialogueFidelity(d.parsed, tampered)[0].code, 'DIALOGUE_EDITED');
});

test('planner: voice-only character is in the clip but never visually referenced', async () => {
  const voz = bible.characters.find((c) => c.voice_only)!;
  const d = await plan();
  const c = d.clips.find((x) => x.character_ids.includes(voz.id))!;
  assert.ok(c.audio_requirements.notes.some((n) => n.includes('off-screen')));
  assert.ok(!c.issues.some((i) => i.code === 'MISSING_REFERENCE_IMAGE' && i.message.includes(voz.name)));
});

test('planner: missing reference images are info for mock, review for paid providers', async () => {
  const free = await plan();
  assert.ok(free.clips[0].issues.some((i) => i.code === 'MISSING_REFERENCE_IMAGE' && i.severity === 'info'));
  const paid = await plan(script, fixturePricing(), { ...provider, paid: true });
  assert.ok(paid.clips[0].issues.some((i) => i.code === 'MISSING_REFERENCE_IMAGE' && i.severity === 'review'));
});

test('planner: unconfirmed pricing gives no estimate and blocks via review issue', async () => {
  const d = await plan(script, fixturePricing(), { ...provider, id: 'minimax', model: 'MiniMax-H3' });
  assert.ok(d.clips.every((c) => c.estimated_cost_usd === null));
  assert.ok(d.clips[0].issues.some((i) => i.code === 'PRICING_UNCONFIRMED' && i.severity === 'review'));
  assert.equal(d.summary.estimated_cost_usd, null);
});

test('long lines split only at sentence boundaries and re-join verbatim', () => {
  const line = 'Primera oración con varias palabras aquí. ' .repeat(6).trim();
  const parts = splitAtSentences(line, 8, DEFAULT_TIMING);
  assert.ok(parts.length > 1);
  assert.equal(parts.join(' '), line);
});

test('plan hash is stable and changes on any edit', async () => {
  const d = await plan();
  const h1 = await computePlanHash(d.scenes, d.clips);
  assert.equal(h1, await computePlanHash(d.scenes, structuredClone(d.clips)));
  const edited = structuredClone(d.clips);
  edited[0].camera_direction = 'close-up';
  assert.notEqual(h1, await computePlanHash(d.scenes, edited));
});
