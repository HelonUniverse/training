# PassPro™ Video Studio: backend core (MVP v0.1)

A reusable video-production engine with a PassPro education layer on top.
**Mock-first:** the whole workflow runs free, and paid generation is off in
three independent places.

```
npm install
npm test            # unit + end-to-end tests (needs ffmpeg/ffprobe on PATH)
npm run test:db     # migrations on a throwaway local Postgres (never Supabase)
npm run typecheck
npm run demo        # full workflow with the mock provider → out/demo/…mp4 + .srt
npm run demo -- --script path/to/video0.txt
```

## Layout

| Path | What |
|---|---|
| `src/core/` | Engine: types, planner (script → scenes → clips), PromptCompiler, VideoProvider / VoiceProvider interfaces, mock + MiniMax-H3 adapters, pricing, BudgetGuard, cost ledger, SRT, workflow service, storage |
| `src/education/` | PassPro layer: content-lock validator, Spanish number parser, fact injection |
| `src/worker/` | FFmpeg render worker (Railway): normalize → concat → loudnorm → captions |
| `supabase/migrations/` | Version-controlled schema (not applied to live) |
| `supabase/seed/` | Idempotent seeds (series bible, Video 0 content locks) |
| `seed/series/*.json` | Single source for the series bible (`npm run seed:sql` regenerates SQL) |
| `docs/` | Plan, schema, integration boundary, MiniMax research |

## Safety switches (all must be on to spend money)

1. `VIDEO_PROVIDER_MODE=live`, which defaults to `mock`.
2. `VIDEO_PAID_GENERATION_CONFIRM=I_UNDERSTAND_THIS_SPENDS_MONEY` plus a `MINIMAX_API_KEY`.
3. The database setting `vs_settings.generation.paid_providers_enabled = true`, which defaults to false.

Two more things must also hold:

- **Confirmed pricing.** The MiniMax price is `null` until confirmed, so no estimate exists and approval is impossible.
- **A human approval** bound to the exact plan hash, within the per-clip, per-episode, daily and retry limits.

## Render worker (Railway)

- Configured by `railway.json` and `worker/Dockerfile`.
- Environment: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `VIDEO_STUDIO_BUCKET`.
- It refuses to start if `MINIMAX_API_KEY`, `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY` or `OPENAI_API_KEY` is present.
- Not deployed yet.
