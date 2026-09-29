import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertNoAiKeys, RenderQueueClient } from '../src/worker/main.ts';
import { concatListFile, escapeFilterPath, finalizeArgs, normalizeArgs } from '../src/worker/ffmpeg-plan.ts';
import { buildSeedSql, seedTargets } from '../scripts/build-seed-sql.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const walk = (d: string): string[] => readdirSync(d).flatMap((f) => (statSync(join(d, f)).isDirectory() ? walk(join(d, f)) : [join(d, f)]));

test('worker refuses to start with AI provider keys', () => {
  assert.throws(() => assertNoAiKeys({ MINIMAX_API_KEY: 'x' }), /refuses to start/);
  assert.throws(() => assertNoAiKeys({ ANTHROPIC_API_KEY: 'x' }), /refuses to start/);
  assert.throws(() => assertNoAiKeys({ ELEVENLABS_API_KEY: 'x' }), /refuses to start/);
  assert.doesNotThrow(() => assertNoAiKeys({ SUPABASE_SERVICE_ROLE_KEY: 'x' }));
});

test('ffmpeg plan: normalization, silent-audio fill, fades, captions', () => {
  const n = normalizeArgs('in.mp4', 'out.mp4', { duration_s: 8, has_audio: false, fade_in: true, fade_out: false, video: { width: 1920, height: 1080, fps: 24 }, sample_rate: 48000 });
  assert.ok(n.includes('anullsrc=r=48000:cl=stereo'));
  assert.match(n.join(' '), /scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080/);
  assert.match(n.join(' '), /fade=t=in:st=0:d=0.5/);
  assert.doesNotMatch(n.join(' '), /fade=t=out/);
  const soft = finalizeArgs('j.mp4', 'o.mp4', { loudnorm: true, srt_file: 'c.srt', burn_in: false, language: 'es' });
  assert.ok(soft.includes('mov_text') && soft.includes('language=spa') && soft.join(' ').includes('loudnorm=I=-16'));
  const burn = finalizeArgs('j.mp4', 'o.mp4', { loudnorm: false, srt_file: '/tmp/a:b.srt', burn_in: true, language: 'es' });
  assert.ok(burn.join(' ').includes("subtitles='/tmp/a\\:b.srt'"));
  assert.equal(escapeFilterPath("a'b,c"), "a\\'b\\,c");
  assert.equal(concatListFile(["/x/it's.mp4"]), "file '/x/it'\\''s.mp4'\n");
});

test('render queue client talks only to Supabase (fake fetch)', async () => {
  const seen: string[] = [];
  const fake = (async (url: string, init: RequestInit) => {
    seen.push(`${init?.method ?? 'GET'} ${url}`);
    assert.equal((init.headers as Record<string, string>).Authorization, 'Bearer service-key');
    if (url.endsWith('/rpc/vs_claim_render_job')) return new Response(JSON.stringify({ id: null }));
    return new Response('');
  }) as unknown as typeof fetch;
  const q = new RenderQueueClient({ supabase_url: 'https://proj.supabase.co/', service_role_key: 'service-key', bucket: 'video-studio', worker_id: 'w1', fetch: fake });
  assert.equal(await q.claim(), null);
  await q.complete('job-1', true, 'episodes/e/renders/x.mp4');
  assert.deepEqual(seen, ['POST https://proj.supabase.co/rest/v1/rpc/vs_claim_render_job', 'POST https://proj.supabase.co/rest/v1/rpc/vs_complete_render_job']);
  assert.equal(q.objectUrl('episodes/a b/x.mp4'), 'https://proj.supabase.co/storage/v1/object/video-studio/episodes/a%20b/x.mp4');
});

test('architecture: core never imports the education layer or the worker', () => {
  for (const f of walk(join(ROOT, 'src', 'core')).filter((f) => f.endsWith('.ts'))) {
    const src = readFileSync(f, 'utf8');
    assert.doesNotMatch(src, /from ['"][^'"]*education\//, `${f} imports education`);
    assert.doesNotMatch(src, /from ['"][^'"]*worker\//, `${f} imports worker`);
  }
});

test('architecture: no exam facts hard-coded in core or education code', () => {
  const files = [...walk(join(ROOT, 'src', 'core')), ...walk(join(ROOT, 'src', 'education'))].filter((f) => f.endsWith('.ts'));
  for (const f of files) {
    const src = readFileSync(f, 'utf8');
    assert.doesNotMatch(src, /\b85\b|\bpretest_questions\b.*=\s*10|\b120 minut/, `${f} contains a hard-coded exam fact`);
  }
});

test('architecture: worker image never contains AI keys or the education layer', () => {
  const docker = readFileSync(join(ROOT, 'worker', 'Dockerfile'), 'utf8');
  assert.doesNotMatch(docker, /MINIMAX|ANTHROPIC|ELEVENLABS/);
  assert.doesNotMatch(docker, /src\/education/);
});

test('seed SQL is generated from the series JSON and up to date', () => {
  for (const t of seedTargets())
    assert.equal(readFileSync(t.sql, 'utf8'), buildSeedSql(JSON.parse(readFileSync(t.json, 'utf8'))), `${t.sql} is stale; run npm run seed:sql`);
});

test('.env.example has names only and paid mode off', () => {
  const env = readFileSync(join(ROOT, '.env.example'), 'utf8');
  assert.match(env, /^VIDEO_PROVIDER_MODE=mock$/m);
  for (const line of env.split('\n').filter((l) => /_(KEY|SECRET)=/.test(l))) assert.match(line, /=$/, `secret has a value: ${line}`);
});
