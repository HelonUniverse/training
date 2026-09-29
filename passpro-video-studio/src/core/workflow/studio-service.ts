// StudioService — the whole MVP workflow, stateless over a StudioStore:
//
//   create episode → analyze (plan, validate, estimate; NO generation)
//   → edit / approve clips → approve episode (human, bound to plan hash)
//   → generate (budget-guarded, idempotent) → poll → versions
//   → regenerate ONE clip (retry budget or explicit authorization)
//   → select version → timeline → render request → cost summary
//
// Nothing here calls a provider before explicit approval: generateApproved()
// only submits clips whose reservation passes vs_reserve_generation rules.

import type { Clip, Episode, GenerationJob, Scene, TimelineItem, ValidationIssue } from '../types.ts';
import { StudioError } from '../types.ts';
import type { StudioStore } from './store.ts';
import type { StudioLayer } from './hooks.ts';
import type { VideoProvider } from '../providers/video-provider.ts';
import { SubmissionNotSentError } from '../providers/video-provider.ts';
import { RuleBasedPlanner, checkDialogueFidelity, computePlanHash, type ProductionPlanner } from '../planner/planner.ts';
import { parseScript } from '../planner/script-parser.ts';
import { compileClipPrompt } from '../compiler/prompt-compiler.ts';
import { estimateClipCost } from '../pricing.ts';
import { blockingIssues } from '../budget/budget-guard.ts';
import { summarizeCosts, type CostSummary } from '../ledger/ledger.ts';
import { buildCaptionCues, toSrt } from '../captions/srt.ts';
import { clipVersionPath, type MediaStorage } from '../storage/storage.ts';
import type { RenderSpec } from '../render/render-spec.ts';
import { sha256Hex } from '../util.ts';

export interface StudioDeps {
  store: StudioStore;
  provider: VideoProvider;
  storage: MediaStorage;
  layers?: StudioLayer[];
  planner?: ProductionPlanner;
  clock?: () => Date;
  callbackUrl?: (jobId: string) => string | undefined;
}

export type ClipEdit = Partial<
  Pick<Clip, 'dialogue' | 'action' | 'camera_direction' | 'visual_prompt' | 'duration_estimate_s' | 'audio_requirements' | 'reference_asset_ids' | 'character_ids' | 'location_asset_id'>
>;

const OPEN_JOB = new Set(['RESERVED', 'SUBMITTED', 'QUEUED', 'RUNNING']);
const issueKey = (i: ValidationIssue) => [i.source, i.code, i.found ?? '', i.expected ?? '', i.lock_id ?? '', i.clip_id ?? ''].join('|');

export class StudioService {
  private d: Required<Omit<StudioDeps, 'callbackUrl'>> & Pick<StudioDeps, 'callbackUrl'>;

  constructor(deps: StudioDeps) {
    this.d = { layers: [], planner: new RuleBasedPlanner(), clock: () => new Date(), ...deps };
  }

  // ================================================================ episodes

  async createEpisode(a: { series_id: string; number: number; title: string; script: string; target_duration_s?: number; language?: string }): Promise<Episode> {
    const series = await this.d.store.getSeries(a.series_id);
    return this.d.store.createEpisode({
      series_id: series.id, number: a.number, title: a.title, language: a.language ?? series.language,
      target_duration_s: a.target_duration_s ?? null, script: a.script, script_sha256: await sha256Hex(a.script),
      status: 'DRAFT', plan_version: 0, plan_hash: null, analysis: {}, approval: null, timeline: [],
      render_settings: { captions: true, caption_language: series.language, burn_in: false },
    });
  }

  /** ANALYZE SCRIPT: builds the production plan. Never calls a video provider. */
  async analyzeEpisode(episodeId: string) {
    const ep = await this.d.store.getEpisode(episodeId);
    const existing = await this.d.store.listClips(episodeId);
    if (existing.some((c) => c.versions.length || c.status === 'GENERATING'))
      throw new StudioError('VS_STATE', 'clips were already generated; edit individual clips instead of re-analyzing');
    const series = await this.d.store.getSeries(ep.series_id);
    const characters = await this.d.store.listCharacters(series.id);
    const assets = await this.d.store.listAssets(series.id);
    const { pricing } = await this.d.store.settings();
    const p = this.d.provider;
    const draft = await this.d.planner.plan({
      episode_id: ep.id, script: ep.script, series, characters, assets, pricing,
      provider: { id: p.id, model: p.model, paid: p.paid, capabilities: p.capabilities() },
      resolution: series.bible.defaults.resolution,
    });

    for (const clip of draft.clips) {
      const fid = draft.warnings.filter((w) => w.clip_id === clip.id);
      clip.issues = [...clip.issues, ...fid, ...(await this.layerIssues(clip, series))];
    }
    const episodeWarnings = draft.warnings.filter((w) => !w.clip_id);
    await this.d.store.replacePlan(ep.id, draft.scenes, draft.clips);

    ep.plan_version += 1;
    ep.plan_hash = await computePlanHash(draft.scenes, draft.clips);
    ep.approval = null;
    ep.timeline = [];
    const blocking = blockingIssues(draft.clips);
    ep.status = draft.clips.some((c) => c.issues.some((i) => i.severity === 'conflict')) ? 'CONTENT_CONFLICT' : 'ANALYZED';
    ep.analysis = { summary: draft.summary, warnings: episodeWarnings, blocking_count: blocking.length, title_from_script: draft.title };
    await this.d.store.saveEpisode(ep);
    return this.planView(ep.id);
  }

  /** Everything the Production Plan screen shows. */
  async planView(episodeId: string) {
    const ep = await this.d.store.getEpisode(episodeId);
    const scenes = await this.d.store.listScenes(episodeId);
    const clips = await this.d.store.listClips(episodeId);
    const characters = await this.d.store.listCharacters(ep.series_id);
    const { budget } = await this.d.store.settings();
    const byChar = new Map(characters.map((c) => [c.id, c.name]));
    const total = clips.reduce((s, c) => s + (c.estimated_cost_usd ?? NaN), 0);
    const all = clips.flatMap((c) => c.issues);
    return {
      episode: { id: ep.id, number: ep.number, title: ep.title, status: ep.status, plan_hash: ep.plan_hash, approval: ep.approval },
      estimated_duration_s: clips.reduce((s, c) => s + c.duration_estimate_s, 0),
      scene_count: scenes.length,
      clip_count: clips.length,
      characters: [...new Set(clips.flatMap((c) => c.character_ids))].map((id) => byChar.get(id) ?? id),
      estimated_total_usd: Number.isNaN(total) ? null : Math.round(total * 100) / 100,
      pricing_verified: clips.every((c) => c.pricing_verified),
      maximum_possible_authorized_usd: Math.min(budget.max_cost_per_episode_usd, Number.isNaN(total) ? Infinity : total + budget.max_retry_budget_per_episode_usd),
      content_conflicts: all.filter((i) => i.severity === 'conflict'),
      needs_review: all.filter((i) => i.severity === 'review' && !i.acknowledged),
      warnings: (ep.analysis as { warnings?: ValidationIssue[] }).warnings ?? [],
      scenes: scenes.map((s) => ({
        ...s,
        clips: clips.filter((c) => c.scene_id === s.id).map((c) => ({
          id: c.id, ord: c.ord, duration_s: c.duration_estimate_s, status: c.status, action: c.action,
          camera: c.camera_direction, characters: c.character_ids.map((id) => byChar.get(id) ?? id),
          dialogue: c.dialogue.map((d) => ({ speaker: d.speaker_label, text: d.text })),
          estimated_cost_usd: c.estimated_cost_usd, pricing_verified: c.pricing_verified, issues: c.issues,
          versions: c.versions.filter((v) => !v.deleted_at).map((v) => v.version), selected_version: c.selected_version,
        })),
      })),
    };
  }

  // ================================================================ review

  async editClip(clipId: string, patch: ClipEdit, by: string): Promise<Clip> {
    const clip = await this.d.store.getClip(clipId);
    if (clip.status === 'GENERATING' || clip.status === 'LOCKED')
      throw new StudioError('VS_STATE', `cannot edit a clip that is ${clip.status}`);
    const ep = await this.d.store.getEpisode(clip.episode_id);
    const series = await this.d.store.getSeries(ep.series_id);
    const caps = this.d.provider.capabilities();
    if (patch.duration_estimate_s !== undefined) {
      const dur = patch.duration_estimate_s;
      if (dur < caps.min_duration_s || dur > caps.max_duration_s || (caps.integer_duration_only && !Number.isInteger(dur)))
        throw new StudioError('VS_INVALID', `duration must be ${caps.integer_duration_only ? 'an integer ' : ''}between ${caps.min_duration_s} and ${caps.max_duration_s}s`);
    }
    const next: Clip = { ...clip, ...structuredClone(patch), edited_by_human: true };
    if (patch.action !== undefined && patch.visual_prompt === undefined && clip.visual_prompt === clip.action) next.visual_prompt = patch.action;
    if (next.status === 'APPROVED') next.status = 'PLANNED';

    const { pricing } = await this.d.store.settings();
    const est = estimateClipCost(pricing, {
      provider: this.d.provider.id, model: this.d.provider.model, resolution: series.bible.defaults.resolution,
      duration_s: next.duration_estimate_s, reference_image_count: next.reference_asset_ids.length,
    });
    next.estimated_cost_usd = est.amount_usd;
    next.pricing_verified = est.verified;
    await this.revalidate(next, series, est.issues);
    await this.d.store.saveClip(next);
    await this.refreshPlanHash(ep);
    return next;
  }

  /** Per-clip APPROVE button (review mark). Money is authorized only by approveEpisode. */
  async approveClip(clipId: string): Promise<Clip> {
    const clip = await this.d.store.getClip(clipId);
    if (blockingIssues([clip]).length) throw new StudioError('VS_CONTENT_BLOCKED', 'resolve this clip’s issues first');
    if (clip.status === 'PLANNED') clip.status = 'APPROVED';
    await this.d.store.saveClip(clip);
    return clip;
  }

  /** A reviewer confirms a REVIEW item on purpose. CONTENT CONFLICTS cannot be acknowledged. */
  async acknowledgeIssue(clipId: string, code: string, by: string, found?: string): Promise<Clip> {
    const clip = await this.d.store.getClip(clipId);
    const target = clip.issues.find((i) => i.code === code && (found === undefined || i.found === found) && !i.acknowledged);
    if (!target) throw new StudioError('VS_NOT_FOUND', `no open issue ${code} on this clip`);
    if (target.severity === 'conflict')
      throw new StudioError('VS_CONFLICT_NOT_ACKNOWLEDGEABLE', '⚠ CONTENT CONFLICT must be fixed in the script or in the verified source; it cannot be waved through');
    target.acknowledged = true;
    target.acknowledged_by = by;
    await this.d.store.saveClip(clip);
    const ep = await this.d.store.getEpisode(clip.episode_id);
    await this.refreshEpisodeStatus(ep);
    return clip;
  }

  async approveEpisode(episodeId: string, a: { plan_hash: string; authorized_max_usd: number; retry_budget_usd: number; approved_by: string }) {
    return this.d.store.approveEpisode({ episode_id: episodeId, ...a });
  }

  // ================================================================ generation

  /** Submits APPROVED clips (up to the concurrency limit). Safe to call repeatedly. */
  async generateApproved(episodeId: string): Promise<GenerationJob[]> {
    const ep = await this.d.store.getEpisode(episodeId);
    if (!ep.approval || ep.approval.plan_hash !== ep.plan_hash)
      throw new StudioError('VS_NOT_APPROVED', 'approve the episode (current plan) before generating');
    const { generation } = await this.d.store.settings();
    const jobs = await this.d.store.listJobs(episodeId);
    let open = jobs.filter((j) => j.job_type === 'clip' && OPEN_JOB.has(j.status)).length;
    const submitted: GenerationJob[] = [];
    for (const clip of await this.d.store.listClips(episodeId)) {
      if (open >= generation.max_concurrent_jobs) break;
      if (clip.status !== 'APPROVED' || clip.versions.length) continue;
      const attempt = jobs.filter((j) => j.clip_id === clip.id).length + 1;
      const job = await this.submitClip(ep, clip, false, `clip:${clip.id}:plan:${ep.plan_hash}:attempt:${attempt}`);
      if (job) {
        submitted.push(job);
        open += 1;
      }
    }
    if (submitted.length) {
      ep.status = 'GENERATING';
      await this.d.store.saveEpisode(await this.withStatus(ep.id, 'GENERATING'));
    }
    return submitted;
  }

  /** Regenerate ONE clip. Other clips are untouched. */
  async regenerateClip(clipId: string, by: string): Promise<GenerationJob> {
    const clip = await this.d.store.getClip(clipId);
    const ep = await this.d.store.getEpisode(clip.episode_id);
    const n = (await this.d.store.listJobs(ep.id)).filter((j) => j.clip_id === clipId).length + 1;
    const job = await this.submitClip(ep, clip, true, `clip:${clip.id}:regen:${n}`, by);
    if (!job) throw new StudioError('VS_CONTENT_BLOCKED', 'the compiled prompt failed validation; see clip issues');
    return job;
  }

  async authorizeRegeneration(clipId: string, maxUsd: number, by: string) {
    return this.d.store.authorizeRegeneration(clipId, maxUsd, by);
  }

  private async submitClip(ep: Episode, clip: Clip, isRegeneration: boolean, key: string, _by?: string): Promise<GenerationJob | null> {
    const series = await this.d.store.getSeries(ep.series_id);
    const characters = await this.d.store.listCharacters(series.id);
    const assets = await this.d.store.listAssets(series.id);
    const scenes = await this.d.store.listScenes(ep.id);
    const clips = await this.d.store.listClips(ep.id);
    const scene = scenes.find((s) => s.id === clip.scene_id) as Scene;
    const facts = (await Promise.all(this.d.layers.map((l) => l.facts?.factsForClip(clip, series) ?? []))).flat();
    const compiled = await compileClipPrompt({
      series, characters, assets, scene, clip, clip_count: clips.length, capabilities: this.d.provider.capabilities(),
      resolution: series.bible.defaults.resolution, ratio: series.bible.defaults.ratio,
      resolveMedia: (a) => this.d.storage.urlFor(a.storage_path!), facts,
    });

    // Final gate: validate exactly what would be sent.
    const promptIssues = (await Promise.all(this.d.layers.flatMap((l) => l.validators.map((v) => v.validateText(compiled.request.prompt, series, `clip ${clip.ord} compiled prompt`))))).flat()
      .map((i) => ({ ...i, clip_id: clip.id }));
    const problems = this.d.provider.validateRequest(compiled.request);
    if (problems.length) promptIssues.push({ code: 'PROVIDER_REQUEST_INVALID', severity: 'review', source: 'provider', clip_id: clip.id, message: problems.join('; ') });
    if (blockingIssues([{ ...clip, issues: promptIssues }]).length) {
      await this.d.store.saveClip({ ...clip, status: 'NEEDS_REVIEW', issues: mergeIssues(clip.issues, promptIssues) });
      return null;
    }

    const { pricing } = await this.d.store.settings();
    const est = estimateClipCost(pricing, {
      provider: this.d.provider.id, model: this.d.provider.model, resolution: compiled.request.resolution,
      duration_s: compiled.request.duration_s, reference_image_count: compiled.request.reference_images.length,
    });
    if (est.amount_usd === null) throw new StudioError('VS_NO_ESTIMATE', 'no confirmed price for this provider/model');

    const { job, created } = await this.d.store.reserveGeneration({
      clip_id: clip.id, provider: this.d.provider.id, model: this.d.provider.model, estimate_usd: est.amount_usd,
      idempotency_key: key, is_regeneration: isRegeneration, simulated: est.simulated || !this.d.provider.paid,
      request: {
        prompt: compiled.request.prompt, sections: compiled.sections, fact_ids: compiled.fact_ids,
        reference_asset_ids: compiled.request.reference_images.map((r) => r.asset_id),
        reference_audio_asset_ids: compiled.request.reference_audios.map((r) => r.asset_id),
        settings: { duration_s: compiled.request.duration_s, resolution: compiled.request.resolution, ratio: compiled.request.ratio },
        warnings: compiled.warnings,
      },
    });
    // Idempotent replay (double click, retry after a crash): NEVER submit again.
    // A job left RESERVED by a crash is ambiguous — a person must check it.
    if (!created) {
      if (job.status === 'RESERVED' && !job.provider_job_id) {
        await this.d.store.saveJob({ ...job, status: 'NEEDS_REVIEW', error: { message: 'reserved but submission state unknown' } });
        return { ...job, status: 'NEEDS_REVIEW' };
      }
      return job;
    }

    try {
      const { provider_job_id } = await this.d.provider.generateClip(compiled.request, { idempotency_key: job.id, callback_url: this.d.callbackUrl?.(job.id) });
      const saved = { ...job, provider_job_id, status: 'SUBMITTED' as const, submitted_at: this.d.clock().toISOString() };
      await this.d.store.saveJob(saved);
      return saved;
    } catch (err) {
      // Definitely-not-sent errors release the money; anything ambiguous goes to a human.
      const notSent = err instanceof SubmissionNotSentError;
      const status = notSent ? 'FAILED' : 'NEEDS_REVIEW';
      await this.d.store.settleJob(job.id, status, 0, null, { message: String(err), ambiguous_submission: !notSent });
      const c = await this.d.store.getClip(clip.id);
      await this.d.store.saveClip({ ...c, status: notSent ? 'FAILED' : 'NEEDS_REVIEW' });
      return { ...job, status };
    }
  }

  /** Poll open jobs, ingest results, settle money, then submit more approved clips. */
  async tick(episodeId: string): Promise<{ completed: number; failed: number; open: number }> {
    let completed = 0;
    let failed = 0;
    for (const job of await this.d.store.listJobs(episodeId)) {
      if (job.job_type !== 'clip' || !job.provider_job_id || !OPEN_JOB.has(job.status)) continue;
      const st = await this.d.provider.getJobStatus(job.provider_job_id);
      if (st.state === 'queued' || st.state === 'running') {
        const s = st.state === 'queued' ? 'QUEUED' : 'RUNNING';
        if (job.status !== s) await this.d.store.saveJob({ ...job, status: s });
        continue;
      }
      if (st.state === 'succeeded') {
        await this.completeJob(job);
        completed += 1;
      } else {
        failed += 1;
        const series = await this.seriesOf(episodeId);
        const actual = st.usage?.output_seconds ? this.actualCost(series.bible.defaults.resolution, st.usage) : 0;
        await this.d.store.settleJob(job.id, st.error?.moderation ? 'NEEDS_REVIEW' : 'FAILED', await actual, st.usage ?? null, st.error ?? { state: st.state });
        const clip = await this.d.store.getClip(job.clip_id!);
        // No automatic paid retry: a person decides (regenerateClip).
        await this.d.store.saveClip({ ...clip, status: st.error?.moderation ? 'NEEDS_REVIEW' : clip.versions.length ? 'COMPLETE' : 'FAILED' });
      }
    }
    const ep = await this.d.store.getEpisode(episodeId);
    if (ep.approval && ep.approval.plan_hash === ep.plan_hash) {
      // Queue the next approved clips. A refusal (e.g. daily limit) is recorded
      // for the UI instead of being retried or silently dropped.
      await this.generateApproved(episodeId).catch(async (err) => {
        const e = await this.d.store.getEpisode(episodeId);
        e.analysis = { ...e.analysis, last_generation_error: { code: (err as StudioError).code ?? 'ERROR', message: String((err as Error).message), at: this.d.clock().toISOString() } };
        await this.d.store.saveEpisode(e);
      });
    }
    const open = (await this.d.store.listJobs(episodeId)).filter((j) => j.job_type === 'clip' && OPEN_JOB.has(j.status)).length;
    const clips = await this.d.store.listClips(episodeId);
    if (!open && clips.every((c) => c.versions.length || c.status === 'FAILED' || c.status === 'NEEDS_REVIEW'))
      await this.d.store.saveEpisode(await this.withStatus(episodeId, 'IN_REVIEW'));
    return { completed, failed, open };
  }

  private async seriesOf(episodeId: string) {
    return this.d.store.getSeries((await this.d.store.getEpisode(episodeId)).series_id);
  }

  private async actualCost(resolution: string, usage: { output_seconds?: number; input_image_count?: number }): Promise<number> {
    const { pricing } = await this.d.store.settings();
    const est = estimateClipCost(pricing, {
      provider: this.d.provider.id, model: this.d.provider.model, resolution,
      duration_s: Number(usage.output_seconds ?? 0), reference_image_count: Number(usage.input_image_count ?? 0),
    });
    return est.amount_usd ?? 0;
  }

  private async completeJob(job: GenerationJob) {
    const result = await this.d.provider.getResult(job.provider_job_id!);
    const clip = await this.d.store.getClip(job.clip_id!);
    const version = Math.max(0, ...clip.versions.map((v) => v.version)) + 1;
    const ingest = await this.d.storage.ingestVideo(result.video_url, clipVersionPath(job.episode_id, clip.id, version), result.duration_s);
    const settings = (job.request.settings ?? {}) as Record<string, unknown>;
    const actual = await this.actualCost(String(settings.resolution ?? ''), result.usage.output_seconds ? result.usage : { output_seconds: result.duration_s });
    await this.d.store.settleJob(job.id, 'SUCCEEDED', actual, result.usage, null);
    await this.d.store.saveJob({ ...(await this.d.store.getJob(job.id)), output_url: null, output_storage_path: ingest.storage_path });
    const now = this.d.clock().toISOString();
    clip.versions.push({
      version, job_id: job.id, provider: job.provider, model: job.provider_model ?? '', prompt: String(job.request.prompt ?? ''),
      reference_asset_ids: (job.request.reference_asset_ids as string[]) ?? [], settings, cost_usd: actual,
      simulated: !this.d.provider.paid, storage_path: ingest.storage_path, duration_s: ingest.duration_s, created_at: now, deleted_at: null,
    });
    if (clip.selected_version === null) clip.selected_version = version;
    clip.status = 'COMPLETE';
    await this.d.store.saveClip(clip);
  }

  // ================================================================ versions & timeline

  async selectVersion(clipId: string, version: number): Promise<Clip> {
    const clip = await this.d.store.getClip(clipId);
    if (!clip.versions.some((v) => v.version === version && !v.deleted_at)) throw new StudioError('VS_NOT_FOUND', `version ${version}`);
    clip.selected_version = version;
    await this.d.store.saveClip(clip);
    const ep = await this.d.store.getEpisode(clip.episode_id);
    ep.timeline = ep.timeline.map((t) => (t.clip_id === clipId ? { ...t, version } : t));
    await this.d.store.saveEpisode(ep);
    return clip;
  }

  /** Soft delete: the file and ledger history stay; the selected version cannot be deleted. */
  async deleteVersion(clipId: string, version: number): Promise<Clip> {
    const clip = await this.d.store.getClip(clipId);
    if (clip.selected_version === version) throw new StudioError('VS_STATE', 'select another version before deleting this one');
    const v = clip.versions.find((x) => x.version === version && !x.deleted_at);
    if (!v) throw new StudioError('VS_NOT_FOUND', `version ${version}`);
    v.deleted_at = this.d.clock().toISOString();
    await this.d.store.saveClip(clip);
    return clip;
  }

  /** 01 → 02 → 03 … from each clip's selected version. */
  async buildTimeline(episodeId: string): Promise<{ timeline: TimelineItem[]; missing: number[] }> {
    const ep = await this.d.store.getEpisode(episodeId);
    const clips = await this.d.store.listClips(episodeId);
    const missing = clips.filter((c) => c.selected_version === null).map((c) => c.ord);
    ep.timeline = clips.filter((c) => c.selected_version !== null).map((c) => ({ clip_id: c.id, version: c.selected_version!, enabled: true, transition: 'cut' }));
    await this.d.store.saveEpisode(ep);
    return { timeline: ep.timeline, missing };
  }

  async reorderTimeline(episodeId: string, clipIds: string[]): Promise<TimelineItem[]> {
    const ep = await this.d.store.getEpisode(episodeId);
    const byId = new Map(ep.timeline.map((t) => [t.clip_id, t]));
    if (clipIds.length !== ep.timeline.length || clipIds.some((id) => !byId.has(id)))
      throw new StudioError('VS_INVALID', 'reorder must list every timeline clip exactly once');
    ep.timeline = clipIds.map((id) => byId.get(id)!);
    await this.d.store.saveEpisode(ep);
    return ep.timeline;
  }

  async removeFromTimeline(episodeId: string, clipId: string): Promise<TimelineItem[]> {
    const ep = await this.d.store.getEpisode(episodeId);
    ep.timeline = ep.timeline.map((t) => (t.clip_id === clipId ? { ...t, enabled: false } : t));
    await this.d.store.saveEpisode(ep);
    return ep.timeline;
  }

  async setTransition(episodeId: string, clipId: string, transition: 'cut' | 'fade'): Promise<void> {
    const ep = await this.d.store.getEpisode(episodeId);
    ep.timeline = ep.timeline.map((t) => (t.clip_id === clipId ? { ...t, transition } : t));
    await this.d.store.saveEpisode(ep);
  }

  // ================================================================ render & captions

  async captionsSrt(episodeId: string): Promise<string> {
    const ep = await this.d.store.getEpisode(episodeId);
    return toSrt(buildCaptionCues(ep.timeline, await this.d.store.listClips(episodeId)));
  }

  /** Queues a render job. The worker renders from storage only; no AI calls. */
  async requestRender(episodeId: string, opts: { captions?: boolean; burn_in?: boolean } = {}): Promise<{ job: GenerationJob; spec: RenderSpec }> {
    const ep = await this.d.store.getEpisode(episodeId);
    const clips = await this.d.store.listClips(episodeId);
    const byId = new Map(clips.map((c) => [c.id, c]));
    const items = ep.timeline.filter((t) => t.enabled);
    if (!items.length) throw new StudioError('VS_STATE', 'the timeline is empty; build it first');
    const inputs = items.map((t) => {
      const v = byId.get(t.clip_id)?.versions.find((x) => x.version === t.version && !x.deleted_at);
      if (!v) throw new StudioError('VS_STATE', `timeline clip ${byId.get(t.clip_id)?.ord ?? t.clip_id} has no playable version ${t.version}`);
      return { clip_id: t.clip_id, version: t.version, storage_path: v.storage_path, duration_s: v.duration_s, transition: t.transition };
    });
    const captions = opts.captions ?? ep.render_settings.captions;
    const srt = captions ? toSrt(buildCaptionCues(ep.timeline, clips)) : null;
    const stamp = (await sha256Hex(JSON.stringify({ inputs, captions, burn: opts.burn_in }))).slice(0, 12);
    const spec: RenderSpec = {
      episode_id: ep.id,
      inputs,
      output_path: `episodes/${ep.id}/renders/${stamp}.mp4`,
      srt_path: srt ? `episodes/${ep.id}/renders/${stamp}.${ep.render_settings.caption_language}.srt` : null,
      srt,
      captions: { enabled: captions, burn_in: Boolean(opts.burn_in ?? ep.render_settings.burn_in), language: ep.render_settings.caption_language },
      video: { width: 1920, height: 1080, fps: 24 },
      audio: { sample_rate: 48000, loudnorm: true },
    };
    if (srt && this.d.storage.writeText) await this.d.storage.writeText(spec.srt_path!, srt);
    const job = await this.d.store.createRenderJob(ep.id, { spec }, `render:${ep.id}:${stamp}`);
    await this.d.store.saveEpisode(await this.withStatus(ep.id, 'RENDERING'));
    return { job, spec };
  }

  async costSummary(episodeId: string): Promise<CostSummary> {
    return summarizeCosts(await this.d.store.ledger(), episodeId);
  }

  // ================================================================ internals

  private async layerIssues(clip: Clip, series: Awaited<ReturnType<StudioStore['getSeries']>>) {
    return (await Promise.all(this.d.layers.flatMap((l) => l.validators.map((v) => v.validateClip(clip, series))))).flat();
  }

  private async revalidate(clip: Clip, series: Awaited<ReturnType<StudioStore['getSeries']>>, pricingIssues: ValidationIssue[]) {
    const ep = await this.d.store.getEpisode(clip.episode_id);
    const characters = await this.d.store.listCharacters(series.id);
    const all = (await this.d.store.listClips(ep.id)).map((c) => (c.id === clip.id ? clip : c));
    const fidelity = checkDialogueFidelity(parseScript(ep.script, characters), all).filter((i) => i.clip_id === clip.id);
    const kept = clip.issues.filter((i) => i.source === 'planner');
    const fresh = [...kept, ...pricingIssues.map((i) => ({ ...i, clip_id: clip.id })), ...fidelity, ...(await this.layerIssues(clip, series))];
    clip.issues = mergeIssues([], fresh, clip.issues);
  }

  private async refreshPlanHash(ep: Episode) {
    const scenes = await this.d.store.listScenes(ep.id);
    const clips = await this.d.store.listClips(ep.id);
    const e = await this.d.store.getEpisode(ep.id);
    e.plan_hash = await computePlanHash(scenes, clips);
    e.plan_version += 1;
    await this.d.store.saveEpisode(e);
    await this.refreshEpisodeStatus(e);
  }

  private async refreshEpisodeStatus(ep: Episode) {
    const e = await this.d.store.getEpisode(ep.id);
    if (!['DRAFT', 'ANALYZED', 'CONTENT_CONFLICT', 'APPROVED'].includes(e.status)) return;
    const clips = await this.d.store.listClips(e.id);
    const conflict = clips.some((c) => c.issues.some((i) => i.severity === 'conflict'));
    e.status = conflict ? 'CONTENT_CONFLICT' : e.approval && e.approval.plan_hash === e.plan_hash ? 'APPROVED' : 'ANALYZED';
    await this.d.store.saveEpisode(e);
  }

  private async withStatus(id: string, status: Episode['status']): Promise<Episode> {
    const e = await this.d.store.getEpisode(id);
    e.status = status;
    return e;
  }
}

/** Keeps acknowledgements across re-validation (same issue → same key). */
function mergeIssues(base: ValidationIssue[], add: ValidationIssue[], previous: ValidationIssue[] = base): ValidationIssue[] {
  const acked = new Map(previous.filter((i) => i.acknowledged).map((i) => [issueKey(i), i]));
  const out = new Map<string, ValidationIssue>();
  for (const i of [...base, ...add]) {
    const prev = acked.get(issueKey(i));
    out.set(issueKey(i), prev && i.severity === 'review' ? { ...i, acknowledged: true, acknowledged_by: prev.acknowledged_by } : i);
  }
  return [...out.values()];
}
