// End-to-end MVP acceptance flow on the FREE mock provider:
// series → characters → episode → script → analyze → scenes/clips →
// content-lock validation → estimate → edit → approve → mock generation →
// review → regenerate one → choose version → timeline → render → captions →
// cost ledger. Uses real FFmpeg for clip synthesis and the final render.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { makeStudio, runUntilIdle } from './helpers.ts';
import { readFixture } from '../fixtures/load-series.ts';
import { renderEpisode } from '../src/worker/render.ts';
import { probeDuration } from '../src/core/storage/local-storage.ts';
import { MemoryStudioStore } from '../src/core/workflow/store.ts';
import { StudioService } from '../src/core/workflow/studio-service.ts';
import { StudioError } from '../src/core/types.ts';
import { spawnSync } from 'node:child_process';

const SCRIPT = readFixture('test-script.fixture.txt');

test('full mock workflow — acceptance steps 1–16 without spending money', { timeout: 240_000 }, async () => {
  const { bible, store, studio, provider, root } = await makeStudio();

  // 1–4: series exists, characters persist, create Video 0 with the script
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'Bienvenidos a la casa de Doña Póliza', script: SCRIPT, target_duration_s: 125 });
  assert.equal(ep.status, 'DRAFT');

  // 5–7: analyze → plan with scenes/clips/cost BEFORE any generation
  const plan = await studio.analyzeEpisode(ep.id);
  assert.equal(provider.calls.generateClip, 0, 'analysis never calls the video provider');
  assert.equal(plan.scene_count, 3);
  assert.ok(plan.clip_count >= 4);
  assert.ok(plan.estimated_total_usd! > 0);
  assert.deepEqual(plan.content_conflicts, [], 'fixture script agrees with the verified locks');
  assert.deepEqual(plan.characters.sort(), ['Doña Póliza', 'El Sobrino', 'La Voz del Examen']);
  const confirmed = plan.scenes.flatMap((s) => s.clips.flatMap((c) => c.issues)).filter((i) => i.code === 'FACT_CONFIRMED');
  assert.equal(confirmed.length, 3, '85 scored, 10 pretest, 2 hours confirmed against locks');

  // 8: edit one clip (camera) → plan hash changes; old approval hash is stale
  const clips0 = await store.listClips(ep.id);
  const h0 = (await store.getEpisode(ep.id)).plan_hash!;
  await studio.editClip(clips0[0].id, { camera_direction: 'wide establishing shot, slow push-in' }, 'admin');
  const h1 = (await store.getEpisode(ep.id)).plan_hash!;
  assert.notEqual(h0, h1);
  await assert.rejects(studio.approveEpisode(ep.id, { plan_hash: h0, authorized_max_usd: 10, retry_budget_usd: 2, approved_by: 'admin' }), /VS_PLAN_CHANGED/);
  await assert.rejects(studio.generateApproved(ep.id), /VS_NOT_APPROVED/);
  assert.equal(provider.calls.generateClip, 0);

  // 9: approve (bound to the current hash) with a cap and retry budget
  const est = (await studio.planView(ep.id)).estimated_total_usd!;
  // retry budget = exactly one regeneration of clip #2
  const retry = (await store.listClips(ep.id))[1].estimated_cost_usd!;
  await studio.approveEpisode(ep.id, { plan_hash: h1, authorized_max_usd: Math.ceil(est) + 1, retry_budget_usd: retry, approved_by: 'admin' });

  // 10: generate (concurrency 2) and poll until done
  const first = await studio.generateApproved(ep.id);
  assert.equal(first.length, 2, 'max_concurrent_jobs = 2');
  const again = await studio.generateApproved(ep.id);
  assert.equal(again.length, 0, 'double click does not submit more than the limit');
  await runUntilIdle(studio, ep.id);
  let clips = await store.listClips(ep.id);
  assert.ok(clips.every((c) => c.status === 'COMPLETE' && c.versions.length === 1 && c.selected_version === 1));
  assert.equal(provider.calls.generateClip, clips.length, 'exactly one submission per clip');
  for (const c of clips) assert.ok(existsSync(join(root, c.versions[0].storage_path)));

  // 11–13: review; regenerate ONE clip; others untouched; select the new version
  const target = clips[1];
  const before = new Map(clips.map((c) => [c.id, JSON.stringify(c.versions)]));
  await studio.regenerateClip(target.id, 'admin');
  await runUntilIdle(studio, ep.id);
  clips = await store.listClips(ep.id);
  for (const c of clips) if (c.id !== target.id) assert.equal(JSON.stringify(c.versions), before.get(c.id), `clip ${c.ord} untouched`);
  const t2 = clips.find((c) => c.id === target.id)!;
  assert.deepEqual(t2.versions.map((v) => v.version), [1, 2], 'previous version kept, not overwritten');
  assert.equal(t2.selected_version, 1, 'selection does not change by itself');
  await studio.selectVersion(t2.id, 2);
  await assert.rejects(studio.deleteVersion(t2.id, 2), /select another version/);
  await studio.deleteVersion(t2.id, 1);
  assert.ok((await store.getClip(t2.id)).versions[0].deleted_at, 'soft delete keeps history');

  // a second regeneration exceeds the retry budget → needs explicit authorization
  const callsBefore = provider.calls.generateClip;
  await assert.rejects(studio.regenerateClip(t2.id, 'admin'), (e: unknown) => e instanceof StudioError && e.code === 'VS_NEEDS_AUTHORIZATION');
  assert.equal(provider.calls.generateClip, callsBefore, 'refused regeneration never reached the provider');

  // 14: timeline in order, reorder/restore, play order
  const { timeline, missing } = await studio.buildTimeline(ep.id);
  assert.deepEqual(missing, []);
  assert.deepEqual(timeline.map((t) => t.clip_id), clips.map((c) => c.id));
  assert.equal(timeline.find((t) => t.clip_id === t2.id)!.version, 2);
  const rev = [...timeline].reverse().map((t) => t.clip_id);
  await studio.reorderTimeline(ep.id, rev);
  await studio.reorderTimeline(ep.id, clips.map((c) => c.id));
  await studio.setTransition(ep.id, clips[clips.length - 1].id, 'fade');

  // captions (canonical dialogue) + SRT export
  const srt = await studio.captionsSrt(ep.id);
  assert.match(srt, /^1\n\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}\n¿Tú también vienes por el examen\?\n/);
  assert.match(srt, /Siéntate, que esto se explica mejor con un\npastelillo\.\n/, 'cues break at sentence ends, not mid-sentence');
  assert.ok(srt.replace(/\n/g, ' ').includes('El examen tiene 85 preguntas que cuentan para la nota.'), 'captions use the canonical dialogue');

  // 15: render request → FFmpeg worker renders from storage only
  const { job, spec } = await studio.requestRender(ep.id, { captions: true });
  assert.equal(job.status, 'QUEUED');
  assert.equal((await store.getEpisode(ep.id)).status, 'RENDERING');
  const callsAtRender = { ...provider.calls };
  const result = await renderEpisode(spec, (p) => join(root, p), root);
  assert.deepEqual(provider.calls, callsAtRender, 'render never calls the AI provider');
  const expected = spec.inputs.reduce((s, i) => s + i.duration_s, 0);
  assert.ok(Math.abs(result.duration_s - expected) < 0.6, `final ${result.duration_s}s vs ${expected}s`);
  const streams = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_type,width,height', '-of', 'csv=p=0', result.output_file]).stdout.toString();
  assert.match(streams, /video,1920,1080/);
  assert.match(streams, /audio/);
  assert.match(streams, /subtitle/, 'Spanish soft captions attached');
  assert.equal(readFileSync(result.srt_file!, 'utf8'), srt);

  // 16: actual total cost from the ledger (simulated for mock)
  const cost = await studio.costSummary(ep.id);
  const sumVersions = (await store.listClips(ep.id)).flatMap((c) => c.versions).reduce((s, v) => s + v.cost_usd, 0);
  assert.equal(cost.total_actual_usd, Math.round(sumVersions * 10000) / 10000);
  assert.ok(cost.regenerations_usd > 0);
  assert.equal(cost.open_reservations_usd, 0);
  assert.equal(cost.simulated, true);
  assert.ok(Object.keys(cost.by_scene).length === 3);
});

test('a CONTENT CONFLICT stops the workflow and cannot be waved through', async () => {
  const { bible, studio, store, provider } = await makeStudio();
  const bad = SCRIPT.replace('85 preguntas que cuentan', 'noventa preguntas que cuentan');
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'x', script: bad });
  const plan = await studio.analyzeEpisode(ep.id);
  assert.equal(plan.episode.status, 'CONTENT_CONFLICT');
  assert.equal(plan.content_conflicts.length, 1);
  assert.match(plan.content_conflicts[0].message, /⚠ CONTENT CONFLICT/);
  assert.equal(plan.content_conflicts[0].expected, '85 questions');
  const clip = (await store.listClips(ep.id)).find((c) => c.issues.some((i) => i.code === 'CONTENT_CONFLICT'))!;
  assert.ok(clip.dialogue.some((d) => d.text.includes('noventa preguntas')), 'script text NOT silently corrected');
  await assert.rejects(studio.acknowledgeIssue(clip.id, 'CONTENT_CONFLICT', 'admin'), /VS_CONFLICT_NOT_ACKNOWLEDGEABLE/);
  await assert.rejects(studio.approveClip(clip.id), /VS_CONTENT_BLOCKED/);
  await assert.rejects(
    studio.approveEpisode(ep.id, { plan_hash: plan.episode.plan_hash!, authorized_max_usd: 10, retry_budget_usd: 0, approved_by: 'admin' }),
    /VS_CONTENT_BLOCKED/,
  );
  // a human explicitly fixes the dialogue → conflict clears (edit is flagged for review)
  const fixed = clip.dialogue.map((d) => ({ ...d, text: d.text.replace('noventa preguntas', '85 preguntas') }));
  const edited = await studio.editClip(clip.id, { dialogue: fixed }, 'admin');
  assert.ok(!edited.issues.some((i) => i.severity === 'conflict'));
  assert.ok(edited.issues.some((i) => i.code === 'DIALOGUE_EDITED' && i.severity === 'review'));
  await studio.acknowledgeIssue(clip.id, 'DIALOGUE_EDITED', 'admin');
  assert.equal((await store.getEpisode(ep.id)).status, 'ANALYZED');
  assert.equal(provider.calls.generateClip, 0);
});

test('UNVERIFIED fact (70%) needs review; paid-disabled and kill switch hold', async () => {
  const { bible, studio, store, provider } = await makeStudio();
  const s = SCRIPT.replace('Y tienes dos horas.', 'Y para aprobar necesitas 70%.');
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'x', script: s });
  const plan = await studio.analyzeEpisode(ep.id);
  const review = plan.needs_review.find((i) => i.code === 'UNVERIFIED_FACT');
  assert.ok(review, '70% is not authoritative');
  await assert.rejects(
    studio.approveEpisode(ep.id, { plan_hash: plan.episode.plan_hash!, authorized_max_usd: 10, retry_budget_usd: 0, approved_by: 'admin' }),
    /VS_CONTENT_BLOCKED/,
  );
  await studio.acknowledgeIssue(review.clip_id!, 'UNVERIFIED_FACT', 'admin');
  const hash = (await store.getEpisode(ep.id)).plan_hash!;
  await studio.approveEpisode(ep.id, { plan_hash: hash, authorized_max_usd: 10, retry_budget_usd: 0, approved_by: 'admin' });
  store.setSettings({ generation: { enabled: false, paid_providers_enabled: false, max_concurrent_jobs: 2 } });
  await assert.rejects(studio.generateApproved(ep.id), /VS_DISABLED/);
  assert.equal(provider.calls.generateClip, 0);
});

test('a limit hit while queueing is recorded for the UI, not swallowed', { timeout: 120_000 }, async () => {
  const { bible, studio, store } = await makeStudio();
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'x', script: SCRIPT });
  const plan = await studio.analyzeEpisode(ep.id);
  await studio.approveEpisode(ep.id, { plan_hash: plan.episode.plan_hash!, authorized_max_usd: 10, retry_budget_usd: 0, approved_by: 'admin' });
  await studio.generateApproved(ep.id);
  const s = await store.settings();
  store.setSettings({ budget: { ...s.budget, max_daily_spend_usd: 2.5 } });
  await runUntilIdle(studio, ep.id);
  const err = (await store.getEpisode(ep.id)).analysis.last_generation_error as { code: string };
  assert.equal(err.code, 'VS_BUDGET_DAILY');
  assert.ok((await store.listClips(ep.id)).some((c) => c.status === 'APPROVED'), 'remaining clips wait for a person');
});

test('generation state survives a restart (store is the source of truth)', { timeout: 120_000 }, async () => {
  const { bible, studio, store, provider, storage } = await makeStudio();
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'x', script: SCRIPT });
  const plan = await studio.analyzeEpisode(ep.id);
  await studio.approveEpisode(ep.id, { plan_hash: plan.episode.plan_hash!, authorized_max_usd: 10, retry_budget_usd: 0, approved_by: 'admin' });
  await studio.generateApproved(ep.id);
  // "refresh": brand-new store + service built only from persisted state
  const restored = MemoryStudioStore.restore(store.snapshot());
  const studio2 = new StudioService({ store: restored, provider, storage, layers: [] });
  const jobs = await restored.listJobs(ep.id);
  assert.equal(jobs.filter((j) => j.status === 'SUBMITTED').length, 2);
  await runUntilIdle(studio2, ep.id);
  assert.ok((await restored.listClips(ep.id)).every((c) => c.status === 'COMPLETE'));
  assert.equal(provider.calls.generateClip, (await restored.listClips(ep.id)).length, 'no job resubmitted after restart');
});

test('a failed clip is never retried automatically', { timeout: 120_000 }, async () => {
  const { bible, studio, store, provider } = await makeStudio({ failWhen: (r, attempt) => attempt === 1 && r.duration_s > 0 && r.prompt.includes('Clip 2 of') });
  const ep = await studio.createEpisode({ series_id: bible.series.id, number: 0, title: 'x', script: SCRIPT });
  const plan = await studio.analyzeEpisode(ep.id);
  await studio.approveEpisode(ep.id, { plan_hash: plan.episode.plan_hash!, authorized_max_usd: 10, retry_budget_usd: 2, approved_by: 'admin' });
  await studio.generateApproved(ep.id);
  await runUntilIdle(studio, ep.id);
  const clips = await store.listClips(ep.id);
  const failed = clips.filter((c) => c.status === 'FAILED');
  assert.equal((await store.getEpisode(ep.id)).analysis.last_generation_error, undefined);
  assert.equal(failed.length, 1);
  assert.equal(provider.calls.generateClip, clips.length, 'no automatic retry');
  const cost = await studio.costSummary(ep.id);
  assert.equal(cost.open_reservations_usd, 0, 'failed job reservation released');
  await studio.regenerateClip(failed[0].id, 'admin');
  await runUntilIdle(studio, ep.id);
  assert.equal((await store.getClip(failed[0].id)).status, 'COMPLETE');
});
