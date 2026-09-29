import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compileClipPrompt } from '../src/core/compiler/prompt-compiler.ts';
import { RuleBasedPlanner } from '../src/core/planner/planner.ts';
import { MockVideoProvider } from '../src/core/providers/mock-video-provider.ts';
import { loadSeriesBible, readFixture } from '../fixtures/load-series.ts';
import { fixturePricing } from '../fixtures/pricing.fixture.ts';
import type { Asset } from '../src/core/types.ts';

const bible = loadSeriesBible();
const mock = new MockVideoProvider();

async function setup(withRefs = false) {
  const assets = [...bible.assets];
  const characters = structuredClone(bible.characters);
  if (withRefs) {
    const dona = characters.find((c) => c.slug === 'dona-poliza')!;
    const ref: Asset = { ...assets[0], id: 'ref-dona', kind: 'reference_image', slug: 'dona-ref', name: 'Doña ref', character_id: dona.id,
      parent_asset_id: null, storage_path: 'refs/dona.png', status: 'ready' };
    const voice: Asset = { ...ref, id: 'voice-dona', kind: 'voice_sample', slug: 'dona-voice', storage_path: 'voices/dona.wav' };
    dona.primary_reference_asset_id = ref.id;
    dona.voice = { ...dona.voice, master_sample_asset_id: voice.id };
    assets.push(ref, voice);
  }
  const d = await new RuleBasedPlanner().plan({
    episode_id: 'ep', script: readFixture('test-script.fixture.txt'), series: bible.series, characters, assets,
    pricing: fixturePricing(), provider: { id: 'mock', model: 'mock-video-1', paid: false, capabilities: mock.capabilities() }, resolution: '2K',
  });
  return { ...d, assets, characters };
}

const compile = async (d: Awaited<ReturnType<typeof setup>>, i: number, facts?: { id: string; statement: string }[]) =>
  compileClipPrompt({
    series: bible.series, characters: d.characters, assets: d.assets, scene: d.scenes.find((s) => s.id === d.clips[i].scene_id)!,
    clip: d.clips[i], clip_count: d.clips.length, capabilities: mock.capabilities(), resolution: '2K', ratio: '16:9',
    resolveMedia: async (a) => `https://signed.example/${a.storage_path}`, facts,
  });

test('compiler assembles every section and never sends the raw script', async () => {
  const d = await setup();
  const out = await compile(d, 0);
  for (const s of ['STYLE', 'CHARACTER LOCK', 'LOCATION LOCK', 'CURRENT SHOT', 'ACTION', 'CAMERA', 'DIALOGUE', 'CONTINUITY', 'DO NOT'])
    assert.ok(out.request.prompt.includes(`${s}:\n`), `missing ${s}`);
  assert.ok(!out.request.prompt.includes('ESCENA 2'), 'raw script is not embedded');
  assert.match(out.sections['DO NOT'], /on-screen text/);
  assert.match(out.sections['DO NOT'], /invent any number/);
  assert.match(out.sections.DIALOGUE, /word for word/);
  assert.equal(out.request.duration_s, d.clips[0].duration_estimate_s);
});

test('facts come only from the injected provider (none hard-coded)', async () => {
  const d = await setup();
  const i = d.clips.findIndex((c) => c.dialogue.some((x) => x.text.includes('85')));
  const without = await compile(d, i);
  assert.equal(without.sections['LOCKED FACTS'], undefined);
  const withFacts = await compile(d, i, [{ id: 'lock-scored', statement: 'STATEMENT-FROM-DB' }]);
  assert.match(withFacts.sections['LOCKED FACTS'], /STATEMENT-FROM-DB/);
  assert.deepEqual(withFacts.fact_ids, ['lock-scored']);
});

test('voice-only character is marked off-screen and excluded from CHARACTER LOCK visuals', async () => {
  const d = await setup();
  const out = await compile(d, 0);
  assert.match(out.sections['CHARACTER LOCK'], /Off-screen voice only \(never visible\): La Voz del Examen/);
  assert.match(out.sections.DIALOGUE, /LA VOZ DEL EXAMEN \(off-screen\)/);
});

test('reference images and voice samples are numbered and attached', async () => {
  const d = await setup(true);
  const out = await compile(d, 0);
  assert.equal(out.request.reference_images[0].url, 'https://signed.example/refs/dona.png');
  assert.match(out.sections['CHARACTER LOCK'], /Must match reference image 1 exactly/);
  assert.equal(out.request.reference_audios.length, 1);
  assert.match(out.sections.DIALOGUE, /timbre follows reference audio 1/);
  assert.deepEqual(mock.validateRequest(out.request), []);
});

test('prompt over the provider limit is refused, not truncated', async () => {
  const d = await setup();
  d.clips[0].visual_prompt = 'x'.repeat(8000);
  await assert.rejects(compile(d, 0), /VS_PROMPT_TOO_LONG/);
});
