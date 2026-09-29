import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockVideoProvider } from '../src/core/providers/mock-video-provider.ts';
import { MinimaxH3Provider, PaidRequestBlockedError, parseMinimaxCallback, parseTaskStatus, MinimaxError } from '../src/core/providers/minimax-h3.ts';
import { createVideoProvider, PAID_CONFIRM_PHRASE } from '../src/core/providers/registry.ts';
import { SubmissionNotSentError, type CompiledClipRequest } from '../src/core/providers/video-provider.ts';
import { MockVoiceProvider } from '../src/core/providers/voice-provider.ts';

const req = (o: Partial<CompiledClipRequest> = {}): CompiledClipRequest => ({
  clip_id: 'clip-1', prompt: 'STYLE:\nwarm', negative_prompt: '', duration_s: 8, resolution: '2K', ratio: '16:9',
  reference_images: [], reference_audios: [], ...o,
});
const img = (n: number) => ({ asset_id: `a${n}`, url: `https://x/${n}.png`, label: `L${n}` });

test('mock: async lifecycle, idempotent submission, simulated failure', async () => {
  const p = new MockVideoProvider({ ticksToComplete: 3, failWhen: (r, attempt) => r.clip_id === 'bad' && attempt === 1 });
  const a = await p.generateClip(req(), { idempotency_key: 'k1' });
  assert.deepEqual(await p.generateClip(req(), { idempotency_key: 'k1' }), a, 'same key → same job');
  assert.equal((await p.getJobStatus(a.provider_job_id)).state, 'queued');
  assert.equal((await p.getJobStatus(a.provider_job_id)).state, 'running');
  assert.equal((await p.getJobStatus(a.provider_job_id)).state, 'succeeded');
  const r = await p.getResult(a.provider_job_id);
  assert.match(r.video_url, /^mock:\/\/clip\?/);
  assert.equal(r.duration_s, 8);
  const bad = await p.generateClip(req({ clip_id: 'bad' }), { idempotency_key: 'k2' });
  for (let i = 0; i < 2; i++) await p.getJobStatus(bad.provider_job_id);
  assert.equal((await p.getJobStatus(bad.provider_job_id)).state, 'failed');
  await assert.rejects(p.generateClip(req({ duration_s: 20 }), { idempotency_key: 'k3' }), SubmissionNotSentError);
  assert.equal(p.paid, false);
});

test('registry: mock by default; live needs provider, key AND confirmation phrase', () => {
  assert.equal(createVideoProvider({}).id, 'mock');
  assert.equal(createVideoProvider({ VIDEO_PROVIDER_MODE: 'mock', MINIMAX_API_KEY: 'sk-api-x' }).id, 'mock');
  assert.throws(() => createVideoProvider({ VIDEO_PROVIDER_MODE: 'live' }), /VIDEO_PROVIDER=minimax/);
  assert.throws(() => createVideoProvider({ VIDEO_PROVIDER_MODE: 'live', VIDEO_PROVIDER: 'minimax', MINIMAX_API_KEY: 'k' }), /VIDEO_PAID_GENERATION_CONFIRM/);
  assert.throws(() => createVideoProvider({ VIDEO_PROVIDER_MODE: 'live', VIDEO_PROVIDER: 'minimax', VIDEO_PAID_GENERATION_CONFIRM: PAID_CONFIRM_PHRASE }), /MINIMAX_API_KEY/);
  assert.throws(() => createVideoProvider({ VIDEO_PROVIDER_MODE: 'paid' }), /unknown VIDEO_PROVIDER_MODE/);
  const live = createVideoProvider(
    { VIDEO_PROVIDER_MODE: 'live', VIDEO_PROVIDER: 'minimax', VIDEO_PAID_GENERATION_CONFIRM: PAID_CONFIRM_PHRASE, MINIMAX_API_KEY: 'k' },
    { fetch: async () => { throw new Error('network must not be touched in this test'); } },
  );
  assert.equal(live.id, 'minimax');
  assert.equal(live.paid, true);
});

test('minimax: without paid mode it NEVER touches the network', async () => {
  let calls = 0;
  const p = new MinimaxH3Provider({ api_key: 'sk-api-test', allow_paid_requests: false, fetch: (async () => { calls++; return new Response('{}'); }) as typeof fetch });
  await assert.rejects(p.generateClip(req(), { idempotency_key: 'k' }), PaidRequestBlockedError);
  await assert.rejects(p.getJobStatus('t'), PaidRequestBlockedError);
  await assert.rejects(p.getResult('t'), PaidRequestBlockedError);
  assert.equal(calls, 0);
});

test('minimax: request mapping matches the documented v2 wire format (fake fetch)', async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const fake = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    if (init.method === 'POST') return new Response(JSON.stringify({ task_id: 'task-123' }), { status: 200 });
    return new Response(JSON.stringify({ task: { id: 'task-123', status: 'succeeded', content: { url: 'https://cdn/x.mp4' }, duration: 8, usage: { output_seconds: 8, input_image_count: 2 } } }));
  }) as unknown as typeof fetch;
  const p = new MinimaxH3Provider({ api_key: 'sk-api-test', allow_paid_requests: true, fetch: fake });
  const r = req({ reference_images: [img(1), img(2)], reference_audios: [{ asset_id: 'v', url: 'https://x/v.wav', label: 'V' }] });
  const { provider_job_id } = await p.generateClip(r, { idempotency_key: 'job-1', callback_url: 'https://cb' });
  assert.equal(provider_job_id, 'task-123');
  await p.generateClip(r, { idempotency_key: 'job-1' });
  assert.equal(seen.length, 1, 'same idempotency key is never resubmitted');
  assert.equal(seen[0].url, 'https://api.minimax.io/v2/video_generation');
  assert.equal((seen[0].init.headers as Record<string, string>).Authorization, 'Bearer sk-api-test');
  const body = JSON.parse(String(seen[0].init.body));
  assert.equal(body.model, 'MiniMax-H3');
  assert.equal(body.duration, 8);
  assert.equal(body.resolution, '2K');
  assert.equal(body.callback_url, 'https://cb');
  assert.deepEqual(body.content.map((c: { type: string; role?: string }) => [c.type, c.role ?? null]), [
    ['text', null], ['image_url', 'reference_image'], ['image_url', 'reference_image'], ['audio_url', 'reference_audio'],
  ]);
  const res = await p.getResult('task-123');
  assert.equal(seen[1].url, 'https://api.minimax.io/v2/query/video_generation/task-123');
  assert.equal(res.video_url, 'https://cdn/x.mp4');
  assert.equal(res.usage.output_seconds, 8);
});

test('minimax: validation mirrors documented limits', () => {
  const p = new MinimaxH3Provider({ api_key: 'k', allow_paid_requests: false });
  assert.match(p.validateRequest(req({ duration_s: 3 })).join(), /duration/);
  assert.match(p.validateRequest(req({ duration_s: 7.5 })).join(), /integer/);
  assert.match(p.validateRequest(req({ reference_images: Array.from({ length: 10 }, (_, i) => img(i)) })).join(), /max 9/);
  assert.match(p.validateRequest(req({ reference_audios: [{ asset_id: 'v', url: 'u', label: 'v' }] })).join(), /reference image when reference audio/);
  assert.match(p.validateRequest(req({ first_frame: img(1), reference_images: [img(2)] })).join(), /cannot be combined/);
  assert.match(p.validateRequest(req({ ratio: 'adaptive' })).join(), /concrete ratio/);
  assert.match(p.validateRequest(req({ prompt: 'x'.repeat(7001) })).join(), /7000/);
  assert.match(p.validateRequest(req({ resolution: '768P' })).join(), /not supported/, '768P unconfirmed → not offered');
  assert.deepEqual(p.validateRequest(req()), []);
  assert.equal(p.buildCreateBody(req({ first_frame: img(1) })).ratio, 'adaptive', 'frame input forces adaptive');
});

test('minimax: status, errors and callback parsing', () => {
  assert.equal(parseTaskStatus({ status: 'running' }).state, 'running');
  assert.equal(parseTaskStatus({ status: 'weird' }).state, 'failed');
  const mod = parseTaskStatus({ status: 'failed', error: { code: 1026, message: 'sensitive' } });
  assert.equal(mod.error?.moderation, true);
  assert.deepEqual(parseMinimaxCallback({ challenge: 'abc' }), { kind: 'challenge', response: { challenge: 'abc' } });
  const push = parseMinimaxCallback({ task: { id: 't1', status: 'succeeded', content: { url: 'u' } } });
  assert.equal(push.kind, 'status');
  const e = new MinimaxError(429, { base_resp: { status_code: 1002, status_msg: 'rate limit' } });
  assert.equal(e.rate_limited, true);
  assert.equal(new MinimaxError(422, {}).moderation, true);
});

test('voice provider: persistent voice required; mock is free', async () => {
  const v = new MockVoiceProvider();
  const r = await v.synthesize({ text: 'Hola mi amor', voice: { provider: 'elevenlabs', voice_id: 'dona-v1' }, language: 'es' });
  assert.equal(r.simulated, true);
  await assert.rejects(v.synthesize({ text: 'x', voice: { provider: 'elevenlabs' }, language: 'es' }), /voice_id required/);
});
