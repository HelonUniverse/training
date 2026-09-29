# Video Studio schema (revised, minimal) — FOR REVIEW, NOT APPLIED

Status: written as version-controlled migrations and tested only on a
throwaway local Postgres. **Nothing has been applied to the live `passpro`
Supabase project.**

| File | Purpose |
|---|---|
| `supabase/migrations/20260929120000_vs_core.sql` | Core engine (subject-independent) |
| `supabase/migrations/20260929120100_vs_education_content_locks.sql` | PassPro education layer |
| `supabase/seed/10_series_en-la-casa-de-dona-poliza.sql` | Series + 3 characters + location + 6 props (generated from `seed/series/*.json`) |
| `supabase/seed/20_content_locks_fl_214.sql` | Video 0 content locks, values copied from `public.exams` |
| `supabase/tests/` | Stub PassPro baseline + assertions (`npm run test:db`) |

## Tables: 9 you asked for + 1

| Table | Why it exists | JSONB used for |
|---|---|---|
| `vs_series` | Series bible | `bible`: generation / continuity rules, negative prompt, default provider/model/resolution/ratio, `content_lock_scopes` (layer hook) |
| `vs_characters` | Persistent characters; never regenerated per episode | `voice` {provider, voice_id, settings, description, master_sample_asset_id} |
| `vs_assets` | Reusable locations, props, reference images, voice samples (files in Storage) | `metadata` |
| `vs_episodes` | Script, plan hash, approval, timeline, render settings | `analysis`, `approval`, `timeline`, `render_settings` |
| `vs_scenes` | Scene list | — |
| `vs_clips` | Clips | `dialogue`, `continuity`, `audio_requirements`, `issues` (validation), **`versions`** (clip library, never overwritten) |
| `vs_content_locks` | Education layer: verified facts | `match_rules` (detection patterns) |
| `vs_generation_jobs` | Async jobs: clip, voice, **render** (one table, `job_type`) | `request` (compiled prompt, settings, render spec), `usage`, `error` |
| `vs_cost_ledger` | Append-only money log; authorizations and approvals history | `metadata` |
| **`vs_settings`** (+1) | Key → JSONB: `budget` limits, `provider_pricing` table, `generation` kill switch / paid switch / concurrency | `value` |

**Why `vs_settings`:** you asked that limits be configurable and that pricing
live in configurable data rather than code. Both are global (the daily limit
spans every episode), so they don't fit on a series or an episode row. One
tiny key/value table covers both, and a price change never needs a deploy.

**What was folded into JSONB instead of separate tables:**

- clip versions → `vs_clips.versions`
- dialogue → `vs_clips.dialogue`
- timeline → `vs_episodes.timeline`
- approvals → `vs_episodes.approval` + ledger `authorization` rows
- content conflicts → `vs_clips.issues`
- render jobs → `vs_generation_jobs` with `job_type = 'render'`

Any of these can be promoted to its own table later through a migration.

## Default settings (development safety)

```
budget:     max_cost_per_clip_usd 3 · max_cost_per_episode_usd 30 ·
            max_daily_spend_usd 40 · max_retry_budget_per_episode_usd 5 ·
            timezone America/New_York
generation: enabled true · paid_providers_enabled FALSE · max_concurrent_jobs 2
pricing:    mock/mock-video-1 $0.10/s (simulated)
            minimax/MiniMax-H3/2K  price NULL, verified false  ← must be confirmed
```

## Content locks seeded for Video 0 (scope `FL-2-14`)

The values are copied at seed time **from the existing `public.exams` row**.
Nothing is typed in by hand.

| concept | value | status |
|---|---|---|
| `exam.scored_questions` | 85 questions | VERIFIED |
| `exam.pretest_questions` | 10 questions | VERIFIED |
| `exam.time_limit_minutes` | 120 minutes | VERIFIED |
| `exam.passing_score_percent` | 70 percent | **UNVERIFIED** (awaiting official confirmation) |

Each lock stores:

- value and unit
- jurisdiction
- effective date and verified date
- verified by
- source name, source URL, source reference
- verification status: UNVERIFIED, VERIFIED, STALE or CONFLICT

A check constraint rejects `VERIFIED` without a source name, a verified date
and a verifier.

⚠ **`source_url` is NULL for all four.** The blueprint row names the Pearson
VUE 2026 content outline but stores no link. Please send the official URL(s)
so they can be recorded.

## Money functions: the database is the final guard

| Function | Who can call | What it does |
|---|---|---|
| `vs_approve_episode(episode, plan_hash, authorized_max, retry_budget)` | **authenticated admin** (a real person; records `auth.uid()`) | Refuses if:<ul><li>the plan hash is stale</li><li>any CONTENT CONFLICT exists</li><li>any review item is unacknowledged</li><li>any estimate is missing</li><li>a per-clip or per-episode limit is exceeded</li><li>the retry budget exceeds its cap</li></ul>Otherwise writes ledger `authorization` rows and approves the PLANNED clips. |
| `vs_authorize_regeneration(clip, max)` | authenticated admin | Explicit money for ONE clip's regeneration, at most the per-clip limit |
| `vs_reserve_generation(…)` | **server only** (`service_role`) | The **only** path to a provider submission. Takes an advisory lock, then checks:<ul><li>kill switch</li><li>paid switch</li><li>approval matches the current plan</li><li>no conflicts</li><li>clip status</li><li>per-clip / episode / daily / retry limits</li></ul>Then inserts the job and a ledger reservation. Idempotent per key. |
| `vs_settle_job(job, status, actual, usage, error)` | server only | Releases the reservation and records the actual cost. Idempotent. |
| `vs_claim_render_job(worker)` / `vs_complete_render_job(…)` | server only (render worker) | `FOR UPDATE SKIP LOCKED` queue |

Rules enforced both in SQL and in `src/core/budget/budget-guard.ts`, with the same error codes:

- A CONTENT CONFLICT **cannot** be acknowledged; it must be fixed.
- No automatic paid retries: a regeneration needs retry budget or explicit authorization.
- An edit after approval voids the approval, because the plan hash changes.

## RLS

- Every `vs_*` table has RLS enabled. Learners see nothing.
- **Admins read and write the bible directly:** series, characters, assets, content locks.
- **Admins read, but cannot write, production rows:** episodes, scenes, clips.
  - All writes go through the server, which re-validates, re-hashes and re-estimates, or through `vs_approve_episode`.
  - This stops a client from hand-writing an approval or clearing a conflict.
- **Settings, jobs and the ledger are read-only for admins.** Only the server and the functions above write them.
- **The ledger is append-only;** a trigger blocks UPDATE and DELETE.
- **Storage** has a private bucket, `video-studio`, with admin-only policies.

## Existing PassPro tables

- **No existing table is altered.**
- `vs_content_locks.exam_id` references `public.exams`, a read-only foreign key on the Video Studio side.
- `vs_episodes.published_video_id` is reserved for publishing. A row goes into `public.videos` only when a final episode is published. That step is not implemented yet.

## Verified by `npm run test:db`

1. The whole schema is built from scratch **twice**, which proves it can be recreated from migrations.
2. The seeds are applied twice each, which proves they are idempotent.
3. More than 40 assertions pass:
   - seeds, lock statuses and the provenance constraint
   - RLS for learners and admins, including production rows being read-only for clients
   - approval refusals
   - paid-disabled, per-clip, per-episode, daily, retry, authorization and kill-switch guards
   - idempotent reservation, single settlement and the append-only ledger
   - plan-change invalidation
   - the render queue claim and completion
