// Chooses the video provider from configuration. Default is the free mock.
// Paid mode requires ALL of:
//   VIDEO_PROVIDER_MODE=live
//   VIDEO_PROVIDER=minimax
//   VIDEO_PAID_GENERATION_CONFIRM=I_UNDERSTAND_THIS_SPENDS_MONEY
//   MINIMAX_API_KEY set
// and, separately, vs_settings.generation.paid_providers_enabled = true in
// the database (enforced by vs_reserve_generation).

import { MockVideoProvider, type MockVideoOptions } from './mock-video-provider.ts';
import { MinimaxH3Provider } from './minimax-h3.ts';
import type { VideoProvider } from './video-provider.ts';
import { StudioError } from '../types.ts';

export const PAID_CONFIRM_PHRASE = 'I_UNDERSTAND_THIS_SPENDS_MONEY';

export function createVideoProvider(
  env: Record<string, string | undefined>,
  deps: { fetch?: typeof fetch; mock?: MockVideoOptions } = {},
): VideoProvider {
  const mode = (env.VIDEO_PROVIDER_MODE ?? 'mock').trim().toLowerCase();
  if (mode === 'mock') return new MockVideoProvider(deps.mock);
  if (mode !== 'live') throw new StudioError('VS_CONFIG', `unknown VIDEO_PROVIDER_MODE "${mode}" (use mock or live)`);

  const provider = (env.VIDEO_PROVIDER ?? '').trim().toLowerCase();
  if (provider !== 'minimax') throw new StudioError('VS_CONFIG', 'live mode requires VIDEO_PROVIDER=minimax');
  if (env.VIDEO_PAID_GENERATION_CONFIRM !== PAID_CONFIRM_PHRASE)
    throw new StudioError('VS_CONFIG', `live mode requires VIDEO_PAID_GENERATION_CONFIRM=${PAID_CONFIRM_PHRASE}`);
  if (!env.MINIMAX_API_KEY) throw new StudioError('VS_CONFIG', 'live mode requires MINIMAX_API_KEY');

  return new MinimaxH3Provider({
    api_key: env.MINIMAX_API_KEY,
    base_url: env.MINIMAX_API_BASE,
    model: env.MINIMAX_VIDEO_MODEL,
    allow_paid_requests: true,
    fetch: deps.fetch,
  });
}
