// Video Studio CORE domain types. Subject-independent: nothing here knows
// about insurance, exams or PassPro. Field names mirror the vs_* tables.

export type ClipStatus =
  | 'PLANNED'
  | 'APPROVED'
  | 'GENERATING'
  | 'COMPLETE'
  | 'FAILED'
  | 'NEEDS_REVIEW'
  | 'LOCKED';

export type EpisodeStatus =
  | 'DRAFT'
  | 'ANALYZED'
  | 'CONTENT_CONFLICT'
  | 'APPROVED'
  | 'GENERATING'
  | 'IN_REVIEW'
  | 'RENDERING'
  | 'RENDERED'
  | 'PUBLISHED';

export interface SeriesDefaults {
  provider: string;
  model: string;
  resolution: string;
  ratio: string;
}

export interface SeriesBible {
  generation_rules: string[];
  continuity_rules: string[];
  negative_prompt: string;
  defaults: SeriesDefaults;
  /** Opt-in hook for layers (e.g. PassPro content locks). Core ignores it. */
  content_lock_scopes?: string[];
  default_location_slug?: string;
}

export interface Series {
  id: string;
  slug: string;
  name: string;
  language: string;
  target_audience: string;
  visual_style: string;
  bible: SeriesBible;
}

export interface VoiceProfile {
  /** 'minimax-native' = the video model voices the character itself. */
  provider: string;
  voice_id?: string;
  settings?: Record<string, unknown>;
  description?: string;
  master_sample_asset_id?: string;
}

export interface Character {
  id: string;
  series_id: string;
  slug: string;
  name: string;
  aliases: string[];
  age: number | null;
  description: string;
  personality: string[];
  wardrobe: string;
  visual_prompt: string;
  negative_prompt: string;
  continuity_notes: string;
  rules: string[];
  voice_only: boolean;
  voice: VoiceProfile;
  primary_reference_asset_id: string | null;
}

export type AssetKind = 'location' | 'prop' | 'reference_image' | 'voice_sample' | 'style_reference';

export interface Asset {
  id: string;
  series_id: string;
  kind: AssetKind;
  slug: string;
  name: string;
  aliases: string[];
  description: string;
  visual_prompt: string;
  negative_prompt: string;
  continuity_notes: string;
  character_id: string | null;
  parent_asset_id: string | null;
  storage_path: string | null;
  mime_type: string | null;
  status: 'pending_upload' | 'ready' | 'retired';
  metadata: Record<string, unknown>;
}

export interface DialogueLine {
  speaker_character_id: string | null;
  speaker_label: string;
  /** Verbatim from the canonical script. */
  text: string;
  /** 1-based line number in the script. */
  source_line: number;
  est_start_s: number;
  est_end_s: number;
  delivery?: string;
}

export interface Scene {
  id: string;
  episode_id: string;
  ord: number;
  heading: string;
  location_asset_id: string | null;
  summary: string;
}

export type IssueSeverity = 'conflict' | 'review' | 'info';

/** Produced by any validator layer. conflict/review block approval until resolved/acknowledged. */
export interface ValidationIssue {
  code: string;
  severity: IssueSeverity;
  message: string;
  source: string;
  clip_id?: string;
  found?: string;
  expected?: string;
  lock_id?: string;
  acknowledged?: boolean;
  acknowledged_by?: string;
}

export interface ClipVersion {
  version: number;
  job_id: string;
  provider: string;
  model: string;
  prompt: string;
  reference_asset_ids: string[];
  settings: Record<string, unknown>;
  cost_usd: number;
  simulated: boolean;
  storage_path: string;
  duration_s: number;
  created_at: string;
  deleted_at: string | null;
}

export interface AudioRequirements {
  /** native = video model voices the dialogue; dub = TTS overlay at render. */
  mode: 'native' | 'dub';
  notes: string[];
}

export interface Clip {
  id: string;
  episode_id: string;
  scene_id: string;
  ord: number;
  duration_estimate_s: number;
  location_asset_id: string | null;
  character_ids: string[];
  dialogue: DialogueLine[];
  action: string;
  camera_direction: string;
  visual_prompt: string;
  audio_requirements: AudioRequirements;
  reference_asset_ids: string[];
  continuity: { from_previous: string; into_next: string };
  estimated_cost_usd: number | null;
  pricing_verified: boolean;
  status: ClipStatus;
  issues: ValidationIssue[];
  versions: ClipVersion[];
  selected_version: number | null;
  edited_by_human: boolean;
}

export interface EpisodeApproval {
  plan_hash: string;
  approved_by: string;
  approved_at: string;
  authorized_max_usd: number;
  retry_budget_usd: number;
  estimated_total_usd: number;
}

export interface TimelineItem {
  clip_id: string;
  version: number;
  enabled: boolean;
  /** How the timeline goes INTO this clip. Transitions are added only when specified. */
  transition: 'cut' | 'fade';
}

export interface Episode {
  id: string;
  series_id: string;
  number: number;
  title: string;
  language: string;
  target_duration_s: number | null;
  script: string;
  script_sha256: string | null;
  status: EpisodeStatus;
  plan_version: number;
  plan_hash: string | null;
  analysis: Record<string, unknown>;
  approval: EpisodeApproval | null;
  timeline: TimelineItem[];
  render_settings: { captions: boolean; caption_language: string; burn_in?: boolean };
}

export type JobType = 'clip' | 'voice' | 'render';
export type JobStatus =
  | 'RESERVED'
  | 'SUBMITTED'
  | 'QUEUED'
  | 'RUNNING'
  | 'SUCCEEDED'
  | 'FAILED'
  | 'CANCELLED'
  | 'NEEDS_REVIEW';

export interface GenerationJob {
  id: string;
  job_type: JobType;
  episode_id: string;
  clip_id: string | null;
  provider: string;
  provider_model: string | null;
  provider_job_id: string | null;
  idempotency_key: string;
  status: JobStatus;
  is_regeneration: boolean;
  request: Record<string, unknown>;
  cost_estimate_usd: number;
  actual_cost_usd: number | null;
  usage: Record<string, unknown> | null;
  error: Record<string, unknown> | null;
  output_url: string | null;
  output_storage_path: string | null;
  submitted_at: string | null;
  completed_at: string | null;
  created_at: string;
}

export type LedgerEntryType = 'authorization' | 'reservation' | 'actual' | 'release' | 'adjustment';
export type LedgerCategory = 'initial' | 'regeneration' | 'voice' | 'planner' | 'render' | 'retry_budget';

export interface LedgerEntry {
  id: number;
  episode_id: string;
  scene_id: string | null;
  clip_id: string | null;
  job_id: string | null;
  entry_type: LedgerEntryType;
  category: LedgerCategory;
  provider: string | null;
  amount_usd: number;
  simulated: boolean;
  metadata: Record<string, unknown>;
  created_by: string | null;
  created_at: string;
}

export interface BudgetSettings {
  max_cost_per_clip_usd: number;
  max_cost_per_episode_usd: number;
  max_daily_spend_usd: number;
  max_retry_budget_per_episode_usd: number;
  timezone: string;
}

export interface GenerationSettings {
  enabled: boolean;
  paid_providers_enabled: boolean;
  max_concurrent_jobs: number;
}

/** Thrown for every refused action. `code` is stable and matches the SQL guards (VS_*). */
export class StudioError extends Error {
  readonly code: string;
  readonly details?: unknown;
  constructor(code: string, message: string, details?: unknown) {
    super(`${code}: ${message}`);
    this.name = 'StudioError';
    this.code = code;
    this.details = details;
  }
}
