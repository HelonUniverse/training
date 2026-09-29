// Free, deterministic fake provider. It never touches the network. Jobs move
// queued → running → succeeded over successive status polls, so the whole
// async workflow (jobs, polling, refresh-survival, ledger) is exercised.
//
// The result URL is mock://clip?..., which the storage layer turns into a real
// placeholder MP4 (colour card + clip label + tone) with FFmpeg, so review,
// timeline and render can be demonstrated end to end.

import {
  SubmissionNotSentError,
  validateAgainstCapabilities,
  type CompiledClipRequest,
  type ProviderCapabilities,
  type ProviderJobResult,
  type ProviderJobStatus,
  type SubmitOptions,
  type VideoProvider,
} from './video-provider.ts';

export interface MockVideoOptions {
  /** Polls spent in queued/running before success. Default 2. */
  ticksToComplete?: number;
  /** Return true to make the job for this request fail (simulates a bad clip). */
  failWhen?: (req: CompiledClipRequest, attempt: number) => boolean;
}

interface MockJob {
  req: CompiledClipRequest;
  polls: number;
  fail: boolean;
  key: string;
}

const PALETTE = ['e07a5f', '3d405b', '81b29a', 'f2cc8f', '6d597a', '355070', 'b56576', 'eaac8b'];

export class MockVideoProvider implements VideoProvider {
  readonly id = 'mock';
  readonly model = 'mock-video-1';
  readonly paid = false;
  private jobs = new Map<string, MockJob>();
  private byKey = new Map<string, string>();
  private attempts = new Map<string, number>();
  private seq = 0;
  private opts: MockVideoOptions;

  constructor(opts: MockVideoOptions = {}) {
    this.opts = opts;
  }

  capabilities(): ProviderCapabilities {
    // Mirrors MiniMax-H3's documented limits so mock plans are realistic.
    return {
      min_duration_s: 4,
      max_duration_s: 15,
      integer_duration_only: true,
      resolutions: ['768P', '2K'],
      ratios: ['16:9', '9:16', '1:1', '4:3', '3:4', '21:9', 'adaptive'],
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
    return validateAgainstCapabilities(this.capabilities(), req);
  }

  async generateClip(req: CompiledClipRequest, opts: SubmitOptions): Promise<{ provider_job_id: string }> {
    const existing = this.byKey.get(opts.idempotency_key);
    if (existing) return { provider_job_id: existing };
    const problems = this.validateRequest(req);
    if (problems.length) throw new SubmissionNotSentError(`mock provider rejected request: ${problems.join('; ')}`);
    const attempt = (this.attempts.get(req.clip_id) ?? 0) + 1;
    this.attempts.set(req.clip_id, attempt);
    this.seq += 1;
    const id = `mock-job-${this.seq}`;
    this.jobs.set(id, { req, polls: 0, fail: this.opts.failWhen?.(req, attempt) ?? false, key: opts.idempotency_key });
    this.byKey.set(opts.idempotency_key, id);
    return { provider_job_id: id };
  }

  async getJobStatus(providerJobId: string): Promise<ProviderJobStatus> {
    const job = this.jobs.get(providerJobId);
    if (!job) return { state: 'expired', error: { code: 'NOT_FOUND', message: 'unknown mock job' } };
    job.polls += 1;
    const ticks = this.opts.ticksToComplete ?? 2;
    if (job.polls < ticks) return { state: job.polls === 1 ? 'queued' : 'running' };
    if (job.fail) return { state: 'failed', error: { code: 'MOCK_FAILURE', message: 'simulated generation failure' } };
    return { state: 'succeeded', usage: { output_seconds: job.req.duration_s, input_image_count: job.req.reference_images.length } };
  }

  async getResult(providerJobId: string): Promise<ProviderJobResult> {
    const job = this.jobs.get(providerJobId);
    if (!job) throw new Error('unknown mock job');
    const n = Number(providerJobId.split('-').pop());
    const params = new URLSearchParams({
      duration: String(job.req.duration_s),
      color: PALETTE[n % PALETTE.length],
      label: `${job.req.clip_id.slice(0, 8)} · ${providerJobId}`,
      tone: String(220 + (n % 8) * 55),
    });
    return {
      video_url: `mock://clip?${params}`,
      duration_s: job.req.duration_s,
      usage: { output_seconds: job.req.duration_s, input_image_count: job.req.reference_images.length },
    };
  }
}
