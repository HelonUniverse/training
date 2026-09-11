# STEP 7 phases 1-2 — managed deployment record

Migrations 0081, 0082 and 0083 applied to `homeschool-os-dev`
(`ucgxdtulnzumrroanais`, PostgreSQL 17.6) on 2026-09-09, in that order, each as
its own migration through the Supabase MCP channel.

| ledger version | name | file |
|---|---|---|
| `20260909005759` | `step7_evidence_axes` | `20260909010000_evidence_axes.sql` |
| `20260909010313` | `step7_skill_state_model` | `20260909010100_skill_state_model.sql` |
| `20260909010640` | `step7_invariants` | `20260909010200_step7_invariants.sql` |

## Nothing that was there before moved

The same snapshot query was run against managed immediately before 0081 and
again after 0083. Every value is unchanged:

| | before 0081 | after 0083 |
|---|---|---|
| RLS policy digest (the three affected tables) | `44a0ff66f0db63c6b9b7e258d4233e2e` | `44a0ff66f0db63c6b9b7e258d4233e2e` |
| policies on those tables | 9 | 9 |
| `student_skills` triggers | 2 | 2 |
| `student_skill_events` append-only trigger | `O` (enabled) | `O` (enabled) |
| published Florida B.E.S.T. standards | 184 | 184 |
| skill↔standard mappings | 0 | 0 |
| prerequisites created by import | 0 | 0 |
| STEP 6 staged-row content digest | `b0c0d24c365da8ac39524aa30640d229` | `b0c0d24c365da8ac39524aa30640d229` |
| standards columns on `public.skills` | 0 | 0 |

The RLS digest is over `polname`, `polcmd`, `polqual` and `polwithcheck` — the
policy's actual meaning, not its name or its count. It is byte-identical, so no
policy was rewritten, and none of the nine references a column this deployment
retired.

## Local ↔ managed

`scripts/schema-digest.sql`, run on local `hos_test` (PG 16.13) and on managed
(PG 17.6). All twelve rows agree:

| row | n | digest |
|---|---|---|
| tables_with_rls | 173 | `0b8dc5a1c51fba1a6a7da9cc1ef95392` |
| tables_without_rls | 0 | none |
| policies_public | 230 | `d195337f6df85df3d03930798a71694b` |
| policies_storage | 7 | `5e72593de13e23cf6bab72944af81f5f` |
| functions_app_public | 111 | `da3fd8fc1d5aeba172a4a0bc8339fa14` |
| triggers_public | 195 | `cf8408d28b0810d1f3bfb7ae69273105` |
| enum_labels | 636 | `5d51791b1df54fdb58deb8d326327702` |
| capabilities_rows | 448 | `01a1d7229283f333d39e40f7a21f6c57` |
| buckets_total | 6 | `c2514f3190e8460a12d7b4236c0dca57` |
| buckets_public | 0 | none |
| definer_without_search_path | 0 | none |
| view_write_grants_to_users | 0 | none |

`enum_labels` covering all 636 labels of the `app` schema is what proves both
sides carry the same three new types and neither carries the two retired ones.

## The shape that was deployed

    app.skill_state           unknown, emerging, developing, secure
    app.evidence_confidence   preliminary, supported, corroborated
    app.evidence_source       parent, teacher, tutor, evaluator, student_self,
                              assessment_instrument, provider_system,
                              portfolio_artifact, diagnostic_session, unknown
    app.record_provenance     human_entered, human_confirmed_ai_proposal,
                              (human_confirmed_system_observation added by 0096)
                              ai_proposed_unreviewed, document_extraction,
                              provider_import, system_computed, unknown

`app.confidence_level` and `app.mastery_level` are gone. `score`,
`mastery_level`, `delta` and `confidence` are absent from `student_skills` and
`student_skill_events`; `confidence` is absent from `assessment_results`.
`app.assert_schema_invariants()` passes.

`assessment_results.percentage` still exists and is deliberately untouched. A
test instrument genuinely has a percentage; what STEP 7 retired is a percentage
standing for a *child's* skill, which is why the invariant names only
`student_skills` and `student_skill_events`.

## What was proved by behaviour, not by catalog

Run as `authenticated` with `auth.uid()` set to Carla, `is_superuser = off`, so
RLS was genuinely in force. Every write below was rolled back.

| | managed | local |
|---|---|---|
| UPDATE an event | refused, 23001 append-only | identical |
| UPDATE an event's `skill_state` | refused, 23001 append-only | identical |
| DELETE an event | refused, 23001 append-only | identical |
| DELETE the parent row, cascading into events | refused, 23001 append-only | identical |
| unreviewed-AI event carrying `developing` | refused, `sse_unreviewed_ai_has_no_state_ck` | identical |
| unreviewed-AI event at `unknown` | accepted | identical |
| unreviewed-AI event with a null state | accepted | identical |
| unreviewed-AI skill at `emerging` | refused, `student_skills_unreviewed_ai_has_no_state_ck` | identical |
| unreviewed-AI skill at `secure` *with* a human confirmation stamp | refused, `student_skills_secure_requires_human_ck` | identical |
| `secure` with no human confirmation | refused, `student_skills_secure_requires_human_ck` | identical |
| unreviewed-AI skill at `unknown` | accepted — the review queue still works | identical |
| promoting that queued row while it stays unreviewed | refused | identical |
| a person reviewing it, then promoting it | accepted → `developing` | identical |
| **a parent human-confirming her own child `secure`** | **accepted, and visible to her** | identical |

The last row is the one that matters for this product. The 0012 constraint it
replaces required `teacher_observed` or `assessment_confirmed`, which in a
homeschool — where the parent is the teacher — meant no parent could ever record
her own child as secure. Nestra protects against a *machine* deciding, not
against a particular class of authorized human.

The cascade-delete row was not planned. It surfaced because a cleanup step in
the probe tried to delete the parent `student_skills` row and the append-only
trigger refused the cascade. That is the correct answer — history is not erasable
through a foreign key — and it is now recorded as a property rather than an
accident.

## The migration regression suite

It ran against local, PASS: `tests/migration/run.sh` builds the schema as it
stood at 0080, seeds seven synthetic legacy rows carrying every old enum value,
applies the three real migration files, and asserts the outcome.

It did **not** run against managed, and cannot: it requires a pre-STEP-7 schema,
and managed is now migrated. Re-creating one there would mean tearing the
deployed schema back down. What was checked on managed instead is the mapping
vocabulary evaluated against the deployed enums:

    not_started -> unknown      progressing -> developing
    introduced  -> unknown      proficient  -> developing
    developing  -> developing   mastered    -> secure

    no legacy value produces `emerging`
    only `mastered` reaches `secure`
    nothing is written into evidence_confidence

and the fact that decides how much the backfill mattered here: `student_skills`,
`student_skill_events` and `assessment_results` all held **0 rows** before and
after. On managed these migrations were purely structural. The row-level mapping
is exercised where rows exist, which is the regression suite.

That the suspend/restore of the append-only trigger works on real rows is
therefore evidence from local, not from managed — and it is the reason the
trigger is verified enabled again on managed above.

## Local state at deployment

13/13 SQL suites PASS, migration regression PASS, on commit `ef62f6b`.
