import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkApproval, checkReservation, DEFAULT_BUDGET, DEFAULT_GENERATION } from '../src/core/budget/budget-guard.ts';
import { CostLedger, committedUsd, committedTodayUsd, summarizeCosts, formatCostSummary, dayKey } from '../src/core/ledger/ledger.ts';
import { estimateClipCost } from '../src/core/pricing.ts';
import { buildCaptionCues, captionChunks, formatSrtTime, toSrt, wrapCaption } from '../src/core/captions/srt.ts';
import { fixturePricing } from '../fixtures/pricing.fixture.ts';
import type { Clip, Episode } from '../src/core/types.ts';

const clip = (o: Partial<Clip> = {}): Clip => ({
  id: 'c1', episode_id: 'e1', scene_id: 's1', ord: 1, duration_estimate_s: 10, location_asset_id: null, character_ids: [],
  dialogue: [], action: '', camera_direction: '', visual_prompt: '', audio_requirements: { mode: 'native', notes: [] },
  reference_asset_ids: [], continuity: { from_previous: '', into_next: '' }, estimated_cost_usd: 1, pricing_verified: true,
  status: 'APPROVED', issues: [], versions: [], selected_version: null, edited_by_human: false, ...o,
});
const episode = (o: Partial<Episode> = {}): Episode => ({
  id: 'e1', series_id: 's', number: 0, title: 't', language: 'es', target_duration_s: null, script: '', script_sha256: null,
  status: 'APPROVED', plan_version: 1, plan_hash: 'h', analysis: {}, timeline: [], render_settings: { captions: true, caption_language: 'es' },
  approval: { plan_hash: 'h', approved_by: 'u', approved_at: '', authorized_max_usd: 10, retry_budget_usd: 2, estimated_total_usd: 5 }, ...o,
});
const now = new Date('2026-09-29T15:00:00Z');

test('pricing: estimate from config; unknown price → null + review; simulated flag', () => {
  const m = estimateClipCost(fixturePricing(), { provider: 'mock', model: 'mock-video-1', resolution: '2K', duration_s: 11, reference_image_count: 0 });
  assert.equal(m.amount_usd, 1.1);
  assert.equal(m.simulated, true);
  const h3 = estimateClipCost(fixturePricing(), { provider: 'minimax', model: 'MiniMax-H3', resolution: '2K', duration_s: 11, reference_image_count: 0 });
  assert.equal(h3.amount_usd, null);
  assert.equal(h3.issues[0].code, 'PRICING_UNCONFIRMED');
  const none = estimateClipCost(fixturePricing(), { provider: 'runway', model: 'x', resolution: '2K', duration_s: 5, reference_image_count: 0 });
  assert.equal(none.issues[0].code, 'NO_PRICING');
  const imgs = estimateClipCost([{ provider: 'p', model: 'm', resolution: '*', unit: 'per_output_second', price_usd: 0.1, verified: true },
    { provider: 'p', model: 'm', resolution: '*', unit: 'per_input_image', price_usd: 0.04, verified: true, free_units: 5 }],
    { provider: 'p', model: 'm', resolution: '2K', duration_s: 10, reference_image_count: 7 });
  assert.equal(imgs.amount_usd, 1.08);
});

test('approval: bound to plan hash, blocked by conflicts, capped by limits', () => {
  const ok = { episode: episode({ approval: null }), clips: [clip({ status: 'PLANNED' })], plan_hash: 'h', authorized_max_usd: 5, retry_budget_usd: 5, budget: DEFAULT_BUDGET };
  assert.equal(checkApproval(ok), 1);
  assert.throws(() => checkApproval({ ...ok, plan_hash: 'old' }), /VS_PLAN_CHANGED/);
  assert.throws(() => checkApproval({ ...ok, clips: [clip({ issues: [{ code: 'CONTENT_CONFLICT', severity: 'conflict', message: '', source: 'x', acknowledged: true }] })] }), /VS_CONTENT_BLOCKED/, 'acknowledged conflict still blocks');
  assert.doesNotThrow(() => checkApproval({ ...ok, clips: [clip({ issues: [{ code: 'X', severity: 'review', message: '', source: 'x', acknowledged: true }] })] }));
  assert.throws(() => checkApproval({ ...ok, clips: [clip({ estimated_cost_usd: null })] }), /VS_NO_ESTIMATE/);
  assert.throws(() => checkApproval({ ...ok, authorized_max_usd: 31 }), /per-episode limit/);
  assert.throws(() => checkApproval({ ...ok, retry_budget_usd: 5.01 }), /retry budget/);
  assert.throws(() => checkApproval({ ...ok, clips: [clip({ estimated_cost_usd: 3.5 })], authorized_max_usd: 5 }), /per-clip limit/);
  assert.throws(() => checkApproval({ ...ok, authorized_max_usd: 0.5 }), /below the estimate/);
});

test('reservation: every limit enforced', () => {
  const ledger = new CostLedger(() => now);
  const base = { episode: episode(), clip: clip(), estimate_usd: 1, is_regeneration: false, simulated: true,
    budget: DEFAULT_BUDGET, generation: DEFAULT_GENERATION, ledger: ledger.all(), now };
  assert.equal(checkReservation(base), 'initial');
  assert.throws(() => checkReservation({ ...base, simulated: false }), /VS_PAID_DISABLED/);
  assert.throws(() => checkReservation({ ...base, generation: { ...DEFAULT_GENERATION, enabled: false } }), /VS_DISABLED/);
  assert.throws(() => checkReservation({ ...base, episode: episode({ plan_hash: 'changed' }) }), /VS_NOT_APPROVED/);
  assert.throws(() => checkReservation({ ...base, estimate_usd: 3.01 }), /VS_BUDGET_CLIP/);
  assert.throws(() => checkReservation({ ...base, clip: clip({ status: 'PLANNED' }) }), /VS_NOT_APPROVED/);
  ledger.append({ episode_id: 'e1', entry_type: 'actual', category: 'initial', amount_usd: 9.5, simulated: true });
  assert.throws(() => checkReservation({ ...base, ledger: ledger.all() }), /VS_BUDGET_EPISODE/);
  // daily: other episodes count too
  const l2 = new CostLedger(() => now);
  l2.append({ episode_id: 'other', entry_type: 'actual', category: 'initial', amount_usd: 39.5 });
  assert.throws(() => checkReservation({ ...base, ledger: l2.all() }), /VS_BUDGET_DAILY/);
});

test('regeneration: retry budget first, then explicit authorization', () => {
  const ledger = new CostLedger(() => now);
  const base = { episode: episode(), clip: clip({ status: 'COMPLETE' }), estimate_usd: 1.5, is_regeneration: true, simulated: true,
    budget: DEFAULT_BUDGET, generation: DEFAULT_GENERATION, ledger: ledger.all(), now };
  assert.equal(checkReservation(base), 'regeneration');
  ledger.append({ episode_id: 'e1', entry_type: 'actual', category: 'regeneration', amount_usd: 1.5 });
  assert.throws(() => checkReservation({ ...base, ledger: ledger.all() }), /VS_NEEDS_AUTHORIZATION/);
  ledger.append({ episode_id: 'e1', clip_id: 'c1', entry_type: 'authorization', category: 'regeneration', amount_usd: 2 });
  assert.equal(checkReservation({ ...base, ledger: ledger.all() }), 'regeneration');
  assert.throws(() => checkReservation({ ...base, clip: clip({ status: 'GENERATING' }) }), /VS_STATE/);
});

test('ledger: append-only rows, committed math, timezone day, summary', () => {
  const l = new CostLedger(() => now);
  const r = l.append({ episode_id: 'e1', scene_id: 's1', clip_id: 'c1', job_id: 'j', entry_type: 'reservation', category: 'initial', provider: 'mock', amount_usd: 1, simulated: true });
  assert.throws(() => { (r as { amount_usd: number }).amount_usd = 0; }, TypeError);
  assert.throws(() => l.append({ episode_id: 'e1', entry_type: 'actual', category: 'initial', amount_usd: -1 }));
  l.append({ episode_id: 'e1', scene_id: 's1', clip_id: 'c1', job_id: 'j', entry_type: 'release', category: 'initial', provider: 'mock', amount_usd: 1, simulated: true });
  l.append({ episode_id: 'e1', scene_id: 's1', clip_id: 'c1', job_id: 'j', entry_type: 'actual', category: 'initial', provider: 'mock', amount_usd: 0.8, simulated: true });
  l.append({ episode_id: 'e1', scene_id: 's1', clip_id: 'c1', job_id: 'k', entry_type: 'actual', category: 'regeneration', provider: 'mock', amount_usd: 0.9, simulated: true });
  l.append({ episode_id: 'e1', entry_type: 'authorization', category: 'initial', amount_usd: 10 });
  assert.equal(committedUsd([...l.all()], 'e1'), 1.7);
  assert.equal(committedUsd([...l.all()], 'e1', ['regeneration']), 0.9);
  assert.equal(committedTodayUsd([...l.all()], now, 'America/New_York'), 1.7);
  assert.equal(dayKey('2026-09-30T02:00:00Z', 'America/New_York'), '2026-09-29');
  const s = summarizeCosts(l.all(), 'e1');
  assert.equal(s.initial_generation_usd, 0.8);
  assert.equal(s.regenerations_usd, 0.9);
  assert.equal(s.total_actual_usd, 1.7);
  assert.equal(s.by_clip.c1, 1.7);
  assert.equal(s.by_provider.mock, 1.7);
  assert.equal(s.open_reservations_usd, 0);
  assert.match(formatCostSummary(s, 'Video 0'), /TOTAL\s+\$1\.70/);
  assert.match(formatCostSummary(s, 'Video 0'), /SIMULATED/);
});

test('srt: timestamps, offsets per clip, scaling to real duration, wrapping', () => {
  assert.equal(formatSrtTime(3723.456), '01:02:03,456');
  assert.deepEqual(wrapCaption('uno dos tres cuatro cinco', 10), ['uno dos', 'tres', 'cuatro', 'cinco']);
  const a = clip({ id: 'a', duration_estimate_s: 10, dialogue: [{ speaker_character_id: null, speaker_label: 'D', text: 'Hola.', source_line: 1, est_start_s: 0, est_end_s: 2 }],
    versions: [{ version: 1, job_id: '', provider: '', model: '', prompt: '', reference_asset_ids: [], settings: {}, cost_usd: 0, simulated: true, storage_path: '', duration_s: 5, created_at: '', deleted_at: null }] });
  const b = clip({ id: 'b', duration_estimate_s: 8, dialogue: [{ speaker_character_id: null, speaker_label: 'S', text: 'Adiós.', source_line: 2, est_start_s: 1, est_end_s: 3 }],
    versions: [{ ...a.versions[0], duration_s: 8 }] });
  const cues = buildCaptionCues([{ clip_id: 'a', version: 1, enabled: true, transition: 'cut' }, { clip_id: 'b', version: 1, enabled: true, transition: 'cut' }], [a, b]);
  assert.equal(cues.length, 2);
  assert.equal(cues[0].end_s, 1, 'scaled 10s plan to 5s real clip');
  assert.equal(cues[1].start_s, 6, 'second clip offset by first clip real duration');
  assert.match(toSrt(cues), /^1\n00:00:00,000 --> 00:00:01,000\nHola\.\n\n2\n00:00:06,000 --> 00:00:08,000\nAdiós\.\n$/);
  assert.deepEqual(captionChunks('¿Tú también vienes por el examen? Siéntate, que esto se explica mejor con un pastelillo.'),
    ['¿Tú también vienes por el examen?', 'Siéntate, que esto se explica mejor con un\npastelillo.']);
  assert.deepEqual(captionChunks('Hola. Adiós.'), ['Hola. Adiós.']);
  const disabled = buildCaptionCues([{ clip_id: 'a', version: 1, enabled: false, transition: 'cut' }], [a]);
  assert.equal(disabled.length, 0);
});
