// MiniMax-H3 adapter (v2 video API). Wire format per the official MiniMax CLI
// source (github.com/MiniMax-AI/cli, 2026-09-19); see
// docs/video-provider-minimax.md. Values marked there as UNVERIFIED must be
// confirmed on platform.minimax.io before the first paid call.
//
// SAFETY: this adapter refuses to make ANY network request unless it was
// constructed with allow_paid_requests: true. The registry only does that when
// paid mode is explicitly configured (see registry.ts). Tests use a fake fetch.

import {
  SubmissionNotSentError,
  validateAgainstCapabilities,
  type CompiledClipRequest,
  type ProviderCapabilities,
  type ProviderJobResult,
  type ProviderJobState,
  type ProviderJobStatus,
  type SubmitOptions,
  type VideoProvider,
} from './video-provider.ts';

export class PaidRequestBlockedError extends SubmissionNotSentError {
  constructor(what: string) {
    super(`PAID_REQUEST_BLOCKED: ${what} would call the MiniMax API; paid mode is not enabled`);
    this.name = 'PaidRequestBlockedError';
  }
}

export interface MinimaxH3Options {
  api_key: string;
  base_url?: string;
  model?: string;
  allow_paid_requests: boolean;
  fetch?: typeof fetch;
}

type ContentItem =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string }; role: 'first_frame' | 'last_frame' | 'reference_image' }
  | { type: 'audio_url'; audio_url: { url: string }; role: 'reference_audio' };

export interface MinimaxCreateBody {
  model: string;
  content: ContentItem[];
  resolution: string;
  duration: number;
  ratio: string;
  callback_url?: string;
}

const STATE_MAP: Record<string, ProviderJobState> = {
  queued: 'queued',
  running: 'running',
  succeeded: 'succeeded',
  failed: 'failed',
  cancelled: 'cancelled',
  expired: 'expired',
};

const MODERATION_CODES = new Set(['1026', '1027']);

export class MinimaxH3Provider implements VideoProvider {
  readonly id = 'minimax';
  readonly model: string;
  readonly paid = true;
  private opts: MinimaxH3Options;
  private base: string;
  private submittedKeys = new Map<string, string>();

  constructor(opts: MinimaxH3Options) {
    this.opts = opts;
    this.model = opts.model ?? 'MiniMax-H3';
    this.base = (opts.base_url ?? 'https://api.minimax.io').replace(/\/$/, '');
  }

  capabilities(): ProviderCapabilities {
    return {
      min_duration_s: 4,
      max_duration_s: 15,
      integer_duration_only: true,
      // 768P availability is conflicting in official sources; 2K is certain.
      resolutions: ['2K'],
      ratios: ['adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'],
      max_prompt_chars: 7000,
      max_reference_images: 9,
      max_reference_audios: 3,
      image_reference: true,
      audio_reference: true,
      character_reference: true,
      native_audio: true,
      first_last_frame: true,
      frames_and_references_together: false,
    };
  }
  supportsImageReference() { return true; }
  supportsAudioReference() { return true; }
  supportsCharacterReference() { return true; }

  validateRequest(req: CompiledClipRequest): string[] {
    const problems = validateAgainstCapabilities(this.capabilities(), req);
    if (req.reference_audios.length && !req.reference_images.length)
      problems.push('MiniMax-H3 needs at least one reference image when reference audio is sent');
    const hasFrames = Boolean(req.first_frame || req.last_frame);
    if (!hasFrames && !req.reference_images.length && req.ratio === 'adaptive')
      problems.push('text-only requests need a concrete ratio, not adaptive');
    return problems;
  }

  /** Pure mapping, exported for tests and for request logging. */
  buildCreateBody(req: CompiledClipRequest, callbackUrl?: string): MinimaxCreateBody {
    const content: ContentItem[] = [{ type: 'text', text: req.prompt }];
    const hasFrames = Boolean(req.first_frame || req.last_frame);
    if (req.first_frame) content.push({ type: 'image_url', image_url: { url: req.first_frame.url }, role: 'first_frame' });
    if (req.last_frame) content.push({ type: 'image_url', image_url: { url: req.last_frame.url }, role: 'last_frame' });
    for (const img of req.reference_images)
      content.push({ type: 'image_url', image_url: { url: img.url }, role: 'reference_image' });
    for (const a of req.reference_audios)
      content.push({ type: 'audio_url', audio_url: { url: a.url }, role: 'reference_audio' });
    const body: MinimaxCreateBody = {
      model: this.model,
      content,
      resolution: req.resolution,
      duration: req.duration_s,
      ratio: hasFrames ? 'adaptive' : req.ratio,
    };
    if (callbackUrl) body.callback_url = callbackUrl;
    return body;
  }

  private guard(what: string): typeof fetch {
    if (!this.opts.allow_paid_requests) throw new PaidRequestBlockedError(what);
    if (!this.opts.api_key) throw new SubmissionNotSentError('MINIMAX_API_KEY is not configured');
    return this.opts.fetch ?? fetch;
  }

  private headers() {
    return { Authorization: `Bearer ${this.opts.api_key}`, 'Content-Type': 'application/json' };
  }

  async generateClip(req: CompiledClipRequest, opts: SubmitOptions): Promise<{ provider_job_id: string }> {
    const doFetch = this.guard('generateClip');
    // In-process guard; the durable guarantee is vs_generation_jobs.idempotency_key.
    const prior = this.submittedKeys.get(opts.idempotency_key);
    if (prior) return { provider_job_id: prior };
    const problems = this.validateRequest(req);
    if (problems.length) throw new SubmissionNotSentError(`INVALID_REQUEST: ${problems.join('; ')}`);

    const res = await doFetch(`${this.base}/v2/video_generation`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(this.buildCreateBody(req, opts.callback_url)),
    });
    const data = (await res.json().catch(() => ({}))) as Record<string, any>;
    const taskId = data.task_id ?? data.data?.task_id;
    if (!res.ok || !taskId) {
      // Never retried automatically: an ambiguous submission may already be billed.
      throw new MinimaxError(res.status, data);
    }
    this.submittedKeys.set(opts.idempotency_key, taskId);
    return { provider_job_id: String(taskId) };
  }

  async getJobStatus(providerJobId: string): Promise<ProviderJobStatus> {
    const task = await this.queryTask(providerJobId);
    return parseTaskStatus(task);
  }

  async getResult(providerJobId: string): Promise<ProviderJobResult> {
    const task = await this.queryTask(providerJobId);
    const status = parseTaskStatus(task);
    if (status.state !== 'succeeded') throw new Error(`task ${providerJobId} is ${status.state}`);
    const url = task?.content?.url;
    if (!url) throw new Error(`task ${providerJobId} succeeded without content.url`);
    return {
      video_url: url,
      duration_s: Number(task.duration ?? task.usage?.output_seconds ?? 0),
      usage: task.usage ?? {},
      raw: task,
    };
  }

  private async queryTask(id: string): Promise<Record<string, any>> {
    const doFetch = this.guard('getJobStatus');
    const res = await doFetch(`${this.base}/v2/query/video_generation/${encodeURIComponent(id)}`, {
      method: 'GET',
      headers: this.headers(),
    });
    const data = (await res.json().catch(() => ({}))) as Record<string, any>;
    if (!res.ok) throw new MinimaxError(res.status, data);
    return data.task ?? data;
  }
}

export class MinimaxError extends Error {
  readonly http_status: number;
  readonly code: string;
  readonly moderation: boolean;
  readonly rate_limited: boolean;
  constructor(httpStatus: number, body: Record<string, any>) {
    const code = String(body?.base_resp?.status_code ?? body?.error?.code ?? httpStatus);
    const msg = String(body?.base_resp?.status_msg ?? body?.error?.message ?? 'MiniMax request failed');
    super(`MINIMAX_${code}: ${msg}`);
    this.name = 'MinimaxError';
    this.http_status = httpStatus;
    this.code = code;
    this.moderation = MODERATION_CODES.has(code) || httpStatus === 422;
    this.rate_limited = code === '1002' || httpStatus === 429;
  }
}

export function parseTaskStatus(task: Record<string, any>): ProviderJobStatus {
  const state = STATE_MAP[String(task?.status ?? '').toLowerCase()];
  if (!state) return { state: 'failed', error: { code: 'UNKNOWN_STATUS', message: `unknown status ${task?.status}` } };
  const out: ProviderJobStatus = { state };
  if (task.usage) out.usage = task.usage;
  if (task.error && (task.error.code || task.error.message)) {
    const code = String(task.error.code ?? '');
    out.error = { code, message: String(task.error.message ?? ''), moderation: MODERATION_CODES.has(code) };
  }
  return out;
}

export type CallbackParse =
  | { kind: 'challenge'; response: { challenge: string } }
  | { kind: 'status'; provider_job_id: string; status: ProviderJobStatus; video_url?: string };

/** Webhook handling: echo the verification challenge; otherwise parse a status push. */
export function parseMinimaxCallback(body: Record<string, any>): CallbackParse {
  if (typeof body?.challenge === 'string') return { kind: 'challenge', response: { challenge: body.challenge } };
  const task = body.task ?? body;
  return {
    kind: 'status',
    provider_job_id: String(task.id ?? task.task_id ?? ''),
    status: parseTaskStatus(task),
    video_url: task.content?.url,
  };
}
