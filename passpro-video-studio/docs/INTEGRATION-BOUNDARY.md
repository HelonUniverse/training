# Integration boundary: where the PassPro frontend plugs in

**Status: frontend integration is STOPPED.** The PassPro frontend source code
was not found in any repository or workspace this session can reach (see the
search record below). Nothing UI-related has been built, and no second PassPro
app was created.

## Layers

```
Video Studio Core            src/core/            no insurance / exam knowledge
   ↓ hooks (PlanValidator, FactContextProvider)
PassPro Education Layer      src/education/       content locks, Spanish number parsing
   ↓ reads
Content Locks / Exam Facts   vs_content_locks (+ public.exams)
   ↓
PassPro UI                   ⟵ NOT FOUND — integration point described here
```

An automated test (`test/worker-and-boundaries.test.ts`) fails the build if
`src/core` ever imports the education layer or the worker, or if an exam fact
is hard-coded in core or education code.

## What the frontend will call

Each call is server-side: a Supabase Edge Function that verifies
`is_admin()` from the caller's JWT, as the existing `desde-la-red`
`generate-teaching` function does. Every call maps 1:1 to a `StudioService`
method that already exists and is tested:

| UI action | Server call → `StudioService` | Writes |
|---|---|---|
| Series / Character Bible screens | direct supabase-js on `vs_series`, `vs_characters`, `vs_assets` (RLS: admin) | bible rows |
| Upload reference image or voice sample | Storage upload to `video-studio/refs/…`, then an insert into `vs_assets` (`kind: reference_image \| voice_sample`, `character_id`), then set `vs_characters.primary_reference_asset_id` | asset rows |
| New Episode | `createEpisode` | `vs_episodes` |
| ANALYZE SCRIPT | `analyzeEpisode` → `planView` | scenes, clips, `plan_hash` (**no provider call**) |
| [EDIT] clip | `editClip` | clip; re-validation; new `plan_hash` (voids approval) |
| [APPROVE] clip | `approveClip` | clip status |
| Acknowledge a review item | `acknowledgeIssue` (refuses CONTENT CONFLICT) | clip issues |
| APPROVE EPISODE & GENERATE | RPC `vs_approve_episode` (user JWT), then `generateApproved` | ledger authorization, jobs |
| Background progress | cron / MiniMax callback → `tick` | jobs, versions, ledger |
| Clip library | `selectVersion`, `deleteVersion` (soft), `regenerateClip`, `authorizeRegeneration` | clip versions, ledger |
| Timeline | `buildTimeline`, `reorderTimeline`, `removeFromTimeline`, `setTransition` | `vs_episodes.timeline` |
| Captions | `captionsSrt` (SRT download) | — |
| EXPORT MP4 | `requestRender` → Railway worker | render job |
| Cost dashboard | `costSummary` (or `vs_cost_summary` view) | — |

**Refresh survival.** The UI keeps no generation state. It reads `vs_*` rows
and can subscribe to Supabase Realtime on `vs_clips`, `vs_generation_jobs` and
`vs_episodes`.

## Still to build once the frontend is located

1. `SupabaseStudioStore` implementing `StudioStore` (`src/core/workflow/store.ts`). Its money methods call the SQL functions.
2. The Edge Functions listed above (thin wrappers around `StudioService`), plus the MiniMax callback endpoint. `parseMinimaxCallback` already handles the verification challenge.
3. The Studio screens inside the existing PassPro app, using its design system.

## Search record (2026-09-29)

**Access in this session:**

- GitHub: `HelonUniverse/training` (attached). Also read-only clones of every other repo the account lists:
  - `estandares-curriculo` (private, attached)
  - `hub`, `trainer`, `learningorbit`, `Learning-Orbit`, `autism`, `Daily-Observations`, `test` (public, anonymous read)
- Supabase: projects `passpro`, `PEAK/PRESENZA`, `homeschool-os-dev`, `verified-agent`
- Vercel: team `admin-70541029's projects`, with projects `desde-la-red`, `project-pc02x` (rbttraining.helonuniverse.com) and `project-y43mm`
- Cloudflare: 10 Workers (presenza-*, spark-call-bridge, panel-*, verified-agent, cuestionario-marca, iaa-transcribe, iln-motor)
- Google Drive: connected

**Searched for:**

- `passpro` / `PassPro`
- the Supabase ref `lhsbaiiympnlmwsfytus`
- tables `exams`, `exam_blueprints`, `question_attempts`, `coach_bookings`, `videos`
- `scored_questions`, `FL-2-14`, `2-14`
- `is_admin(` and `learner` / `coach` / `admin` usage
- `*.supabase.co` URLs

**Where:**

- a grep across all 9 cloned repos
- GitHub code search (the ref, and `passpro` in the org)
- GitHub repository search
- Drive full-text search
- Vercel projects
- Cloudflare Workers
- the passpro auth logs (no redirect/referrer URLs; 1 user)

**Result:** no match anywhere.

- The only Supabase URL found in code belongs to `desde-la-red`.
- The public GitHub repos named "PassPro" belong to unrelated owners (password managers).
- The `passpro` Supabase project has no Edge Functions and no storage buckets.

**Conclusion:** the PassPro frontend lives somewhere this session cannot see: a
repo under another GitHub account or org, a local-only project, or another
builder tool.
