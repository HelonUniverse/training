# Video provider: MiniMax (Hailuo)

Research date: 2026-09-29. Nothing here has been called against the live API yet.

## How this was researched — read first

The research sandbox's network proxy blocked direct fetches of `platform.minimax.io`,
so the official doc pages themselves could not be opened. Facts come from three
levels of evidence, tagged throughout:

- **[CODE]** — read in MiniMax's own open-source repos, which are the strongest
  source available here:
  - `github.com/MiniMax-AI/cli` (official `mmx` CLI/SDK, last commit 2026-09-19)
  - `github.com/MiniMax-AI/MiniMax-H3` (2026-08-15)
  - `github.com/MiniMax-AI/MiniMax-MCP` and `MiniMax-MCP-JS` (2026-08)
  - `github.com/MiniMax-AI/skills` (2026-04)
- **[SNIPPET]** — search-engine summary of an official platform.minimax.io page.
  The page exists; exact wording and values must be confirmed.
- **[UNVERIFIED]** — third-party source only, or not found.

**Before any money is spent, a human must open these pages and confirm pricing,
resolution support and rate limits** (all on `platform.minimax.io`):

- `/docs/api-reference/video-generation-v2-create`
- `/docs/api-reference/video-generation-v2-regeneration`
- `/docs/guides/pricing-paygo`, `/docs/pricing/overview`, `/docs/guides/pricing-video`
- `/docs/guides/rate-limits`
- `/docs/api-reference/speech-t2a-http`, `/docs/guides/speech-voice-clone`
- `/docs/release-notes/models`

## Recommendation for PassPro

Use **MiniMax-H3 on the v2 API** as the first adapter. It is the only MiniMax
model that:

- takes several character/location **reference images** at once (up to 9),
- generates **native audio with Spanish dialogue and lip sync**,
- accepts **reference audio** so the voice timbre can follow a character's
  master voice sample,
- supports clip durations of **4–15 s**, which matches our 5–15 s clip design.

The legacy v1 models (Hailuo-2.3, Hailuo-02, S2V-01) produce silent video, take
only one subject reference, and are fixed at 6 s or 10 s. They stay as a
fallback adapter only.

## Base URL and authentication

| Item | Value | Evidence |
|---|---|---|
| International base | `https://api.minimax.io` | [CODE] |
| Mainland China base | `https://api.minimaxi.com` (not for us) | [CODE] |
| Auth header | `Authorization: Bearer <MINIMAX_API_KEY>` | [CODE] |
| Content type | `application/json` | [CODE] |
| Key type for H3 | Standard pay-as-you-go / credit API key. Token Plan subscription keys are rejected (error 2013). | [CODE] |
| Secret key prefix | `sk-api-` | [CODE] |
| GroupId | Not sent by any 2026 official code. Older docs required it on some endpoints. | [UNVERIFIED] |

The key lives only in server-side secrets (Supabase Edge Function secrets). It is
never sent to the browser.

## MiniMax-H3 (v2 API)

### Endpoints [CODE]

| Purpose | Method and path |
|---|---|
| Create generation task | `POST /v2/video_generation` |
| Query task | `GET /v2/query/video_generation/{task_id}` |
| Upscale 768p → 2K | `POST /v2/video_regeneration` (input `video_url` with role `base_video` + prompt) |
| Prompt expansion ("Context IR") | `POST /v2/h3_context_ir` |
| Upload a file (gives `mm_file://<file_id>`) | `POST /v1/files/upload` (multipart) |
| Account balance | `/account/query_balance` |

### Request body [CODE]

```json
{
  "model": "MiniMax-H3",
  "content": [
    { "type": "text", "text": "…compiled prompt…" },
    { "type": "image_url", "image_url": { "url": "…" }, "role": "reference_image" },
    { "type": "audio_url", "audio_url": { "url": "…" }, "role": "reference_audio" }
  ],
  "resolution": "2K",
  "duration": 10,
  "ratio": "16:9",
  "callback_url": "https://…/functions/v1/vs-provider-callback"
}
```

| Field | Rules | Evidence |
|---|---|---|
| `model` | `"MiniMax-H3"` is the only model on v2. "Hailuo 03" / "Hailuo 3.0" are unofficial names. | [CODE] |
| text | Exactly one non-empty text item, **max 7000 characters** | [CODE] |
| `duration` | Integer **4–15 s**. CLI default is 5. | [CODE] |
| `resolution` | `"2K"` or `"768P"`. **Conflicting:** the H3 repo scripts send both, but the CLI (2026-09-19) rejects anything except 2K. Treat as **2K only** until confirmed. | [CODE, conflicting] |
| `ratio` | `adaptive`, `21:9`, `16:9`, `4:3`, `1:1`, `3:4`, `9:16`. Text-only needs a concrete ratio. Frame input forces `adaptive`. Reference mode defaults to `adaptive`. | [CODE] |
| Media URLs | Public http(s) URL, Base64 data URL, or `mm_file://<file_id>` | [CODE] |

### Input modes [CODE]

| Mode | Inputs | Notes |
|---|---|---|
| Text → video+audio | text only | |
| First/last frame | at most 1 `first_frame` + 1 `last_frame` | A last frame alone is allowed |
| Omni-reference | up to 9 `reference_image`, 3 `reference_video`, 3 `reference_audio`; 12 files total | **Cannot be mixed with first/last frame.** Reference audio needs at least one reference image or video. |

This matters for continuity. In one request we can lock character identity with
reference images, **or** chain from the previous clip's last frame, but not both.
See the risks section of the implementation plan.

### Media limits [CODE]

- **Images:** JPEG/PNG/WebP, each side 256–5760 px, aspect ratio 0.4–2.5.
- **Videos:** MP4/MOV (H.264/H.265), 23.976–60 fps, each 2–15 s, 15 s total or less.
- **Audio:** MP3/WAV, each 2–15 s, 15 s total or less.
- **CLI-side caps:** image 30 MB, video 50 MB, audio 15 MB, 64 MB request body.

### Output [CODE]

- 24 fps.
- 32 kHz stereo audio, generated together with the video: dialogue, ambience and music.
- Dialogue is stable in 11 languages, **including Spanish**.
- Reference audio sets voice timbre. The official example uses "Voice timbre follows reference audio 1".
- The base model renders at 768p; 2K comes from the regenerate pass.

### Camera

H3 takes natural-language camera terms, such as "static shot", "close-up",
"tracking shot", "dolly in", "pan", "tilt", "handheld" and "aerial view" [CODE].
The `[Pan left]` bracket syntax belongs to the v1 models and is not documented for H3.

### Async job behaviour [CODE]

1. `POST` create returns `{ "task_id": "…" }`.
2. `GET` query returns:
   ```
   task { id, model, status, error{code,message}, created_at, updated_at,
          content{url}, resolution, duration, ratio, task_type,
          usage{total_seconds, input_seconds, output_seconds, input_image_count} }
   ```
3. Status values are `queued`, `running`, `succeeded`, `failed`, `cancelled` and `expired`.
4. The MP4 URL is in `task.content.url`; there is no separate file-retrieve step.
   Its expiry is unknown [UNVERIFIED], so **we download it into our own storage
   immediately**.
5. Poll no more often than every 10 s. No ETA is published; the official CLI gives
   up after 30 min.
6. **Every submission is billed. Never resubmit once a `task_id` exists.**

### Callback [SNIPPET]

When `callback_url` is set:

1. MiniMax first sends a verification request containing `challenge`. We must echo
   it back within 3 s.
2. After that, it POSTs on every status change. The body has the same shape as the
   query response.

We use the callback as the fast path and a cron poll as the safety net.

### Error codes [CODE]

| Code | HTTP | Meaning | Our handling |
|---|---|---|---|
| 1002 | 429 | Rate limited | Wait 60 s. Retrying **submission** is only safe if no `task_id` was returned. |
| 1008 | 402 | Insufficient balance | Stop the queue and alert |
| 1026, 1027 | 422 | Content moderation rejection | Mark clip `NEEDS_REVIEW` |
| 1000, 1001, 1024, 1033 | 5xx | Temporary errors | Retry the status poll only; never a re-submit without approval |
| 1004, 2049 | — | Authentication | Stop and alert |
| 2013 | — | Key type does not support H3 | Configuration error |

Moderation covers prompts, images, videos and the expanded prompt [CODE].

## Pricing

**No price below is confirmed from an official page.** The estimator stores these
as a configurable price table flagged `verified = false` until a human confirms them.

| Item | Price | Evidence |
|---|---|---|
| H3 2K | ~$0.13 per output second | [UNVERIFIED] third-party (atlascloud, wavespeed, ofox) |
| H3 768P | ~$0.08 per output second | [UNVERIFIED] |
| 768P → 2K regenerate | ~$0.05 per second | [UNVERIFIED] |
| Reference images | First 5 free, then ~$0.04 each; audio inputs free | [UNVERIFIED] |
| Hailuo-02 768P (v1) | 6 s $0.28, 10 s $0.56 | [UNVERIFIED] |
| Hailuo-02 1080P (v1) | 6 s $0.49 | [UNVERIFIED] |
| MiniMax's own claim | H3 2K costs under 1/3 of flagship competitors per second | [SNIPPET] |

The query response includes `usage.output_seconds` and `usage.input_image_count`
[CODE]. **Actual cost** is computed from that usage times the confirmed rate, and
reconciled against `/account/query_balance` before and after a batch.

Rough example for Video 0: about 125 s of output × $0.13 ≈ **$16–17** for a
first full pass at 2K, before regenerations. This is **unverified**.

## Rate limits

The official `/docs/guides/rate-limits` page exists and describes RPM/TPM limits,
dynamic throttling at peak times, and roughly 1-minute resets [SNIPPET]. **No
specific video RPM or concurrency numbers were found.** The MVP limits itself to
2 concurrent tasks (configurable) and backs off 60 s on 1002/429.

## Legacy v1 models (fallback only)

- **Create:** `POST /v1/video_generation`
- **Query:** `GET /v1/query/video_generation?task_id=…`
- **Retrieve:** `GET /v1/files/retrieve?file_id=…` returns `download_url`, valid for about 1 hour [CODE: skills guide].
- **Status values:** Preparing, Queueing, Processing, Success, Fail [CODE].
- **Models [CODE]:**
  - `MiniMax-Hailuo-2.3`: T2V/I2V; 768P at 6/10 s, 1080P at 6 s
  - `MiniMax-Hailuo-2.3-Fast`: I2V only
  - `MiniMax-Hailuo-02`: T2V, I2V and first+last frame
  - `S2V-01`: `subject_reference: [{type: "character", image: [url]}]`
  - `T2V-01(-Director)`, `I2V-01(-Director|-live)`
- **Prompt limit:** 2000 characters. `prompt_optimizer` defaults to true.
- **Camera:** bracket commands, such as `[Pan left]`, `[Push in]` and `[Static shot]`.
- **Audio:** no evidence of any audio. Treat as silent video [UNVERIFIED].

## MiniMax speech (candidate VoiceProvider)

| Item | Value | Evidence |
|---|---|---|
| Endpoint | `POST /v1/t2a_v2` (sync, up to 10,000 characters) | [CODE] |
| Models | `speech-2.8-hd` (default), `speech-2.8-turbo`, `speech-2.6-*`, `speech-02-*`, `speech-01-*` | [CODE] / [SNIPPET] |
| Voice settings | `voice_id`, `speed` 0.5–2, `vol` 0–10, `pitch` −12..12, `emotion` (happy, sad, angry, fearful, disgusted, surprised, calm, fluent, whisper) | [CODE] |
| Output | hex or URL; mp3/pcm/flac(/wav); `extra_info.audio_length` | [CODE] |
| Voice clone | 1. `POST /v1/files/upload` (`purpose=voice_clone`)<br>2. `POST /v1/voice_clone` with our chosen `voice_id`<br>3. Use that `voice_id` in `t2a_v2` | [CODE] |
| Other | `/v1/get_voice` (list voices), `/v1/voice_design` (create a voice from a description) | [CODE] |
| Pricing | speech-2.8-hd ~$100 per 1M characters; turbo ~$60 per 1M; clone ~$1.50 per voice; design ~$3 per voice | [UNVERIFIED] |

ElevenLabs remains the alternative VoiceProvider. The interface is the same either way.
