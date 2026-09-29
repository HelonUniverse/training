// Spending guard. Same rules and error codes as the SQL functions
// vs_approve_episode / vs_reserve_generation (the database is the final
// authority in production; this mirror lets the workflow, the UI and tests
// explain refusals before a round-trip, and powers the in-memory demo).

import type { BudgetSettings, Clip, Episode, GenerationSettings, LedgerEntry } from '../types.ts';
import { StudioError } from '../types.ts';
import { authorizedUsd, committedTodayUsd, committedUsd } from '../ledger/ledger.ts';
import { roundUsd } from '../util.ts';

export const DEFAULT_BUDGET: BudgetSettings = {
  max_cost_per_clip_usd: 3,
  max_cost_per_episode_usd: 30,
  max_daily_spend_usd: 40,
  max_retry_budget_per_episode_usd: 5,
  timezone: 'America/New_York',
};

export const DEFAULT_GENERATION: GenerationSettings = {
  enabled: true,
  paid_providers_enabled: false,
  max_concurrent_jobs: 2,
};

/** Conflicts always block (they can only be fixed, never acknowledged); review items block until acknowledged. */
export function blockingIssues(clips: Clip[]) {
  return clips.flatMap((c) => c.issues.filter((i) => i.severity === 'conflict' || (i.severity === 'review' && !i.acknowledged)));
}

export interface ApprovalCheck {
  episode: Episode;
  clips: Clip[];
  plan_hash: string;
  authorized_max_usd: number;
  retry_budget_usd: number;
  budget: BudgetSettings;
  /** initial-generation spend already committed (re-approval after an edit) */
  committed_initial_usd?: number;
}

/** Returns the estimated total when the approval is allowed; throws otherwise. */
export function checkApproval(a: ApprovalCheck): number {
  if (!a.episode.plan_hash || a.episode.plan_hash !== a.plan_hash)
    throw new StudioError('VS_PLAN_CHANGED', 'the plan changed since it was reviewed; reload and review again');
  const blocking = blockingIssues(a.clips);
  if (blocking.length)
    throw new StudioError('VS_CONTENT_BLOCKED', `${blocking.length} unresolved issue(s) (CONTENT CONFLICT or review) block approval`, blocking);
  if (a.clips.some((c) => c.estimated_cost_usd === null))
    throw new StudioError('VS_NO_ESTIMATE', 'every clip needs a cost estimate from confirmed pricing');
  const estimate = roundUsd(
    (a.committed_initial_usd ?? 0) +
      a.clips.filter((c) => c.status === 'PLANNED' || c.status === 'APPROVED').reduce((s, c) => s + (c.estimated_cost_usd ?? 0), 0),
  );
  if (a.authorized_max_usd < estimate)
    throw new StudioError('VS_BUDGET', `authorized max ${a.authorized_max_usd} is below the estimate ${estimate}`);
  if (a.authorized_max_usd > a.budget.max_cost_per_episode_usd)
    throw new StudioError('VS_BUDGET', `authorized max ${a.authorized_max_usd} exceeds the per-episode limit ${a.budget.max_cost_per_episode_usd}`);
  if (a.retry_budget_usd < 0 || a.retry_budget_usd > a.budget.max_retry_budget_per_episode_usd)
    throw new StudioError('VS_BUDGET', `retry budget ${a.retry_budget_usd} exceeds the limit ${a.budget.max_retry_budget_per_episode_usd}`);
  const over = a.clips.find((c) => (c.estimated_cost_usd ?? 0) > a.budget.max_cost_per_clip_usd);
  if (over) throw new StudioError('VS_BUDGET', `clip ${over.ord} exceeds the per-clip limit ${a.budget.max_cost_per_clip_usd}`);
  return estimate;
}

export interface ReservationCheck {
  episode: Episode;
  clip: Clip;
  estimate_usd: number;
  is_regeneration: boolean;
  simulated: boolean;
  budget: BudgetSettings;
  generation: GenerationSettings;
  ledger: readonly LedgerEntry[];
  now: Date;
}

export function checkReservation(r: ReservationCheck): 'initial' | 'regeneration' {
  const { episode: ep, clip, budget } = r;
  const ledger = [...r.ledger];
  if (!r.generation.enabled) throw new StudioError('VS_DISABLED', 'generation kill switch is off');
  if (!r.simulated && !r.generation.paid_providers_enabled)
    throw new StudioError('VS_PAID_DISABLED', 'paid providers are disabled in settings');
  if (!ep.approval || ep.approval.plan_hash !== ep.plan_hash)
    throw new StudioError('VS_NOT_APPROVED', 'episode plan is not approved (or changed after approval)');
  if (blockingIssues([clip]).length)
    throw new StudioError('VS_CONTENT_BLOCKED', 'clip has an unresolved CONTENT CONFLICT / review issue');
  if (clip.status === 'LOCKED') throw new StudioError('VS_LOCKED', 'clip is locked');
  if (!r.is_regeneration && clip.status !== 'APPROVED') throw new StudioError('VS_NOT_APPROVED', `clip status is ${clip.status}`);
  if (r.is_regeneration && !['COMPLETE', 'FAILED', 'NEEDS_REVIEW'].includes(clip.status))
    throw new StudioError('VS_STATE', `clip in status ${clip.status} cannot be regenerated`);
  if (r.estimate_usd > budget.max_cost_per_clip_usd)
    throw new StudioError('VS_BUDGET_CLIP', `estimate ${r.estimate_usd} exceeds per-clip limit ${budget.max_cost_per_clip_usd}`);

  const regenAuthorized = authorizedUsd(ledger, ep.id, 'regeneration');
  const episodeCap = Math.min(
    ep.approval.authorized_max_usd + ep.approval.retry_budget_usd + regenAuthorized,
    budget.max_cost_per_episode_usd,
  );
  if (committedUsd(ledger, ep.id, ['initial', 'regeneration']) + r.estimate_usd > episodeCap + 1e-9)
    throw new StudioError('VS_BUDGET_EPISODE', 'would exceed the authorized / per-episode maximum');
  if (committedTodayUsd(ledger, r.now, budget.timezone) + r.estimate_usd > budget.max_daily_spend_usd + 1e-9)
    throw new StudioError('VS_BUDGET_DAILY', `would exceed the daily limit ${budget.max_daily_spend_usd}`);

  if (r.is_regeneration) {
    const cap = ep.approval.retry_budget_usd + regenAuthorized;
    const used = committedUsd(ledger, ep.id, ['regeneration']);
    if (used + r.estimate_usd > cap + 1e-9)
      throw new StudioError('VS_NEEDS_AUTHORIZATION', `regeneration needs approval (retry budget ${used} used of ${cap})`, { used, cap });
    return 'regeneration';
  }
  if (committedUsd(ledger, ep.id, ['initial']) + r.estimate_usd > ep.approval.authorized_max_usd + 1e-9)
    throw new StudioError('VS_BUDGET_EPISODE', `would exceed the approved maximum ${ep.approval.authorized_max_usd}`);
  return 'initial';
}
