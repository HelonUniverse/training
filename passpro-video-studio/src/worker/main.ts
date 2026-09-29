// Render worker entrypoint (Railway). Provider-independent: it only moves
// files between Supabase Storage and FFmpeg. It must NEVER hold AI keys and
// refuses to start if any are present in its environment.
//
//   Queue mode (Railway):  node src/worker/main.ts
//     env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIDEO_STUDIO_BUCKET
//   Local mode (demo/dev): node src/worker/main.ts --spec spec.json --root ./out/storage

import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir, hostname } from 'node:os';
import { dirname, join } from 'node:path';
import type { RenderSpec } from '../core/render/render-spec.ts';
import { renderEpisode } from './render.ts';

export const FORBIDDEN_ENV = ['MINIMAX_API_KEY', 'ANTHROPIC_API_KEY', 'ELEVENLABS_API_KEY', 'OPENAI_API_KEY'];

export function assertNoAiKeys(env: Record<string, string | undefined>): void {
  const present = FORBIDDEN_ENV.filter((k) => env[k]);
  if (present.length)
    throw new Error(`render worker refuses to start: AI provider secrets present (${present.join(', ')}). Remove them from this service.`);
}

export interface WorkerConfig {
  supabase_url: string;
  service_role_key: string;
  bucket: string;
  worker_id: string;
  fetch?: typeof fetch;
}

/** Minimal PostgREST + Storage client for the render queue. */
export class RenderQueueClient {
  private c: WorkerConfig;
  private f: typeof fetch;
  constructor(c: WorkerConfig) {
    this.c = { ...c, supabase_url: c.supabase_url.replace(/\/$/, '') };
    this.f = c.fetch ?? fetch;
  }
  private headers(extra: Record<string, string> = {}) {
    return { apikey: this.c.service_role_key, Authorization: `Bearer ${this.c.service_role_key}`, ...extra };
  }
  private async rpc(fn: string, body: unknown) {
    const res = await this.f(`${this.c.supabase_url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: this.headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${fn} failed: HTTP ${res.status} ${await res.text()}`);
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }
  async claim(): Promise<{ id: string; request: { spec: RenderSpec } } | null> {
    const job = await this.rpc('vs_claim_render_job', { p_worker: this.c.worker_id });
    return job && job.id ? job : null;
  }
  async complete(jobId: string, ok: boolean, outputPath: string | null, error: unknown = null) {
    await this.rpc('vs_complete_render_job', { p_job_id: jobId, p_ok: ok, p_output_storage_path: outputPath, p_error: error });
  }
  objectUrl(path: string) {
    return `${this.c.supabase_url}/storage/v1/object/${this.c.bucket}/${path.split('/').map(encodeURIComponent).join('/')}`;
  }
  async download(path: string, dest: string) {
    const res = await this.f(this.objectUrl(path), { headers: this.headers() });
    if (!res.ok) throw new Error(`download ${path}: HTTP ${res.status}`);
    await mkdir(dirname(dest), { recursive: true });
    await writeFile(dest, new Uint8Array(await res.arrayBuffer()));
  }
  async upload(path: string, file: string, contentType: string) {
    const res = await this.f(this.objectUrl(path), {
      method: 'POST',
      headers: this.headers({ 'Content-Type': contentType, 'x-upsert': 'true' }),
      body: await readFile(file),
    });
    if (!res.ok) throw new Error(`upload ${path}: HTTP ${res.status} ${await res.text()}`);
  }
}

export async function processOne(q: RenderQueueClient): Promise<boolean> {
  const job = await q.claim();
  if (!job) return false;
  const spec = job.request.spec;
  const work = await mkdtemp(join(tmpdir(), 'vs-worker-'));
  try {
    for (const i of spec.inputs) await q.download(i.storage_path, join(work, 'in', i.storage_path));
    const result = await renderEpisode(spec, (p) => join(work, 'in', p), join(work, 'out'));
    await q.upload(spec.output_path, result.output_file, 'video/mp4');
    if (result.srt_file && spec.srt_path) await q.upload(spec.srt_path, result.srt_file, 'application/x-subrip');
    await q.complete(job.id, true, spec.output_path);
  } catch (err) {
    await q.complete(job.id, false, null, { message: String(err) }).catch(() => {});
  } finally {
    await rm(work, { recursive: true, force: true });
  }
  return true;
}

async function main(argv: string[], env: Record<string, string | undefined>) {
  assertNoAiKeys(env);
  const specIdx = argv.indexOf('--spec');
  if (specIdx >= 0) {
    const root = argv[argv.indexOf('--root') + 1] ?? '.';
    const spec = JSON.parse(await readFile(argv[specIdx + 1], 'utf8')) as RenderSpec;
    const r = await renderEpisode(spec, (p) => join(root, p), root);
    console.log(JSON.stringify(r, null, 2));
    return;
  }
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
  const q = new RenderQueueClient({
    supabase_url: env.SUPABASE_URL,
    service_role_key: env.SUPABASE_SERVICE_ROLE_KEY,
    bucket: env.VIDEO_STUDIO_BUCKET ?? 'video-studio',
    worker_id: env.RAILWAY_REPLICA_ID ?? hostname(),
  });
  const idle = Number(env.RENDER_POLL_INTERVAL_MS ?? 5000);
  console.log('render worker started');
  for (;;) {
    const did = await processOne(q).catch((e) => {
      console.error('worker error', e);
      return false;
    });
    if (!did) await new Promise((r) => setTimeout(r, idle));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2), process.env).catch((e) => {
    console.error(String(e));
    process.exit(1);
  });
}
