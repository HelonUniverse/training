// Mirrors the default vs_settings.provider_pricing rows.
import type { PriceRow } from '../src/core/pricing.ts';

export function fixturePricing(): PriceRow[] {
  return [
    { provider: 'mock', model: 'mock-video-1', resolution: '*', unit: 'per_output_second', price_usd: 0.1, verified: true, simulated: true },
    { provider: 'minimax', model: 'MiniMax-H3', resolution: '2K', unit: 'per_output_second', price_usd: null, verified: false,
      source_url: 'https://platform.minimax.io/docs/guides/pricing-paygo' },
  ];
}
