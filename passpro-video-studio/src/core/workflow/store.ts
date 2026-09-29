// Persistence boundary. Production implementation: Supabase (vs_* tables +
// SQL money functions). MemoryStudioStore below backs tests and the demo and
// applies the same guards through budget-guard.ts.
//
// Every workflow state lives here — never only in UI memory — so the UI can
// refresh at any time and resume from the store.

import type {
  Asset,
  BudgetSettings,
  Character,
  Clip,
  Episode,
  GenerationJob,
  GenerationSettings,
  LedgerCategory,
  LedgerEntry,
  Scene,
  Series,
} from '../types.ts';
import { StudioError } from '../types.ts';
import type { PriceRow } from '../pricing.ts';
import { checkApproval, checkReservation, DEFAULT_BUDGET, DEFAULT_GENERATION } from '../budget/budget-guard.ts';
import { CostLedger, committedUsd } from '../ledger/ledger.ts';
import { uuid } from '../util.ts';

export interface StudioSettings {
  budget: BudgetSettings;
  generation: GenerationSettings;
  pricing: PriceRow[];
}

export interface ReserveArgs {
  clip_id: string;
  provider: string;
  model: string;
  estimate_usd: number;
  idempotency_key: string;
  is_regeneration: boolean;
  simulated: boolean;
  request: Record<string, unknown>;
}

export interface StudioStore {
  settings(): Promise<StudioSettings>;
  getSeries(id: string): Promise<Series>;
  listCharacters(seriesId: string): Promise<Character[]>;
  listAssets(seriesId: string): Promise<Asset[]>;
  saveAsset(asset: Asset): Promise<void>;
  saveCharacter(c: Character): Promise<void>;

  createEpisode(ep: Omit<Episode, 'id'>): Promise<Episode>;
  getEpisode(id: string): Promise<Episode>;
  saveEpisode(ep: Episode): Promise<void>;
  listScenes(episodeId: string): Promise<Scene[]>;
  listClips(episodeId: string): Promise<Clip[]>;
  getClip(id: string): Promise<Clip>;
  saveClip(c: Clip): Promise<void>;
  replacePlan(episodeId: string, scenes: Scene[], clips: Clip[]): Promise<void>;

  /** Human approval (vs_approve_episode). */
  approveEpisode(a: { episode_id: string; plan_hash: string; authorized_max_usd: number; retry_budget_usd: number; approved_by: string }): Promise<Episode>;
  /** Extra money for one clip's regeneration (vs_authorize_regeneration). */
  authorizeRegeneration(clipId: string, maxUsd: number, by: string): Promise<void>;
  /**
   * Atomic limit check + job row + reservation (vs_reserve_generation).
   * Idempotent per key: a replay returns the existing job with created=false.
   */
  reserveGeneration(a: ReserveArgs): Promise<{ job: GenerationJob; created: boolean }>;
  /** Release reservation + record actual (vs_settle_job). Idempotent. */
  settleJob(jobId: string, status: 'SUCCEEDED' | 'FAILED' | 'CANCELLED' | 'NEEDS_REVIEW', actualUsd: number, usage: Record<string, unknown> | null, error: Record<string, unknown> | null): Promise<void>;

  getJob(id: string): Promise<GenerationJob>;
  saveJob(job: GenerationJob): Promise<void>;
  listJobs(episodeId: string): Promise<GenerationJob[]>;
  createRenderJob(episodeId: string, request: Record<string, unknown>, key: string): Promise<GenerationJob>;
  ledger(): Promise<readonly LedgerEntry[]>;
}

const clone = <T>(x: T): T => structuredClone(x);

export class MemoryStudioStore implements StudioStore {
  private data = {
    settings: { budget: DEFAULT_BUDGET, generation: DEFAULT_GENERATION, pricing: [] as PriceRow[] } as StudioSettings,
    series: new Map<string, Series>(),
    characters: new Map<string, Character>(),
    assets: new Map<string, Asset>(),
    episodes: new Map<string, Episode>(),
    scenes: new Map<string, Scene>(),
    clips: new Map<string, Clip>(),
    jobs: new Map<string, GenerationJob>(),
  };
  costLedger: CostLedger;
  private clock: () => Date;

  constructor(clock: () => Date = () => new Date()) {
    this.clock = clock;
    this.costLedger = new CostLedger(clock);
  }

  // ------------------------------------------------------------ seeding
  setSettings(s: Partial<StudioSettings>) {
    this.data.settings = { ...this.data.settings, ...clone(s) };
  }
  addSeries(s: Series) { this.data.series.set(s.id, clone(s)); }
  addCharacter(c: Character) { this.data.characters.set(c.id, clone(c)); }
  addAsset(a: Asset) { this.data.assets.set(a.id, clone(a)); }

  /** Serialize everything (used to prove state survives a restart/refresh). */
  snapshot(): string {
    return JSON.stringify({
      settings: this.data.settings,
      series: [...this.data.series.values()],
      characters: [...this.data.characters.values()],
      assets: [...this.data.assets.values()],
      episodes: [...this.data.episodes.values()],
      scenes: [...this.data.scenes.values()],
      clips: [...this.data.clips.values()],
      jobs: [...this.data.jobs.values()],
      ledger: this.costLedger.all(),
    });
  }
  static restore(json: string, clock?: () => Date): MemoryStudioStore {
    const d = JSON.parse(json);
    const s = new MemoryStudioStore(clock);
    s.data.settings = d.settings;
    for (const x of d.series) s.data.series.set(x.id, x);
    for (const x of d.characters) s.data.characters.set(x.id, x);
    for (const x of d.assets) s.data.assets.set(x.id, x);
    for (const x of d.episodes) s.data.episodes.set(x.id, x);
    for (const x of d.scenes) s.data.scenes.set(x.id, x);
    for (const x of d.clips) s.data.clips.set(x.id, x);
    for (const x of d.jobs) s.data.jobs.set(x.id, x);
    s.costLedger = CostLedger.fromRows(d.ledger, clock);
    return s;
  }

  private must<T>(m: Map<string, T>, id: string, what: string): T {
    const v = m.get(id);
    if (!v) throw new StudioError('VS_NOT_FOUND', `${what} ${id}`);
    return clone(v);
  }

  // ------------------------------------------------------------ reads/writes
  async settings() { return clone(this.data.settings); }
  async getSeries(id: string) { return this.must(this.data.series, id, 'series'); }
  async listCharacters(seriesId: string) { return [...this.data.characters.values()].filter((c) => c.series_id === seriesId).map(clone); }
  async listAssets(seriesId: string) { return [...this.data.assets.values()].filter((a) => a.series_id === seriesId).map(clone); }
  async saveAsset(a: Asset) { this.data.assets.set(a.id, clone(a)); }
  async saveCharacter(c: Character) { this.data.characters.set(c.id, clone(c)); }

  async createEpisode(ep: Omit<Episode, 'id'>) {
    if ([...this.data.episodes.values()].some((e) => e.series_id === ep.series_id && e.number === ep.number))
      throw new StudioError('VS_DUPLICATE', `episode ${ep.number} already exists in this series`);
    const e = { ...clone(ep), id: uuid() } as Episode;
    this.data.episodes.set(e.id, e);
    return clone(e);
  }
  async getEpisode(id: string) { return this.must(this.data.episodes, id, 'episode'); }
  async saveEpisode(ep: Episode) { this.data.episodes.set(ep.id, clone(ep)); }
  async listScenes(episodeId: string) {
    return [...this.data.scenes.values()].filter((s) => s.episode_id === episodeId).sort((a, b) => a.ord - b.ord).map(clone);
  }
  async listClips(episodeId: string) {
    return [...this.data.clips.values()].filter((c) => c.episode_id === episodeId).sort((a, b) => a.ord - b.ord).map(clone);
  }
  async getClip(id: string) { return this.must(this.data.clips, id, 'clip'); }
  async saveClip(c: Clip) { this.data.clips.set(c.id, clone(c)); }
  async replacePlan(episodeId: string, scenes: Scene[], clips: Clip[]) {
    for (const [id, c] of this.data.clips) if (c.episode_id === episodeId) this.data.clips.delete(id);
    for (const [id, s] of this.data.scenes) if (s.episode_id === episodeId) this.data.scenes.delete(id);
    for (const s of scenes) this.data.scenes.set(s.id, clone(s));
    for (const c of clips) this.data.clips.set(c.id, clone(c));
  }

  // ------------------------------------------------------------ money
  async approveEpisode(a: { episode_id: string; plan_hash: string; authorized_max_usd: number; retry_budget_usd: number; approved_by: string }) {
    const ep = await this.getEpisode(a.episode_id);
    const clips = await this.listClips(a.episode_id);
    const { budget } = await this.settings();
    const estimate = checkApproval({
      episode: ep, clips, plan_hash: a.plan_hash, authorized_max_usd: a.authorized_max_usd,
      retry_budget_usd: a.retry_budget_usd, budget,
      committed_initial_usd: committedUsd([...this.costLedger.all()], ep.id, ['initial']),
    });
    this.costLedger.append({ episode_id: ep.id, entry_type: 'authorization', category: 'initial', amount_usd: a.authorized_max_usd,
      created_by: a.approved_by, metadata: { plan_hash: a.plan_hash, estimated_total_usd: estimate } });
    if (a.retry_budget_usd > 0)
      this.costLedger.append({ episode_id: ep.id, entry_type: 'authorization', category: 'retry_budget', amount_usd: a.retry_budget_usd,
        created_by: a.approved_by, metadata: { plan_hash: a.plan_hash } });
    for (const c of clips) if (c.status === 'PLANNED') this.data.clips.set(c.id, { ...c, status: 'APPROVED' });
    ep.status = 'APPROVED';
    ep.approval = {
      plan_hash: a.plan_hash, approved_by: a.approved_by, approved_at: this.clock().toISOString(),
      authorized_max_usd: a.authorized_max_usd, retry_budget_usd: a.retry_budget_usd, estimated_total_usd: estimate,
    };
    this.data.episodes.set(ep.id, clone(ep));
    return ep;
  }

  async authorizeRegeneration(clipId: string, maxUsd: number, by: string) {
    const clip = await this.getClip(clipId);
    const { budget } = await this.settings();
    if (!(maxUsd > 0) || maxUsd > budget.max_cost_per_clip_usd)
      throw new StudioError('VS_BUDGET', 'regeneration authorization must be > 0 and <= per-clip limit');
    this.costLedger.append({ episode_id: clip.episode_id, scene_id: clip.scene_id, clip_id: clip.id, entry_type: 'authorization',
      category: 'regeneration', amount_usd: maxUsd, created_by: by, metadata: { scope: 'single_clip' } });
  }

  async reserveGeneration(a: ReserveArgs): Promise<{ job: GenerationJob; created: boolean }> {
    const existing = [...this.data.jobs.values()].find((j) => j.idempotency_key === a.idempotency_key);
    if (existing) return { job: clone(existing), created: false };
    const clip = await this.getClip(a.clip_id);
    const ep = await this.getEpisode(clip.episode_id);
    const s = await this.settings();
    const category: LedgerCategory = checkReservation({
      episode: ep, clip, estimate_usd: a.estimate_usd, is_regeneration: a.is_regeneration, simulated: a.simulated,
      budget: s.budget, generation: s.generation, ledger: this.costLedger.all(), now: this.clock(),
    });
    const job: GenerationJob = {
      id: uuid(), job_type: 'clip', episode_id: ep.id, clip_id: clip.id, provider: a.provider, provider_model: a.model,
      provider_job_id: null, idempotency_key: a.idempotency_key, status: 'RESERVED', is_regeneration: a.is_regeneration,
      request: clone(a.request), cost_estimate_usd: a.estimate_usd, actual_cost_usd: null, usage: null, error: null,
      output_url: null, output_storage_path: null, submitted_at: null, completed_at: null, created_at: this.clock().toISOString(),
    };
    this.data.jobs.set(job.id, job);
    this.costLedger.append({ episode_id: ep.id, scene_id: clip.scene_id, clip_id: clip.id, job_id: job.id, entry_type: 'reservation',
      category, provider: a.provider, amount_usd: a.estimate_usd, simulated: a.simulated });
    this.data.clips.set(clip.id, { ...clip, status: 'GENERATING' });
    return { job: clone(job), created: true };
  }

  async settleJob(jobId: string, status: 'SUCCEEDED' | 'FAILED' | 'CANCELLED' | 'NEEDS_REVIEW', actualUsd: number, usage: Record<string, unknown> | null, error: Record<string, unknown> | null) {
    const job = this.must(this.data.jobs, jobId, 'job');
    if (job.completed_at) return;
    const rows = this.costLedger.all().filter((e) => e.job_id === jobId);
    const res = rows.find((e) => e.entry_type === 'reservation');
    const open = rows.reduce((s, e) => s + (e.entry_type === 'reservation' ? e.amount_usd : e.entry_type === 'release' ? -e.amount_usd : 0), 0);
    if (res && open > 0)
      this.costLedger.append({ episode_id: res.episode_id, clip_id: res.clip_id, job_id: jobId, entry_type: 'release', category: res.category,
        provider: res.provider, amount_usd: open, simulated: res.simulated });
    if (res && actualUsd > 0)
      this.costLedger.append({ episode_id: res.episode_id, scene_id: res.scene_id, clip_id: res.clip_id, job_id: jobId, entry_type: 'actual',
        category: res.category, provider: res.provider, amount_usd: actualUsd, simulated: res.simulated, metadata: { usage } });
    this.data.jobs.set(jobId, { ...job, status, actual_cost_usd: actualUsd, usage, error, completed_at: this.clock().toISOString() });
  }

  async getJob(id: string) { return this.must(this.data.jobs, id, 'job'); }
  async saveJob(job: GenerationJob) { this.data.jobs.set(job.id, clone(job)); }
  async listJobs(episodeId: string) {
    return [...this.data.jobs.values()].filter((j) => j.episode_id === episodeId).sort((a, b) => a.created_at.localeCompare(b.created_at)).map(clone);
  }
  async createRenderJob(episodeId: string, request: Record<string, unknown>, key: string) {
    const existing = [...this.data.jobs.values()].find((j) => j.idempotency_key === key);
    if (existing) return clone(existing);
    const job: GenerationJob = {
      id: uuid(), job_type: 'render', episode_id: episodeId, clip_id: null, provider: 'ffmpeg', provider_model: null,
      provider_job_id: null, idempotency_key: key, status: 'QUEUED', is_regeneration: false, request: clone(request),
      cost_estimate_usd: 0, actual_cost_usd: null, usage: null, error: null, output_url: null, output_storage_path: null,
      submitted_at: null, completed_at: null, created_at: this.clock().toISOString(),
    };
    this.data.jobs.set(job.id, job);
    return clone(job);
  }
  async ledger() { return this.costLedger.all(); }
}
