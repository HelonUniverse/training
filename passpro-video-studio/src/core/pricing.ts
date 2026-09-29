// Cost estimation from CONFIGURABLE price data (vs_settings.provider_pricing).
// No price is hard-coded in code. A missing or null price means "unknown":
// the clip gets no estimate and approval is blocked.

import type { ValidationIssue } from './types.ts';
import { roundUsd } from './util.ts';

export interface PriceRow {
  provider: string;
  model: string;
  /** '*' matches any resolution */
  resolution: string;
  unit: 'per_output_second' | 'per_request' | 'per_input_image';
  price_usd: number | null;
  verified: boolean;
  simulated?: boolean;
  /** units included free per request (e.g. first N reference images) */
  free_units?: number;
  source_url?: string | null;
  notes?: string;
}

export interface CostEstimate {
  amount_usd: number | null;
  verified: boolean;
  simulated: boolean;
  lines: { unit: string; quantity: number; price_usd: number | null; subtotal_usd: number | null }[];
  issues: ValidationIssue[];
}

export function estimateClipCost(
  pricing: PriceRow[],
  q: { provider: string; model: string; resolution: string; duration_s: number; reference_image_count: number },
): CostEstimate {
  const rows = pricing.filter(
    (r) => r.provider === q.provider && r.model === q.model && (r.resolution === '*' || r.resolution === q.resolution),
  );
  const issues: ValidationIssue[] = [];
  if (!rows.some((r) => r.unit === 'per_output_second' || r.unit === 'per_request')) {
    issues.push({
      code: 'NO_PRICING',
      severity: 'review',
      source: 'pricing',
      message: `No price configured for ${q.provider}/${q.model}@${q.resolution}. Add it to vs_settings.provider_pricing.`,
    });
    return { amount_usd: null, verified: false, simulated: false, lines: [], issues };
  }

  const lines: CostEstimate['lines'] = [];
  let total = 0;
  let unknown = false;
  for (const r of rows) {
    const qty =
      r.unit === 'per_output_second' ? q.duration_s
      : r.unit === 'per_request' ? 1
      : Math.max(0, q.reference_image_count - (r.free_units ?? 0));
    if (r.price_usd === null || r.price_usd === undefined) {
      unknown = true;
      lines.push({ unit: r.unit, quantity: qty, price_usd: null, subtotal_usd: null });
      continue;
    }
    const sub = qty * r.price_usd;
    total += sub;
    lines.push({ unit: r.unit, quantity: qty, price_usd: r.price_usd, subtotal_usd: roundUsd(sub) });
  }
  const verified = rows.every((r) => r.verified);
  const simulated = rows.some((r) => r.simulated);
  if (unknown) {
    issues.push({
      code: 'PRICING_UNCONFIRMED',
      severity: 'review',
      source: 'pricing',
      message: `Price for ${q.provider}/${q.model} is not confirmed. Confirm it on the official pricing page before estimating.`,
    });
    return { amount_usd: null, verified: false, simulated, lines, issues };
  }
  if (!verified) {
    issues.push({
      code: 'PRICING_UNVERIFIED',
      severity: 'review',
      source: 'pricing',
      message: `Price for ${q.provider}/${q.model} is marked unverified.`,
    });
  }
  return { amount_usd: roundUsd(total), verified, simulated, lines, issues };
}
