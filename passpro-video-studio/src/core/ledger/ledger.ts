// Append-only cost ledger + summaries (dashboard numbers).
// committed = reservations − releases + actuals. Authorizations are caps.

import type { LedgerCategory, LedgerEntry } from '../types.ts';
import { roundUsd } from '../util.ts';

const SPEND_SIGN: Record<string, number> = { reservation: 1, release: -1, actual: 1 };

export function committedUsd(
  entries: LedgerEntry[],
  episodeId: string | null,
  categories?: LedgerCategory[],
): number {
  let sum = 0;
  for (const e of entries) {
    if (episodeId && e.episode_id !== episodeId) continue;
    if (categories && !categories.includes(e.category)) continue;
    if (e.category === 'retry_budget') continue;
    sum += (SPEND_SIGN[e.entry_type] ?? 0) * e.amount_usd;
  }
  return roundUsd(sum);
}

export function dayKey(iso: string | Date, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(
    typeof iso === 'string' ? new Date(iso) : iso,
  );
}

export function committedTodayUsd(entries: LedgerEntry[], now: Date, timeZone: string): number {
  const today = dayKey(now, timeZone);
  return committedUsd(entries.filter((e) => dayKey(e.created_at, timeZone) === today), null);
}

export function authorizedUsd(entries: LedgerEntry[], episodeId: string, category: LedgerCategory, clipId?: string): number {
  return roundUsd(
    entries
      .filter((e) => e.episode_id === episodeId && e.entry_type === 'authorization' && e.category === category && (!clipId || e.clip_id === clipId))
      .reduce((s, e) => s + e.amount_usd, 0),
  );
}

export class CostLedger {
  private rows: LedgerEntry[] = [];
  private seq = 0;
  private clock: () => Date;

  constructor(clock: () => Date = () => new Date()) {
    this.clock = clock;
  }

  append(e: Omit<LedgerEntry, 'id' | 'created_at' | 'metadata' | 'scene_id' | 'clip_id' | 'job_id' | 'provider' | 'simulated' | 'created_by'> & Partial<LedgerEntry>): LedgerEntry {
    if (!(e.amount_usd >= 0)) throw new Error('ledger amounts must be >= 0');
    this.seq += 1;
    const row: LedgerEntry = Object.freeze({
      scene_id: null,
      clip_id: null,
      job_id: null,
      provider: null,
      simulated: false,
      metadata: {},
      created_by: null,
      ...e,
      id: this.seq,
      created_at: this.clock().toISOString(),
      amount_usd: roundUsd(e.amount_usd),
    }) as LedgerEntry;
    this.rows.push(row);
    return row;
  }

  all(): readonly LedgerEntry[] {
    return this.rows;
  }

  /** Rehydrate from persisted rows (restart / refresh). */
  static fromRows(rows: LedgerEntry[], clock?: () => Date): CostLedger {
    const l = new CostLedger(clock);
    for (const r of rows) l.rows.push(Object.freeze({ ...r }));
    l.seq = rows.reduce((m, r) => Math.max(m, r.id), 0);
    return l;
  }
}

export interface CostSummary {
  episode_id: string;
  simulated: boolean;
  initial_generation_usd: number;
  regenerations_usd: number;
  voice_usd: number;
  planner_usd: number;
  render_usd: number;
  total_actual_usd: number;
  open_reservations_usd: number;
  authorized_usd: number;
  retry_budget_authorized_usd: number;
  by_scene: Record<string, number>;
  by_clip: Record<string, number>;
  by_provider: Record<string, number>;
}

export function summarizeCosts(entries: readonly LedgerEntry[], episodeId: string): CostSummary {
  const rows = entries.filter((e) => e.episode_id === episodeId);
  const actual = rows.filter((e) => e.entry_type === 'actual');
  const sumBy = (xs: LedgerEntry[], key: (e: LedgerEntry) => string | null) => {
    const out: Record<string, number> = {};
    for (const e of xs) {
      const k = key(e) ?? '(none)';
      out[k] = roundUsd((out[k] ?? 0) + e.amount_usd);
    }
    return out;
  };
  const cat = (c: LedgerCategory) => roundUsd(actual.filter((e) => e.category === c).reduce((s, e) => s + e.amount_usd, 0));
  const open = rows.reduce((s, e) => s + (e.entry_type === 'reservation' ? e.amount_usd : e.entry_type === 'release' ? -e.amount_usd : 0), 0);
  return {
    episode_id: episodeId,
    simulated: rows.some((e) => e.simulated),
    initial_generation_usd: cat('initial'),
    regenerations_usd: cat('regeneration'),
    voice_usd: cat('voice'),
    planner_usd: cat('planner'),
    render_usd: cat('render'),
    total_actual_usd: roundUsd(actual.reduce((s, e) => s + e.amount_usd, 0)),
    open_reservations_usd: roundUsd(open),
    authorized_usd: roundUsd(rows.filter((e) => e.entry_type === 'authorization' && e.category === 'initial').reduce((s, e) => s + e.amount_usd, 0)),
    retry_budget_authorized_usd: roundUsd(rows.filter((e) => e.entry_type === 'authorization' && e.category !== 'initial').reduce((s, e) => s + e.amount_usd, 0)),
    by_scene: sumBy(actual, (e) => e.scene_id),
    by_clip: sumBy(actual, (e) => e.clip_id),
    by_provider: sumBy(actual, (e) => e.provider),
  };
}

/** Plain-text dashboard block, e.g. for logs and the demo. */
export function formatCostSummary(s: CostSummary, title: string): string {
  const f = (n: number) => `$${n.toFixed(2)}`.padStart(10);
  const lines = [
    `${title}${s.simulated ? '   (SIMULATED — mock provider, no money spent)' : ''}`,
    `Initial generation ${f(s.initial_generation_usd)}`,
    `Regenerations      ${f(s.regenerations_usd)}`,
    `Voice              ${f(s.voice_usd)}`,
    `-----------------------------`,
    `TOTAL              ${f(s.total_actual_usd)}`,
  ];
  if (s.open_reservations_usd > 0) lines.push(`(open reservations ${f(s.open_reservations_usd)})`);
  return lines.join('\n');
}
