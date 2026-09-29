// Provider-neutral video generation contract. Episode/Clip models never
// depend on a specific provider; each adapter maps CompiledClipRequest to its
// own wire format.

/**
 * Thrown by adapters when they are CERTAIN nothing reached the provider
 * (paid mode off, request failed local validation). Only then is a
 * reservation released automatically; every other error is treated as an
 * ambiguous submission that a person must review.
 */
export class SubmissionNotSentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SubmissionNotSentError';
  }
}

export interface MediaRef {
  asset_id: string;
  /** Short-lived URL the provider can fetch (signed Storage URL, data URL, …). */
  url: string;
  label: string;
}

export interface CompiledClipRequest {
  clip_id: string;
  prompt: string;
  negative_prompt: string;
  duration_s: number;
  resolution: string;
  ratio: string;
  reference_images: MediaRef[];
  reference_audios: MediaRef[];
  first_frame?: MediaRef;
  last_frame?: MediaRef;
}

export interface ProviderCapabilities {
  min_duration_s: number;
  max_duration_s: number;
  integer_duration_only: boolean;
  resolutions: string[];
  ratios: string[];
  max_prompt_chars: number;
  max_reference_images: number;
  max_reference_audios: number;
  image_reference: boolean;
  audio_reference: boolean;
  character_reference: boolean;
  native_audio: boolean;
  first_last_frame: boolean;
  /** false for MiniMax-H3: first/last frames cannot be combined with references. */
  frames_and_references_together: boolean;
}

export type ProviderJobState = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'expired';

export interface ProviderUsage {
  output_seconds?: number;
  input_image_count?: number;
  [k: string]: unknown;
}

export interface ProviderJobStatus {
  state: ProviderJobState;
  error?: { code: string; message: string; moderation?: boolean };
  usage?: ProviderUsage;
}

export interface ProviderJobResult {
  video_url: string;
  duration_s: number;
  usage: ProviderUsage;
  raw?: unknown;
}

export interface SubmitOptions {
  /** Our job id. Adapters must never submit twice for the same key. */
  idempotency_key: string;
  callback_url?: string;
}

export interface VideoProvider {
  readonly id: string;
  readonly model: string;
  /** true when calls cost real money. */
  readonly paid: boolean;
  capabilities(): ProviderCapabilities;
  supportsImageReference(): boolean;
  supportsAudioReference(): boolean;
  supportsCharacterReference(): boolean;
  /** Validates a request against capabilities; returns human-readable problems. */
  validateRequest(req: CompiledClipRequest): string[];
  generateClip(req: CompiledClipRequest, opts: SubmitOptions): Promise<{ provider_job_id: string }>;
  getJobStatus(providerJobId: string): Promise<ProviderJobStatus>;
  getResult(providerJobId: string): Promise<ProviderJobResult>;
}

/** Shared capability checks, reused by adapters. */
export function validateAgainstCapabilities(caps: ProviderCapabilities, req: CompiledClipRequest): string[] {
  const problems: string[] = [];
  if (!req.prompt.trim()) problems.push('prompt is empty');
  if (req.prompt.length > caps.max_prompt_chars)
    problems.push(`prompt is ${req.prompt.length} chars; provider max is ${caps.max_prompt_chars}`);
  if (req.duration_s < caps.min_duration_s || req.duration_s > caps.max_duration_s)
    problems.push(`duration ${req.duration_s}s outside ${caps.min_duration_s}–${caps.max_duration_s}s`);
  if (caps.integer_duration_only && !Number.isInteger(req.duration_s))
    problems.push(`duration ${req.duration_s}s must be an integer`);
  if (!caps.resolutions.includes(req.resolution)) problems.push(`resolution ${req.resolution} not supported`);
  if (!caps.ratios.includes(req.ratio)) problems.push(`ratio ${req.ratio} not supported`);
  if (req.reference_images.length > caps.max_reference_images)
    problems.push(`${req.reference_images.length} reference images; max ${caps.max_reference_images}`);
  if (req.reference_audios.length > caps.max_reference_audios)
    problems.push(`${req.reference_audios.length} reference audios; max ${caps.max_reference_audios}`);
  if (req.reference_images.length && !caps.image_reference) problems.push('provider has no image reference');
  if (req.reference_audios.length && !caps.audio_reference) problems.push('provider has no audio reference');
  const hasFrames = Boolean(req.first_frame || req.last_frame);
  if (hasFrames && !caps.first_last_frame) problems.push('provider has no first/last frame input');
  if (hasFrames && (req.reference_images.length || req.reference_audios.length) && !caps.frames_and_references_together)
    problems.push('first/last frames cannot be combined with reference images/audio on this provider');
  return problems;
}
