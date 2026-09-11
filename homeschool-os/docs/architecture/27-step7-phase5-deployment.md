# STEP 7 Phase 5 — the adaptive diagnostic, deployed to managed

**Project:** `homeschool-os-dev` (`ucgxdtulnzumrroanais`), PostgreSQL 17.6
**Local:** PostgreSQL 16.13, `hos_test`
**Date:** 2026-09-11
**Rule version introduced:** `app.diagnostic_rule_version() = '2026-09-11.1'`

## What was applied

| # | file | managed migration name |
|---|---|---|
| 0092 | `20260911010000_diagnostic_schema.sql` | `step7_diagnostic_schema` |
| 0093 | `20260911010100_diagnostic_engine.sql` | `step7_diagnostic_engine` |
| 0094 | `20260911010200_diagnostic_seed_items.sql` | `step7_diagnostic_seed_items` |
| 0095 | `20260911010300_diagnostic_invariants.sql` | `step7_diagnostic_invariants` |

All four were sent through the Supabase MCP channel **verbatim, comments
included** — the lesson from 0088. The per-function body check below confirms it
worked: every one of the seventeen functions Phase 5 adds is byte-identical on
both databases.

Each migration ends in `select app.assert_schema_invariants()`, so any of them
that violated a structural guarantee would have refused to apply.

## Catalogue parity — 13 of 14 digest rows identical

`scripts/schema-digest.sql`, run on both sides:

| row | local | managed |
|---|---|---|
| tables_with_rls | 181 / `85679ab3049d597477f65a2e0bee853d` | same |
| tables_without_rls | 0 | same |
| policies_public | 249 / `900b8ee65babf97d44ae03f2af86f05f` | same |
| policies_storage | 7 / `5e72593de13e23cf6bab72944af81f5f` | same |
| functions_app_public | 146 / `afdf90f85714d58d6d547ea532a4c7a7` | same |
| **canonical_function_bodies** | 146 / `b836e9f1641a7821d5636e73a4b404c2` | **same** |
| function_bodies (raw text) | 146 / `40194dd62cb9b86a2a10f50e931ca6e1` | `40e6284d1f1bb5fcbfe54e745716bc9e` |
| triggers_public | 201 / `31cc95bc1db5f6831856a5fc3d019523` | same |
| enum_labels | 703 / `b72c52909502ab5c055b3f0ebde7ca00` | same |
| capabilities_rows | 448 / `01a1d7229283f333d39e40f7a21f6c57` | same |
| buckets_total | 6 / `c2514f3190e8460a12d7b4236c0dca57` | same |
| buckets_public | 0 | same |
| definer_without_search_path | 0 | same |
| view_write_grants_to_users | 0 | same |

The raw-text row is the standing cosmetic drift, and the canonical row matching
is what says the same code runs on both.

## Function-body parity, function by function

A full outer join of `md5(prosrc)` across all 146 functions in `app` and
`public` was run on managed against the local values. No function exists on one
side and not the other. Twenty-five bodies differ in text only:

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

Every one is from STEP 2–6. **No Phase 3, Phase 4 or Phase 5 function drifted.**

This is the deferred-hygiene item, and the count in
`23-deferred-hygiene.md` has been corrected from 22 to 25 — the list was never
enumerated when it was first recorded, so it could not be checked. It is
enumerated now, and the correction is a counting correction, not new drift: the
canonical digest matched then and matches now.

## Route parity — the same scripted sessions on both databases

Eleven scripted diagnostic sessions plus a four-arm standards/grade/age
regression were run, as Carla, against Lucas, inside a transaction that was
rolled back on both sides. The output was diffed mechanically. It is identical
line for line, with one exception noted at the end.

```
A  nothing known yet              NST.FR.1/explore_next_skill/demonstrated | NST.FR.1/uncertainty_probe/demonstrated | NST.FR.2/explore_next_skill/-  [stop=parent_stopped]  [obs=2 profile_rows=0]
B  two skills established         NST.FR.3/explore_next_skill/demonstrated | NST.FR.3/uncertainty_probe/-  [stop=parent_stopped]  [obs=1 profile_rows=2]
C  root confirmed secure          NST.FR.2/explore_next_skill/demonstrated | NST.FR.2/uncertainty_probe/-  [stop=parent_stopped]  [obs=1 profile_rows=1]
D  floor, one prerequisite probe  NST.FR.3/explore_next_skill/not_demonstrated | NST.FR.3/uncertainty_probe/not_demonstrated | NST.FR.2/prerequisite_probe/-  [stop=parent_stopped]  [obs=2 profile_rows=2]
E  prerequisite human-secure      NST.FR.3/explore_next_skill/not_demonstrated | NST.FR.3/uncertainty_probe/not_demonstrated  [stop=frustration_floor]  [obs=2 profile_rows=2]
F  the probe itself fails         NST.FR.3/explore_next_skill/not_demonstrated | NST.FR.3/uncertainty_probe/not_demonstrated | NST.FR.2/prerequisite_probe/not_demonstrated  [stop=frustration_floor]  [obs=3 profile_rows=2]
G  skipped and not_today          NST.FR.1/explore_next_skill/skipped | NST.FR.1/uncertainty_probe/not_today | NST.FR.1/uncertainty_probe/skipped  [stop=no_items_available]  [obs=3 profile_rows=0]
H  success ceiling                NST.FR.1/explore_next_skill/demonstrated | NST.FR.1/uncertainty_probe/demonstrated | NST.FR.2/explore_next_skill/demonstrated | NST.FR.2/uncertainty_probe/demonstrated | NST.FR.3/explore_next_skill/-  [stop=parent_stopped]  [obs=4 profile_rows=0]
I  prereq seen this session       NST.FR.4/explore_next_skill/demonstrated | NST.FR.4/uncertainty_probe/demonstrated | NST.FR.5/explore_next_skill/not_demonstrated | NST.FR.5/uncertainty_probe/not_demonstrated | NST.FR.3/prerequisite_probe/-  [stop=parent_stopped]  [obs=4 profile_rows=3]
J  two eligible prerequisites     NST.FR.5/explore_next_skill/not_demonstrated | NST.FR.5/uncertainty_probe/not_demonstrated | NST.FR.3/prerequisite_probe/-  [stop=parent_stopped]  [obs=2 profile_rows=4]
K  the reading branch             READ.PHO/explore_next_skill/not_demonstrated | READ.PHO/uncertainty_probe/not_demonstrated  [stop=frustration_floor]  [obs=2 profile_rows=0]
```

What each one demonstrates on managed, not only in the local suite:

- **A** the session opens at the root when nothing is known, and two
  demonstrations move it on. `profile_rows=0`: nothing was written to the child's
  profile.
- **B** with FR.1 and FR.2 established the session opens at **FR.3** and never
  mentions FR.1 or FR.2. That is the rule that stops a child being asked about
  addition because of her age.
- **C** a skill a parent confirmed `secure` is not retested.
- **D** the approved refinement, on managed: two consecutive unsuccessful
  observations floor the branch, and **exactly one** `prerequisite_probe`
  follows, aimed at the direct prerequisite FR.2.
- **E** the same situation, but FR.2 is human-confirmed `secure` — **no probe at
  all**, `stop=frustration_floor`. A parent's standing judgement is not reopened
  because the next skill up went badly.
- **F** the probe itself comes back `not_demonstrated` — the branch ends. There
  is no second probe and no staircase.
- **G** four `skipped`/`not_today` answers in a row never reach the floor. The
  session ends because the item bank ran out, not because a child failed.
- **H** the ceiling: two demonstrations per skill, never three, even when more
  items exist.
- **I** FR.3 was demonstrated earlier in the session and is still the probe
  target only because it was *not* answered in that run; the prerequisite the
  child actually answered is not re-asked.
- **J** FR.5 has two direct prerequisites, FR.3 and FR.4. Exactly one probe, and
  it is FR.3 — the stable skill-code tie-break, not a benchmark, grade or age.
- **K** a hard afternoon with fractions leaves reading untouched: a session
  rooted at READ.PHO is unaffected by anything that happened in the fraction
  branch.

In every scenario `profile_rows` equals the number of skills established by hand
beforehand. **No diagnostic session created or changed a single profile row.**

### Standards, grade and age independence — four arms, one route

```
1 no mappings                     NST.FR.1/... | NST.FR.2/explore_next_skill/-  [stop=parent_stopped]  [obs=2 profile_rows=0]
2 every skill mapped              (identical)
3 catalogue renamed away          (identical)
4 grade 11, born 2015             (identical)
```

Arm 3 renames `public.standards` and `public.skill_standards` out from under the
running engine inside the transaction. The route is unchanged, which is a
stronger statement than "it does not join them": it *cannot*.

Arm 4 sets Lucas to grade 11 with a 2015 date of birth. Identical route.

### Rule version

```
current rule version              2026-09-11.1
resume under stale rules          resumed=false  reason=rule_version_changed
                                  session_rv=1999-01-01.0  current_rv=2026-09-11.1
```

A session paused under one rule version is not silently re-routed under another.

### Authenticated RLS probes

Both probes ran with `set local role authenticated` and a JWT sub, so RLS
genuinely applied (`current_user=authenticated`, not a superuser).

```
a stranger to this child   start refused: not permitted  |  items visible: 19  sessions visible: 0
the parent of this child   items she can read: 19  |  UPDATE changed 0 rows  |  DELETE removed 0 rows
                           |  INSERT refused: new row violates row-level security policy
```

Diego is a guardian of Sofia, not of Lucas. He cannot start a session for Lucas
and sees none of anyone's. The shared item bank is readable by every signed-in
family — it holds prompt keys, not children — and is not writable by any of them.

**On the item bank's table grants.** `authenticated` holds
INSERT/UPDATE/DELETE at the table level on `diagnostic_items`, because
`0036_grants_and_invariants` sets `alter default privileges in schema public
grant select, insert, update, delete on tables to authenticated` as a deliberate
project-wide posture: *privileges are granted broadly; RLS decides*. The per-table
`grant select` in 0092 is narrower than that default, not wider, and the probe
above is what proves the posture holds — every write is refused. This is not a
defect and no migration was added for it.

## What the deployment did not change

Pre-deployment baseline against post-deployment reality:

| | before | after |
|---|---|---|
| `rls_digest` (student_skills, student_skill_events, assessment_results) | `44a0ff66f0db63c6b9b7e258d4233e2e` | **unchanged** |
| `step6_digest` (all staged standards rows) | `b0c0d24c365da8ac39524aa30640d229` | **unchanged** |
| standards | 184 | 184 |
| skill mappings | 0 | 0 |
| imported prerequisites | 0 | 0 |
| standards columns on `public.skills` | 0 | 0 |
| families with the refresh advisory on | 0 | 0 |
| `app.recompute_rule_version()` | `2026-09-09.2` | `2026-09-09.2` |
| profile rows / events / overrides / refresh decisions | 0 | 0 |
| prerequisite edges | 5 | 5 |

Phase 5 introduced a new rule version of its own
(`app.diagnostic_rule_version() = '2026-09-11.1'`) and deliberately did **not**
move the profile rule version: no state any child holds was computed differently.

Diagnostic tables after deployment: **19 seed items**, and zero sessions, session
items, observations and routing decisions — the probes rolled back completely.

## Phase 3 and Phase 4 invariants, re-checked on managed

```
assert_schema_invariants()            passes
phase 3 constraints present           student_skills_computed_state_never_secure_ck
                                    + student_skills_override_is_effective_ck
                                    + student_skills_secure_requires_human_ck
                                    + student_skills_unreviewed_ai_has_no_state_ck
phase 4 advisory columns              refresh_advisory_enabled=false  refresh_interval_days=180
computed_state = secure               refused: student_skills_computed_state_never_secure_ck
override_state without an override    refused: student_skills_override_is_effective_ck
refresh advisory, feature off         suggested=false
                                      blocked=["family_has_not_enabled_it","no_current_relevance",
                                               "interval_has_not_elapsed","no_profile_yet"]
skill_state labels                    unknown, emerging, developing, secure
diagnostic_outcome labels             demonstrated, not_demonstrated, skipped, not_today
evidence_confidence labels            preliminary, supported, corroborated
evidence_sufficiency labels           none, preliminary, supported, corroborated
```

A machine still cannot compute `secure`. A human decision still outranks a
computed state. The refresh advisory is still off for every family and still
says why. The four-label state model is intact, and `skipped` and `not_today`
still have no failing sibling.

## Test counts

- **16 SQL suites, all PASS**; 18 files discovered, 2 fixtures, 16 tests, 16
  executed, 0 skipped, 0 unexpected.
- **693 assertion call sites** across the suites, of which **84 are Phase 5**
  (`tests/rls/16_step7_diagnostic.sql`), 54 Phase 4 and 109 Phase 3.
- **Migration regression: PASS** — 15 migrations replayed over synthetic
  pre-STEP-7 rows.
- `typecheck`, `lint` clean. Guards clean: service-role, `'use client'`,
  permission-wrapped server actions, **767 i18n keys in both locales**, family
  language.

## Defects found during managed deployment

**None in the migrations.** All four applied first time, and every structural
and behavioural check above passed on the first run.

One bookkeeping correction: the deferred-hygiene note said 22 cosmetically
drifted function bodies; the actual figure, now enumerated, is 25. The list had
never been written down, so the number could not be verified until this
deployment produced it. All 25 are STEP 2–6, and the canonical digest matches,
so nothing about what runs has changed.

Two probe bugs, found and fixed while building the verification (not defects in
the product):

1. The first RLS write probe concluded the parent had edited the item bank
   because the `UPDATE` raised no exception. It had changed zero rows — RLS
   filters a write to nothing rather than raising. The probe now reports
   `row_count`. This is the same trap as the Phase 3 test-10h finding.
2. The standards arm inserted into `public.skill_standards` with invented column
   names and silently reported the error as its result. Fixed to the real
   columns, which is what made arm 2 a real test instead of a caught exception.

---

# Addendum, 2026-09-11 — the provenance patch (0096-0097)

Phase 5 was approved with one required correction:
`confirm_diagnostic_observation` was writing its evidence as
`human_confirmed_ai_proposal`, which is false. The routing engine is
deterministic and consults no model, so its evidence is a **system** observation
that a person confirmed.

## Applied

| # | file | managed name |
|---|---|---|
| 0096 | `20260911020000_provenance_system_observation_enum.sql` | `step7_provenance_system_observation_enum` |
| 0097 | `20260911020100_provenance_system_observation.sql` | `step7_provenance_system_observation` |

Split in two because PostgreSQL adds an enum value inside a transaction but will
not let the same transaction use it.

## Behaviour, identical on both databases

Line for line, local and managed:

```
provenance labels             human_entered, human_confirmed_ai_proposal,
                              human_confirmed_system_observation, ai_proposed_unreviewed,
                              document_extraction, provider_import, system_computed, unknown
before review: evidence rows  0
before review: profile rows   0
confirmed: provenance         human_confirmed_system_observation
confirmed: evidence source    diagnostic_session
confirmed: names no suggestion true
confirmed: asserts            developing
usable evidence               1
human entered or confirmed    1
computed state                emerging
effective state               emerging
profile rule version          2026-09-09.2
hand-written AI label         refused: sse_diagnostic_evidence_is_not_an_ai_proposal_ck
AI label from elsewhere       accepted, as it should be
invariants                    pass
```

## Catalogue parity

13 of 14 digest rows identical, `canonical_function_bodies 146 /
2fa88670e877ba929ba5594b905a1fb6` and `enum_labels 704 /
2ee8a25d86620c0153c2b14a8d094933` among them — the new label sits in the same
sort position on both. The three functions this patch replaced
(`confirm_diagnostic_observation`, `app.compute_skill_state`,
`app.assert_schema_invariants`) are **byte-identical** on both sides. The raw
`function_bodies` row still differs by the standing 25 STEP 2-6 drifts.

## Unchanged

`rls_digest` `44a0ff66…` · `step6_digest` `b0c0d24c…` · standards 184 · mappings
0 · profile rule version `2026-09-09.2` · diagnostic rule version `2026-09-11.1`
· families with the advisory on 0 · 19 seed items · profile rows, events,
sessions and observations all 0, so the probes rolled back · the append-only
trigger on `student_skill_events` is enabled (`O`).
