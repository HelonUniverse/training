# PassPro™ Video Studio: MVP v0.1 implementation plan

Status: **Approved in principle (2026-09-29) with changes; backend core built mock-first.**

> **Decisions recorded 2026-09-29** (these supersede the matching parts below):
> - The frontend was not found (see `INTEGRATION-BOUNDARY.md`). UI work is stopped and no second app was created.
> - The minimal schema has 9 tables + `vs_settings` (see `SCHEMA.md`). It is **not applied** to the live DB.
> - Render worker: **Railway**. It never holds MiniMax, Anthropic or ElevenLabs keys.
> - Voices: MiniMax **native** Spanish dialogue first. VoiceProvider is an interface; ElevenLabs is the fallback only.
> - Master images (Doña Póliza, El Sobrino, Kevin) will be uploaded later through the asset system. Nothing is recreated.
> - Limits: $3/clip, $30/episode, $40/day, $5 retry per episode (configurable). `VIDEO_PROVIDER_MODE=mock` is the default.
> - Locked: 85 scored, 10 pretest, 120 minutes. **70% stays UNVERIFIED.**
> - No MiniMax call and no paid request until pricing, resolution, model id and parameters are independently confirmed.
Date: 2026-09-29
Companion doc: [`video-provider-minimax.md`](./video-provider-minimax.md)

---

## A. What was inspected

| Place | What is there |
|---|---|
| GitHub `HelonUniverse/training` (this repo) | Static HTML training courses, plus `desde-la-red/`, an Expo/React Native + Supabase app. **No PassPro code.** |
| All other GitHub repos this session can reach | None is PassPro. |
| Supabase project **`passpro`** (`lhsbaiiympnlmwsfytus`, us-east-1, Postgres 17) | This is the live PassPro backend (read-only inspection only). |
| Vercel | No project matching "pass". |
| Cloudflare Workers | PEAK/Presenza and other workers; nothing PassPro. |

**Key finding: PassPro's backend exists, but its frontend source code was not
found in any repository available to this session.** This is blocking question #1
at the end of this document.

## B. Current stack (from the `passpro` Supabase project)

- **Auth:** Supabase Auth. `public.profiles` has `role ∈ {learner, coach, admin}`,
  `preferred_lang ∈ {es, en}`, and a `handle_new_user` trigger.
- **Database:** Postgres 17, with RLS enabled on every table.
  - Existing helpers: `is_admin()`, `is_coach_of()`, `is_member()`, `set_updated_at()`.
  - Extensions: `pgcrypto`, `uuid-ossp`, `supabase_vault`, `pg_stat_statements`.
- **Content model:**
  - `exams → domains → topics → concepts → questions` (383 questions)
  - `chapters → lessons → videos`
  - `videos.provider` is one of `youtube | vimeo | file | other`
  - `lessons` already has `script_es` / `script_en`
- **Exam facts already stored:** `exams` has FL-2-14 with `scored_questions = 85`,
  `pretest_questions = 10`, `time_minutes = 120` and `pass_score = 70`.
  `exam_blueprints` cites the source "Pearson VUE FL Life & Annuity (incl. Variable
  Contracts) 0214 content outline, 2026".
- **AI logging:** the `ai_generation_logs` table exists (empty).
- **Storage:** no buckets yet.
- **Edge Functions:** none deployed yet.
- **Sister-app pattern** (`desde-la-red/supabase/functions/generate-teaching`): a
  Deno Edge Function calls Claude server-side, checks `is_admin()` using the
  caller's JWT, and returns a draft for human review. This is exactly the
  "AI drafts, human approves" pattern the Video Studio needs.

## C. Reusable components

| Reuse | How |
|---|---|
| Supabase Auth + `profiles.role` + `is_admin()` | Studio is admin-only (a new `producer` role can come later) |
| Postgres + RLS conventions | New `vs_*` tables in the same project, admin-only policies |
| `exams` / `exam_blueprints` | **Seed and back the Content Lock.** Locked facts reference `exams.id`, so "85 scored questions" comes from the same row the quiz engine uses. |
| `lessons.script_es` + `videos` | A finished episode is published as a `videos` row (`provider = 'file'`) linked to a lesson. Learners see it through the existing path. |
| `ai_generation_logs` | Log every planner / Claude call |
| Edge Function + Claude pattern from `desde-la-red` | Script analysis / production planner |
| Supabase Vault / function secrets | Store the MiniMax, voice and Anthropic keys server-side |
| PassPro frontend design system | **Unknown until we find the repo** |

## D. MiniMax research summary

Full detail is in `video-provider-minimax.md`.

- **First adapter: `MiniMax-H3` on `POST /v2/video_generation`.**
  - 4–15 s clips.
  - Up to 9 reference images plus up to 3 reference audios.
  - Native Spanish dialogue with lip sync.
  - Async `task_id`, polled with `GET /v2/query/video_generation/{id}` or pushed to a `callback_url`.
  - The MP4 URL is in `task.content.url`.
- **Unconfirmed:**
  - Pricing: third-party sources say ~$0.13/s at 2K.
  - Rate limits.
  - Whether 768P is still offered: the official CLI says 2K only.
- **Must be confirmed by a human on platform.minimax.io before the first paid call.**
  The research sandbox could not open those pages.
- **Billing rule:** every submission is billed. A `task_id`, once returned, is never re-submitted automatically.

## E. Proposed architecture

```
 ┌──────────── PassPro web frontend (existing repo — TBD) ─────────────┐
 │  /studio  Series & Bible · Episodes · Plan review · Clip library ·   │
 │           Timeline · Costs · Settings (budgets)                      │
 └───────────────▲──────────────────────────┬──────────────────────────┘
                 │ supabase-js (user JWT)   │ realtime subscriptions on vs_* rows
                 │                          │ (UI state comes from DB → survives refresh)
 ┌───────────────┴──────────────────────────▼──────────────────────────┐
 │ Supabase project "passpro"                                           │
 │  Postgres: vs_* tables + RLS (is_admin)                              │
 │  Storage: private bucket "video-studio" (refs, clips, audio, renders)│
 │  Edge Functions (Deno, all admin-checked, all keys server-side):     │
 │   vs-analyze-script   Claude → scenes/clips JSON (NO provider calls) │
 │   vs-check-content    locked-fact conflict scan                      │
 │   vs-estimate         pure cost math from vs_provider_pricing        │
 │   vs-approve          records approval + authorized budget cap       │
 │   vs-submit-jobs      budget gate → PromptCompiler → VideoProvider   │
 │   vs-provider-callback MiniMax webhook (challenge echo + status)     │
 │   vs-poll-jobs        cron (pg_cron + pg_net, every 1 min) safety net│
 │   vs-voice            VoiceProvider (master voice samples, TTS)      │
 │   vs-request-render   enqueues a render job                          │
 └───────────────┬──────────────────────────────────────────────────────┘
                 │ polls vs_render_jobs (service key, server-side only)
 ┌───────────────▼──────────────────────────────────────────────────────┐
 │ Render worker — small Node + FFmpeg container (Fly.io / Render /    │
 │ Railway / Cloudflare Containers). Normalizes, concatenates, loudnorm,│
 │ burns/attaches captions, uploads final MP4. Never calls AI APIs.     │
 └──────────────────────────────────────────────────────────────────────┘
```

**Why a separate render worker:** Supabase Edge Functions cannot run the FFmpeg
binary and have short CPU and wall-clock limits. The worker is the only new piece
of infrastructure. It has no AI-provider keys, so it physically cannot spend money
on generation.

### Code modules (server-side TypeScript, shared by the Edge Functions)

```
video-studio/
  providers/video/VideoProvider.ts     interface
  providers/video/minimax-h3.ts        first adapter
  providers/video/mock.ts              free fake provider (dev + tests + dry runs)
  providers/voice/VoiceProvider.ts     interface
  providers/voice/minimax-speech.ts | elevenlabs.ts
  planner/analyzeScript.ts             Claude, structured JSON, validated
  compiler/PromptCompiler.ts           series+character+location+clip → provider prompt
  contentlock/checkContent.ts          number/term extraction vs vs_locked_facts
  budget/BudgetGuard.ts                per-clip / per-episode / daily checks
  captions/srt.ts                      SRT from canonical dialogue + clip offsets
  render/ (worker)                     ffmpeg pipeline
```

### VideoProvider interface

```ts
interface VideoProvider {
  id: string;                                   // 'minimax-h3'
  capabilities(): { minDuration; maxDuration; resolutions; maxRefImages;
                    supportsImageReference; supportsAudioReference;
                    supportsCharacterReference; supportsNativeAudio;
                    supportsFirstFrame; canMixFramesAndRefs };
  estimateCost(req: CompiledClipRequest, pricing: PriceRow): Money;
  generateClip(req: CompiledClipRequest, opts: { callbackUrl?; idempotencyKey })
      : Promise<{ providerJobId: string }>;
  getJobStatus(providerJobId): Promise<{ status: JobStatus; error?; usage? }>;
  getResult(providerJobId): Promise<{ videoUrl: string; usage; raw }>;
  parseCallback(req: Request): CallbackResult;  // incl. challenge echo
}
```

`CompiledClipRequest` is provider-neutral: the prompt sections, reference asset
URLs by role, duration, resolution and ratio. Each adapter maps it to its own wire
format. The episode and clip models never change when a new provider (Runway,
Kling, Veo, Seedance) is added.

### Hard spending protection (enforced server-side, not just in the UI)

1. **Analysis never spends provider money.**
   - `vs-analyze-script` has no video or voice keys.
   - It only calls Claude. The Claude cost is logged, and it is cents.
2. **Approval is a database record, not a click.**
   - `vs_approvals` stores who approved and when.
   - It also stores the plan hash and the **authorized maximum**, which covers the estimate plus the retry budget.
3. **`vs-submit-jobs` checks, inside one DB transaction, before every provider call:**
   - The clip is `APPROVED`.
   - Its plan hash matches the approved hash, so an edit after approval voids that approval.
   - No open `CONTENT_CONFLICT` exists.
   - The clip estimate is ≤ the per-clip max.
   - Episode spend plus open commitments are ≤ the authorized max and ≤ the per-episode max.
   - Today's spend plus open commitments are ≤ the daily max.
   - It then writes a **ledger reservation** before calling the provider.
4. **No automatic paid retries.**
   - A failed clip becomes `FAILED`.
   - Regenerating it needs a new approval, or draws from an explicitly pre-authorized retry budget.
   - Status polls are retried; submissions are not.
5. **A kill switch** (`vs_settings.generation_enabled`) stops all submission.

### Voice consistency: the biggest creative/technical decision

H3 generates dialogue audio itself and can take **reference audio for voice
timbre**. The plan:

1. **Master voices, created once per character through `VoiceProvider`:**
   - Pick a MiniMax system voice, a designed voice, or an ElevenLabs voice for each character.
   - Save a 6–10 s **master voice sample** as a character asset.
2. **Default mode ("native"):**
   - Each clip sends the speaking characters' master samples as `reference_audio`.
   - The dialogue goes in the prompt.
   - H3 produces lip-synced speech in that timbre.
3. **Fallback mode ("dub"):** if the voices drift between clips anyway:
   - Generate each line with TTS using the persistent `voice_id`.
   - Tell H3 to keep ambience only.
   - Overlay the TTS audio in the render step.
   - Cost: lip sync becomes approximate.
4. **Choice level:** the mode is stored per clip, so it is a per-clip decision.

The acceptance test will tell us which mode is good enough.

### Captions

- Dialogue lives in `vs_dialogue_lines`, which is canonical and approved.
- SRT timings come from the clip start offsets on the timeline plus each line's
  estimated in-clip timing. The TTS audio length is used in dub mode.
- Spanish is the only caption language in the MVP. Captions can be switched on or
  off, and exported as SRT.

## F. Proposed database changes

These are new tables only; **no existing PassPro table is altered**. The only
exception is optional: one row is inserted into `videos` when an episode is
published. Everything is `vs_`-prefixed, and every table is admin-only under RLS
via `is_admin()`. The worker uses the service key server-side.

| Table | Key columns |
|---|---|
| `vs_series` | id, name, visual_style, language, target_audience, generation_rules jsonb, continuity_rules jsonb, default_provider, default_resolution, default_ratio |
| `vs_assets` | id, series_id, kind (`character`/`location`/`prop`/`voice_sample`/`style_ref`), slug (e.g. `dona_poliza`), name, description, visual_prompt, negative_prompt, continuity_notes, data jsonb (kind-specific) |
| `vs_characters` | asset_id PK → vs_assets, age, wardrobe, personality, catchphrases[], rules[] (e.g. the self-correcting English joke), voice_only bool, voice_provider, voice_id, voice_settings jsonb, master_image_path, master_voice_sample_path |
| `vs_asset_images` | id, asset_id, storage_path, role (`master`/`turnaround`/`expression`/`pose`), is_primary, width, height |
| `vs_locked_facts` | id, series_id null, exam_id → exams, concept, statement, value_numeric, unit, source, verified_date, verified_by, status (`verified`/`draft`/`retired`) |
| `vs_episodes` | id, series_id, number, title, language, target_duration_s, script, script_hash, status, plan_version, captions_enabled, created_by |
| `vs_scenes` | id, episode_id, order, heading, location_asset_id, summary |
| `vs_clips` | id, scene_id, episode_id, order, duration_estimate_s, location_asset_id, action, camera_direction, visual_prompt, audio_requirements jsonb, audio_mode (`native`/`dub`), continuity_from_previous, continuity_into_next, estimated_cost, status (PLANNED/APPROVED/GENERATING/COMPLETE/FAILED/NEEDS_REVIEW/LOCKED), selected_version_id, plan_hash |
| `vs_clip_characters` | clip_id, asset_id |
| `vs_clip_reference_assets` | clip_id, asset_id, asset_image_id, role (`reference_image`/`reference_audio`/`first_frame`) |
| `vs_dialogue_lines` | id, clip_id, order, character_asset_id, text, emotion, est_start_s, est_end_s, tts_audio_path |
| `vs_content_conflicts` | id, episode_id, clip_id, locked_fact_id, found_text, expected, severity, status (`open`/`accepted_by_reviewer`/`fixed`), resolved_by, resolved_at |
| `vs_approvals` | id, episode_id, scope (`episode`/`clip`/`retry`), clip_ids[], plan_hash, estimated_total, authorized_max, approved_by, approved_at, revoked_at |
| `vs_generation_jobs` | id, clip_id, provider, provider_job_id, status, submitted_at, completed_at, cost_estimate, actual_cost, usage jsonb, error, output_url, approval_id, compiled_prompt, request jsonb |
| `vs_clip_versions` | id, clip_id, version_no, job_id, provider, prompt, reference_asset_ids[], settings jsonb, cost, storage_path, duration_s, created_at, deleted_at (soft delete; never overwritten) |
| `vs_timeline_items` | id, episode_id, order, clip_id, clip_version_id, transition_in, enabled |
| `vs_render_jobs` | id, episode_id, timeline_snapshot jsonb, options jsonb (captions, loudnorm), status, output_path, srt_path, error, started_at, finished_at |
| `vs_cost_ledger` | id, episode_id, scene_id, clip_id, job_id, category (`initial`/`regeneration`/`voice`/`planner`/`render`), provider, kind (`reservation`/`actual`/`release`), amount_usd, created_at |
| `vs_provider_pricing` | provider, model, resolution, unit (`per_output_second`/`per_image`/`per_1k_chars`), price_usd, verified bool, source_url, effective_from |
| `vs_settings` | singleton: max_cost_per_clip, max_cost_per_episode, max_daily_spend, retry_budget_default, generation_enabled, max_concurrent_jobs |

The **cost dashboard** is a SQL view over `vs_cost_ledger`. It breaks down by
episode, scene, clip, provider and category.

**Storage:** create a private bucket `video-studio/` with these paths:

- `refs/{asset_id}/…`
- `voices/{asset_id}/…`
- `clips/{clip_id}/v{n}.mp4`
- `renders/{episode_id}/{render_id}.mp4|.srt`

The UI plays files through short-lived signed URLs.

## G. Environment variables

### Edge Function secrets (server-only; set with `supabase secrets set`)

```
MINIMAX_API_KEY=            # pay-as-you-go key (sk-api-…); Token Plan keys are rejected for H3
MINIMAX_API_BASE=https://api.minimax.io
MINIMAX_VIDEO_MODEL=MiniMax-H3
MINIMAX_CALLBACK_SECRET=    # random; embedded in callback URL path/query to authenticate webhooks
ANTHROPIC_API_KEY=          # production planner
PLANNER_MODEL=              # Claude model id for script analysis
VOICE_PROVIDER=minimax      # or elevenlabs
ELEVENLABS_API_KEY=         # only if VOICE_PROVIDER=elevenlabs
VIDEO_STUDIO_BUCKET=video-studio
VIDEO_PROVIDER_MODE=mock    # mock | live — live requires explicit switch
```

Supabase injects `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY` into functions automatically.

### Render worker (server-only)

```
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
VIDEO_STUDIO_BUCKET=video-studio
RENDER_POLL_INTERVAL_MS=5000
```

### Frontend

```
SUPABASE_URL / SUPABASE_ANON_KEY  (already exist in PassPro; publishable only)
```

No provider key is ever given a `NEXT_PUBLIC_` / `VITE_` / `EXPO_PUBLIC_` prefix.
A committed `.env.example` lists names only.

## H. Milestones

| # | Milestone | Spends provider money? | Demo at end |
|---|---|---|---|
| **M0** | Confirm open decisions (§K). Human verifies MiniMax pricing and resolution on the official pages. Receive the Video 0 script. | No | Signed-off plan |
| **M1** | Schema migration + storage bucket + RLS. Seed the series, 3 characters, the Casa location, 6 props and the locked facts (from `exams`). Settings with conservative budgets. | No | Tables visible, seed data correct |
| **M2** | Studio shell in the PassPro frontend: Series Bible and Character Bible screens (view/edit, upload reference images), plus a New Episode form | No | Acceptance steps 1–4 |
| **M3** | Planner (`vs-analyze-script`) → scenes/clips. Content Lock scan with the ⚠ CONTENT CONFLICT flow. Cost estimate. Plan review UI with EDIT/APPROVE per clip and an episode total. | No (Claude only, ~cents) | Steps 5–8 |
| **M4** | VideoProvider interface, **mock provider**, PromptCompiler, BudgetGuard, approvals, generation jobs, callback + cron poller, realtime UI. Full flow against the mock. | No | Steps 9–13 end-to-end **for free** |
| **M5** | MiniMax-H3 adapter. **One paid single-clip smoke test** with a hard cap (e.g. $3), to measure real cost, latency, audio and voice consistency. | **Yes, ~1 clip** | Real clip in the library |
| **M6** | Master assets: finalize character reference images and master voice samples through VoiceProvider. Decide native vs dub audio from the M5 result. | Small (voice) | Locked character pack |
| **M7** | Clip library (versions ★, play, select, regenerate one, soft-delete) and timeline (reorder, replace, remove, play-all preview) | No | Steps 11–14 (on mock + M5 clip) |
| **M8** | Render worker: FFmpeg normalize (1080p/24fps/AAC 48k), concat, loudnorm, optional transitions, captions (burn-in or soft sub), SRT export, then publish to `videos` | No | Step 15 |
| **M9** | Cost dashboard (episode / scene / clip / provider / regeneration / voice / total) | No | Step 16 |
| **M10** | **Acceptance run: Video 0 for real**, under an approved episode cap | **Yes, ~$15–25 est.** | All 16 steps |

## I. Technical risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | **PassPro frontend repo not found.** The UI cannot be integrated without it. | Blocking question #1 |
| 2 | **Pricing, resolution and rate limits unconfirmed.** 2K-only would make Video 0 ~$16+ per pass. | Price table is `verified=false` until confirmed; the estimate shows "unverified"; M5 measures real `usage` |
| 3 | **Character consistency across 13 clips.** H3 can take reference images **or** first/last frames, not both. Chaining from the last frame loses the identity refs. | Default to reference-image mode (identity > seamless cuts); design scene cuts at clip boundaries; allow per-clip first-frame mode for continuous shots; strong master reference sheets (M6) |
| 4 | **Voice drift.** H3 native dialogue may vary per clip even with reference audio. | Master voice samples as `reference_audio`; per-clip dub mode fallback; decide from M5 |
| 5 | **Spanish dialogue accuracy and lip sync.** The model may paraphrase lines, and Puerto Rican accent fidelity is uncertain. | Captions come from the canonical script, not ASR. The NEEDS_REVIEW status lets a human reject a clip. Dub mode guarantees exact words. |
| 6 | **On-screen text / numbers invented by the model**, e.g. a wrong "85" on a sign | DO-NOT section in every prompt ("no on-screen text"); facts shown via our captions/overlays in render, not by the model |
| 7 | **Content moderation false positives** (1026/1027) | Mapped to NEEDS_REVIEW with the message shown; no auto-retry |
| 8 | **Double billing** from a retried submission after a network timeout | Idempotency key per job row; a job row is written *before* the call; ambiguous submissions go to NEEDS_REVIEW instead of retrying |
| 9 | **Output URL expiry** | Download to our storage in the same step that records `COMPLETE` |
| 10 | **Edge Function time limits** | Submit and poll are short calls; long work lives in the render worker |
| 11 | **Master reference images do not exist yet** | Decision needed: commission art, use the MiniMax image API, or upload existing PassPro art (§K) |
| 12 | **Facts in the planner** — Claude may "improve" numbers | The Content Lock scan runs on planner output *and* on every clip edit; conflicts block approval and are never auto-fixed |

## J. What can be implemented immediately after approval

These need no API keys, no spend, and no further decisions except the frontend location:

- M1 migration SQL + seed (series, characters, location, props, locked facts from `exams`)
- VideoProvider / VoiceProvider interfaces + **mock provider**
- PromptCompiler (+ unit tests with Video 0 fixtures)
- Content Lock checker (+ tests: "90 preguntas" vs locked 85 → conflict)
- BudgetGuard + ledger logic (+ tests)
- SRT generator
- FFmpeg render pipeline, tested locally with synthetic clips
- MiniMax-H3 adapter code, tested against recorded/mock responses — **not called live** until M5 is approved

**Needs your input first:** the frontend UI (M2+ screens), the live MiniMax
smoke test (M5), master art and voices (M6), and render worker hosting (M8).

## K. Decisions / inputs needed from you

1. **Where is the PassPro frontend code?** Give the repo name so it can be added to
   this session. What framework does it use?
2. **The Video 0 script** ("Bienvenidos a la casa de Doña Póliza"). It was
   referenced as "supplied" but was not included in the request.
3. **Can the Studio's tables and bucket go into the live `passpro` Supabase project**
   (recommended)? Or should we use a Supabase branch/dev project first (safer)?
4. **Render worker host:** Fly.io, Render, Railway or Cloudflare Containers? This
   will be the only new service.
5. **Voice provider:** MiniMax speech (one vendor, one bill) or ElevenLabs
   (stronger Spanish voice catalog)?
6. **Character master images:** do they already exist? If not, how should they be made?
7. **Initial budget limits:** e.g. $3 per clip, $30 per episode, $40 per day, with
   a $5 retry budget.
8. **Locked facts for Video 0:** confirm that 85 scored / 10 pretest / 120 min /
   70% pass (already in `exams`, citing Pearson VUE 2026) are the facts to lock.
   Are there more?
