# Deferred database hygiene

Standing items that are known, understood, harmless today, and deliberately not
being fixed inside a feature deployment. Recorded here so they are a decision
rather than a thing nobody noticed.

## 25 cosmetically drifted function bodies (local ↔ managed)

**Status:** deferred by decision, 2026-09-09. Do not repair inside a phase.

Every migration applied to `homeschool-os-dev` before Phase 4 crossed the
Supabase MCP channel by hand, and some had their comments trimmed on the way to
keep the payload manageable. The result is that 25 of the 146 function bodies in
`app` and `public` differ textually between the repository and managed.

**Corrected 2026-09-11.** This originally said 22 of 121 and never enumerated which,
so the number could not be checked. The STEP 7 Phase 5 deployment ran a
per-function `md5(prosrc)` join across both databases and produced the list.
It is 25 of 146. The three extra were always drifted; they were missed when
the figure was first recorded by hand. The canonical digest matched then and
matches now, so nothing about what runs has changed.

**They do not differ in what they do.** `scripts/schema-digest.sql` reports two
rows for exactly this reason:

| row | meaning |
|---|---|
| `function_bodies` | the text as stored. Differs — this is the drift. |
| `canonical_function_bodies` | comments stripped, whitespace removed. **Matches on both sides** — `16d6d06f4e748514773cb7f59aab4205` at Phase 3, `b836e9f1641a7821d5636e73a4b404c2` after Phase 5. The value moves as code is added; what matters is that it is the same value on both databases. |

So the same code runs on both databases; only the reasoning written beside it is
missing on one. The functions involved are all from STEP 2–6. In full:

`app.audit`, `app.capture_history`, `app.enforce_minor_thread_safety`,
`app.guard_evaluation_transition`, `app.my_document_visibilities`,
`app.my_student_relationships`, `app.prevent_prerequisite_cycle`,
`app.protect_mapping_approval`, `app.record_scan_result`, `app.student_access`,
`public.accept_invitation`, `public.add_child`, `public.add_family_course`,
`public.confirm_skill_evidence`, `public.create_portfolio_item`,
`public.decide_suggestion_field`, `public.log_activity`,
`public.onboard_organization`, `public.onboard_parent`,
`public.preview_invitation`, `public.queue_document_analysis`,
`public.record_manual_completion`, `public.revoke_document_share`,
`public.share_document`, `public.skill_prerequisite_closure`.

The two Phase 3 functions that had drifted were restored verbatim in migration
0088 and are not part of this list. No Phase 3, Phase 4 or Phase 5 function has
ever drifted: those migrations were applied to managed with their comments
intact, which is the practice 0088 established.

**Why it is deferred rather than fixed.** Repairing it means re-applying 25
function definitions to managed, which is 25 opportunities to introduce a real
difference while removing a cosmetic one — inside a deployment whose subject is
something else entirely. The right time is a dedicated pass with nothing else in
flight.

**How it will be caught if it ever becomes real.** `canonical_function_bodies`
is now part of the standard digest. If that row ever differs, the drift has
stopped being cosmetic and is a defect to fix immediately.
