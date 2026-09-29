// FREE end-to-end demonstration (mock provider, no network, no money):
//
//   npm run demo                          uses the synthetic fixture script
//   npm run demo -- --script video0.txt   uses any script file (e.g. the real Video 0)
//
// Output: out/demo/…/final.mp4 + .srt, and the plan / cost dashboard in the terminal.

import { mkdir, readFile, rm } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MemoryStudioStore } from '../src/core/workflow/store.ts';
import { StudioService } from '../src/core/workflow/studio-service.ts';
import { createVideoProvider } from '../src/core/providers/registry.ts';
import { LocalMediaStorage } from '../src/core/storage/local-storage.ts';
import { PassProEducationLayer } from '../src/education/passpro-layer.ts';
import { formatCostSummary } from '../src/core/ledger/ledger.ts';
import { renderEpisode } from '../src/worker/render.ts';
import { StudioError } from '../src/core/types.ts';
import { loadSeriesBible, readFixture } from '../fixtures/load-series.ts';
import { fixtureLocks } from '../fixtures/content-locks.fixture.ts';
import { fixturePricing } from '../fixtures/pricing.fixture.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'out', 'demo');
const argv = process.argv.slice(2);
const scriptArg = argv.indexOf('--script') >= 0 ? argv[argv.indexOf('--script') + 1] : null;
const hr = (t: string) => console.log(`\n${'═'.repeat(64)}\n${t}\n${'═'.repeat(64)}`);
const usd = (n: number | null) => (n === null ? 'UNCONFIRMED' : `$${n.toFixed(2)}`);
const mmss = (s: number) => `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}`;

async function main() {
  // The demo must never be able to spend money, whatever the shell env says.
  const provider = createVideoProvider({ VIDEO_PROVIDER_MODE: 'mock' });
  await rm(OUT, { recursive: true, force: true });
  await mkdir(OUT, { recursive: true });

  // SERIES + CHARACTER BIBLE (same JSON the database seed is generated from)
  const bible = loadSeriesBible();
  const store = new MemoryStudioStore();
  store.setSettings({ pricing: fixturePricing() });
  store.addSeries(bible.series);
  bible.characters.forEach((c) => store.addCharacter(c));
  bible.assets.forEach((a) => store.addAsset(a));
  const education = new PassProEducationLayer(async (scopes) => fixtureLocks().filter((l) => scopes.includes(l.scope_key)));
  const studio = new StudioService({ store, provider, storage: new LocalMediaStorage(OUT), layers: [education.asLayer()] });

  hr(`SERIES  ${bible.series.name}`);
  for (const c of bible.characters) console.log(`  • ${c.name}${c.voice_only ? ' (voice only)' : ''} — ${c.description.slice(0, 70)}…`);

  const script = scriptArg ? await readFile(scriptArg, 'utf8') : readFixture('test-script.fixture.txt');
  if (!scriptArg) console.log('\n  (using the SYNTHETIC fixture script — pass --script <file> for the real Video 0)');

  // CONTENT LOCK demo: a wrong number stops the workflow
  const bad = await studio.createEpisode({ series_id: bible.series.id, number: 99, title: 'Conflict demo', script: script.replace(/85 preguntas/g, 'noventa preguntas') });
  const badPlan = await studio.analyzeEpisode(bad.id);
  if (badPlan.content_conflicts.length) {
    hr('CONTENT LOCK CHECK (deliberately wrong script)');
    for (const c of badPlan.content_conflicts) console.log(`  ${c.message}`);
    try {
      await studio.approveEpisode(bad.id, { plan_hash: badPlan.episode.plan_hash!, authorized_max_usd: 10, retry_budget_usd: 0, approved_by: 'demo' });
    } catch (e) {
      console.log(`  → approval refused: ${(e as StudioError).code}`);
    }
  }

  // VIDEO 0
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'Bienvenidos a la casa de Doña Póliza', script, target_duration_s: 125 });
  const plan = await studio.analyzeEpisode(ep.id);
  hr(`VIDEO ${plan.episode.number}\n${plan.episode.title}`);
  console.log(`Estimated final duration: ${mmss(plan.estimated_duration_s)}`);
  console.log(`Scenes: ${plan.scene_count}\nClips: ${plan.clip_count}`);
  console.log(`Estimated generation: ${usd(plan.estimated_total_usd)}${plan.pricing_verified ? '' : ' (pricing unverified)'}   [mock prices — simulated]`);
  console.log(`Characters: ${plan.characters.join(', ')}`);
  for (const s of plan.scenes) {
    console.log(`\nSCENE ${String(s.ord).padStart(2, '0')}\n${s.heading}`);
    for (const c of s.clips) {
      console.log(`\n  Clip ${String(c.ord).padStart(2, '0')} · ${c.duration_s} sec · ${usd(c.estimated_cost_usd)} · ${c.status}`);
      console.log(`  ${c.action}`);
      for (const d of c.dialogue) console.log(`    ${d.speaker}: "${d.text}"`);
      for (const i of c.issues.filter((x) => x.severity !== 'info' || x.code === 'FACT_CONFIRMED')) console.log(`    [${i.severity}] ${i.code}: ${i.message}`);
      console.log('  [EDIT] [APPROVE]');
    }
  }
  if (plan.content_conflicts.length) {
    console.log('\n⚠ CONTENT CONFLICT — fix the script before approval. Stopping.');
    return;
  }
  for (const r of plan.needs_review) console.log(`\n  needs review: ${r.code} — ${r.message}`);
  if (plan.needs_review.length) {
    console.log('\nReview items must be acknowledged by a person in the UI. Stopping the demo here.');
    return;
  }

  // EDIT a clip, then APPROVE
  const clips = await store.listClips(ep.id);
  await studio.editClip(clips[0].id, { camera_direction: 'wide establishing shot of the porch, slow push-in' }, 'demo');
  const current = await studio.planView(ep.id);
  const budget = (await store.settings()).budget;
  const authorized = Math.min(budget.max_cost_per_episode_usd, Math.ceil(current.estimated_total_usd!) + 1);
  hr('APPROVAL');
  console.log(`TOTAL ESTIMATED COST            ${usd(current.estimated_total_usd)}`);
  console.log(`Maximum possible authorized cost ${usd(authorized + 1)}  (episode cap ${usd(authorized)} + retry budget $1.00)`);
  console.log('[APPROVE EPISODE & GENERATE]  ← approved by "demo"');
  await studio.approveEpisode(ep.id, { plan_hash: current.episode.plan_hash!, authorized_max_usd: authorized, retry_budget_usd: 1, approved_by: 'demo' });

  // GENERATE (mock) and poll
  await studio.generateApproved(ep.id);
  let ticks = 0;
  while ((await studio.tick(ep.id)).open > 0 && ticks++ < 100);
  const done = await store.listClips(ep.id);
  hr('CLIP LIBRARY');
  for (const c of done) console.log(`  Clip ${String(c.ord).padStart(2, '0')}  v${c.versions.map((v) => v.version).join(', v')}  ★ v${c.selected_version}  ${c.status}`);

  // REGENERATE ONE clip, select the replacement
  const target = done[Math.min(1, done.length - 1)];
  await studio.regenerateClip(target.id, 'demo');
  while ((await studio.tick(ep.id)).open > 0 && ticks++ < 200);
  await studio.selectVersion(target.id, 2);
  console.log(`\n  Regenerated clip ${target.ord} only → versions v1, v2 ★ selected (others untouched)`);

  // TIMELINE → RENDER → CAPTIONS
  const { timeline } = await studio.buildTimeline(ep.id);
  hr('TIMELINE');
  console.log('  ' + timeline.map((t) => String(done.find((c) => c.id === t.clip_id)!.ord).padStart(2, '0')).join(' → '));
  const { spec } = await studio.requestRender(ep.id, { captions: true });
  const result = await renderEpisode(spec, (p) => join(OUT, p), OUT);
  console.log(`\n  Final MP4: ${result.output_file}\n  Duration:  ${mmss(result.duration_s)}\n  Captions:  ${result.srt_file} (Spanish, from the canonical script)`);

  // COST DASHBOARD
  hr('COST DASHBOARD');
  console.log(formatCostSummary(await studio.costSummary(ep.id), `Video ${ep.number}`));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
