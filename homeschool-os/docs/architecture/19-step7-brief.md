# 19 — STEP 7 brief: Student Skill Profile + Adaptive Diagnostic

This is the specification to hand to the session that builds STEP 7. It is
written to be pasted whole. Everything in it is a constraint, not a suggestion.

---

# BUILD STEP 7 — STUDENT SKILL PROFILE + ADAPTIVE DIAGNOSTIC

## 0. What already exists — do not re-derive it

- **STEP 5** built the skill graph (`skills`, `skill_prerequisites`),
  `learning_evidence`, the curriculum provider model, and the analysis
  lifecycle. `learning_evidence` deliberately **never writes mastery**.
- **STEP 6** built the standards reference layer and ingested Florida B.E.S.T.
  Mathematics K–5: 184 published benchmarks, full provenance, zero automatic
  skill mappings. Standards are reference maps and nothing else.
- `public.student_skills` and `public.student_skill_events` exist from migration
  0014 and are **empty**. STEP 5 refused to touch them on purpose. STEP 7 is the
  step that decides what they should have been.
- Local: PostgreSQL 16.13 at `/var/tmp/hos-pg`, port 5433. Managed:
  `homeschool-os-dev` (`ucgxdtulnzumrroanais`), PostgreSQL 17.6, reachable only
  through the Supabase MCP tools.
- Read `docs/architecture/16-intelligence-and-learning.md`,
  `17-child-paced-learning.md` and `18-standards-reference-layer.md` before
  writing code. They are binding.

## 1. Governing principles — inherited, non-negotiable

    Student → Skills → Evidence → Readiness → Learning Path
    Skill  → optional standards mappings

**Never reverse this arrow.** Standards do not determine what a child learns
next, their pace, their grade placement, mastery, advancement, remediation,
their weekly schedule, whether they are "behind" or "ahead", or whether the
homeschool is succeeding.

- Nestra owns the learning model. Curriculum providers supply resources.
- **AI proposes. Humans decide.**
- A parent who never once looks at a standards code must be able to use the
  entire learning system, including everything STEP 7 builds.

## 2. What STEP 7 is, and is not

**IS:** an honest, explainable picture of what a child has shown, what is still
unknown, and what might reasonably come next — built from evidence the family
already produced, plus an optional low-stakes diagnostic that helps a parent
find a starting point.

**IS NOT:** a test. Not a grade-level placement. Not a score. Not a ranking.
Not a diagnosis. Not a prediction of ability. Not a gate that must be passed
before learning may continue.

If a screen or a field would let a parent conclude "my child is behind", it is
wrong, however accurate the number behind it.

## 3. Three inherited defects — DECIDED. Migrate forward before building.

These are **product decisions, already made**. They are not open questions.
Implement them in migrations that run before anything else in STEP 7, and state
the reasoning in the migration itself.

**Scope, verified 2026-09-08 against `homeschool-os-dev` and the migrations:**
five columns carry the affected types, and every one of them holds **zero
rows**. No fixture inserts into them either.

| table | column | type | current default | rows |
|---|---|---|---|---|
| `student_skills` | `mastery_level` | `app.mastery_level` | `'not_started'` NOT NULL | 0 |
| `student_skills` | `confidence` | `app.confidence_level` | `'ai_suggested'` NOT NULL | 0 |
| `student_skill_events` | `mastery_level` | `app.mastery_level` | none, nullable | 0 |
| `student_skill_events` | `confidence` | `app.confidence_level` | none, NOT NULL | 0 |
| `assessment_results` | `confidence` | `app.confidence_level` | `'assessment_confirmed'` NOT NULL | 0 |

Two of those defaults are claims nobody made. `student_skills.confidence`
defaults to `'ai_suggested'`, so a row a **parent** inserts asserts by default
that AI suggested it. `assessment_results.confidence` defaults to
`'assessment_confirmed'`, so any assessment result asserts by default that it is
confirmed. Re-verify all five counts before migrating; if any is non-zero, stop
and report rather than guessing what the rows meant.

**3.1 `app.mastery_level` has no "unknown" — DECIDED: replace it.**
Its values are `not_started, introduced, developing, progressing, proficient,
mastered`, defaulting to `not_started`. That is a *claim about the child* where
the truth is almost always "we have no evidence yet". A profile whose default
state is a judgment will quietly tell thousands of parents their child has not
started things the child does every day.

Replace it with the state model in §4. `not_started` is retired as a state:
there is no such thing in Nestra as a child who has not started. There is only
a skill Nestra cannot yet characterize.

**3.2 `student_skills.score` (0–100) — DECIDED: retire it as a mastery
representation.** A percentage on a child is exactly the field that becomes
"your child is at 62%".

- It is retired as a representation of a child's mastery, and as the conceptual
  source of truth for anything.
- Numerical internal signals **may** exist where technically justified — for
  example an uncertainty measure used to choose the next diagnostic probe.
- Any such signal must satisfy all of: it is never rendered to a family as a
  percentage or score; it is never the source of truth for a skill state; it is
  never comparable between children; and its purpose is documented where it is
  defined. A number that cannot meet all four does not get to exist.
- The state model in §4 is the conceptual source of truth. Numbers serve it;
  they never replace it.

**3.3 `app.confidence_level` conflates three different questions — DECIDED:
split it into three.** Its values mix *who observed it* (`parent_reported`,
`teacher_observed`, `self_reported`), *how strong the observation is*
(`assessment_confirmed`), and *how the record came to exist* (`ai_suggested`).
Three independent axes flattened onto one scale — the same mistake STEP 6
corrected by separating authority, artifact kind and representation. A parent's
careful sustained observation and an AI guess must not be orderable against each
other on a single enum.

Split into three distinct concepts, each its own column:

1. **Observation authority / source** — *who or what observed this.*
   Proposed: `parent · teacher · tutor · evaluator · student_self ·
   assessment_instrument · provider_system · portfolio_artifact ·
   diagnostic_session`.
2. **Evidence confidence** — *how strong the evidence is, and nothing else.*
   **APPROVED: `preliminary · supported · corroborated`.**

   This axis describes evidence strength only. It must **not** encode who
   observed it, source authority, AI provenance, or the child's mastery state —
   those are axes 1, 3 and §4 respectively. A parent watching carefully over a
   week can reach `corroborated`; a single test item is `preliminary`. Who
   observed it does not move this axis, and this axis does not move the state.

   Enforce it: a test must show that changing only the observation authority
   leaves evidence confidence untouched, and that changing only evidence
   confidence does not by itself change a skill state.
3. **Record provenance** — *how this row came to exist.* Proposed:
   `human_entered · human_confirmed_ai_proposal · human_confirmed_system_observation · ai_proposed_unreviewed ·
   document_extraction · provider_import · system_computed`.

Hard invariant on the third axis: a row whose provenance is
`ai_proposed_unreviewed` may **never** contribute to a skill state. That is
"AI proposes, humans decide" made structural rather than procedural, and it
must be enforced by a constraint or trigger, not by convention.

Fix the two dishonest defaults while you are there: no column may default to
asserting who observed something or how the record came to exist.

## 4. The skill state model

For each (student, skill), the profile records at minimum:

- **state** — exactly four values, in this order:

      unknown → emerging → developing → secure

  This is the complete state model. Nothing else is a state. In particular
  `needs_refresh` is **not** a state — see §9. `unknown` is not a deficiency
  and must never be rendered as one.
- **evidence sufficiency** — how much we have to go on, kept *separate* from
  state. "Secure on thin evidence" and "secure on rich evidence" are different
  claims and a parent deserves to see which one they are looking at.
- **source** — what produced this state (family observation, portfolio work,
  provider progress, diagnostic response, AI proposal, parent statement).
- **strength** — how much weight that source carries. Never fold into source.
- **as_of** — states are about a moment. A state with no date is a claim about
  forever.
- **provenance** — the specific evidence rows that produced it, resolvable.

## 5. Evidence sufficiency is not skill strength

A child who has done one worksheet and a child who has done thirty are not in
the same position, even if both look "developing". Keep the two axes apart in
the schema, in the recompute, and on screen. Collapsing them is how a system
becomes confidently wrong about a child.

## 6. `unknown` means exactly one thing

**`unknown` means only that Nestra lacks sufficient evidence to characterize
the skill.** It is a statement about what Nestra knows, not about the child.

It must never imply, in data, in copy, in styling, in ordering, or in any
export, that the child:

- has not started,
- cannot do it,
- is deficient or has a gap,
- is behind,
- or needs instruction in it.

Consequences that follow from that and are not negotiable:

- `unknown` is the default for every (student, skill) pair with no evidence.
- It is never styled as red, missing, incomplete, overdue, or a gap to close.
- It never generates a prompt, badge, nag or notification framed as something
  to fix, and it never sorts to the top of a list of things needing attention.
- It may generate an **invitation** ("want to explore this?"), never a warning.
- The family-facing word for it is closer to *"not shown yet"* than *"missing"*.
- A profile that is 90% `unknown` for a newly onboarded child is **correct**,
  and the UI must make that feel normal rather than alarming.

Test the negative directly: assert that no `unknown` state produces a
deficit-framed string in either locale, and that `unknown` is never an input to
a "needs attention" surface.

## 7. Recompute must be deterministic and explainable

- Given the same evidence, the recompute produces the same states. No
  randomness, no model call in the path that decides a state.
- Every state must be reproducible from stored inputs — the recompute is a
  pure function of evidence plus explicit rules, not a black box.
- Recompute is **idempotent** and safe to re-run.
- Store the rule version that produced each state, so a later rule change is
  visible as a change rather than silently rewriting a child's history.
- An AI model may *propose* evidence interpretations upstream. It may not be
  the thing that computes state.

## 8. Parent authority is absolute

- A parent may set, correct, or clear any skill state directly.
- A parent correction **outranks** every computed state and survives recompute.
  If a recompute would overwrite a parent's judgment, the recompute is wrong.
- Corrections are recorded with who and when, and are themselves reversible.
- The system may show that it disagrees with a parent. It may not act on that
  disagreement.

## 9. `refresh_suggested` is a recommendation, not a state

Skills fade, and pretending otherwise makes a profile slowly untrue. But time
passing is not evidence about a child, and it must never be allowed to look
like it is.

**`refresh_suggested` is a separate, derived, advisory signal. It is not a
mastery state and it never appears in the state model of §4.**

**DEFAULT: OFF for newly onboarded families.** Build the capability; do not let
it fire on day one, and never let elapsed time alone produce a recommendation.

**Elapsed time is necessary but not sufficient.** A refresh suggestion requires
all three:

1. prior **`secure`** evidence — nothing below `secure` may be "refreshed",
   because refreshing something never established is just instruction framed as
   maintenance;
2. **current relevance** — the skill still matters to what this child is doing
   now;
3. elapsed time beyond the configured interval.

If a technical default interval is required, use **180 days**, and make it
configurable per family. The interval is a floor on the third condition, never
a trigger on its own.

- It is computed alongside the state, from those three conditions together.
- It **never** downgrades `secure`. A child who showed something six months ago
  is still `secure`; the signal says only that revisiting it might be
  worthwhile. If a recompute would move `secure` to a lower state because time
  passed, the recompute is wrong and must fail its test.
- It never moves any state downward, and never to `unknown`.
- It carries its own reason ("last shown in March") and is always dismissible.
- A family can turn it off entirely, and the parameters are visible and
  adjustable rather than hidden constants.
- It **never**: alters a mastery state, classifies a child as deficient, or
  enters a "needs attention" queue by itself. It is an offer, and a family that
  ignores every one of them forever is using Nestra correctly.
- Family-facing wording is *worth revisiting*, never *expired*, *stale*,
  *lapsed*, or *lost*.

Model it as its own column or its own table — not as a value that could ever be
assigned to the state column. Making it structurally impossible to store as a
state is the point.

## 10. Readiness suggestions, never locks

- Readiness is a **suggestion with reasons**, always overridable.
- Nothing in Nestra may become unavailable because a child is "not ready".
- Every suggestion must state its reasons in family language, and every reason
  must be traceable to evidence or to a prerequisite edge a human authored.
- Prerequisite edges from `import` or `ai_suggestion` are already refused by
  `app.prerequisites_are_not_imported()`. Keep it that way.

## 11. The adaptive diagnostic — purpose and framing

Purpose: help a parent find a **starting point**, quickly, without guessing.

It is optional, parent-initiated, interruptible, and repeatable. Nothing else
in Nestra may require it, reference it as missing, or nag about it. A family
that never runs it must lose no functionality.

Frame it to the parent as *"help me find where to start"* — never as
assessment, testing, placement, screening, or evaluation.

## 12. Child-safety rules for the diagnostic — hard requirements

1. **No score is ever shown to a child.** Not a number, not a percentage, not
   a bar, not a streak, not a "you got 6 of 10".
2. **No time pressure by default.** If timing exists at all it is off by
   default and never affects state.
3. **A frustration floor.** Consecutive incorrect responses must end the
   sequence early and gently. Define the threshold explicitly, make it
   adjustable, and default it low. A diagnostic that keeps going until a child
   fails repeatedly is harmful, and "adaptive" is the mechanism that makes that
   easy to build by accident.
4. **Exit at any time, without penalty**, and a partial session is still useful
   — it produces proposals for what it did see and `unknown` for the rest.
5. **Two modes:** the child responds directly, or the parent observes and
   records. Both are first-class; neither is "less valid".
6. **No wrong-answer language.** The child-facing surface never says incorrect,
   wrong, failed, or try again because you got it wrong.
7. Nothing about the diagnostic may be shared outside the family without an
   explicit, revocable, per-recipient grant.

## 13. Diagnostic mechanics

- Adaptive means: the next probe is chosen from responses so far, to reduce
  uncertainty fastest — **not** to find a ceiling, and not to keep going until
  the child fails.
- Selection may use: the skill graph, prerequisite edges, evidence already
  held, and the parent's stated interest. It may **not** use grade, age, or any
  standards code.
- The sequence must terminate: a hard cap on probes, plus the frustration
  floor, plus the parent's exit.
- Every response is stored with its probe, so any resulting proposal is
  explainable.
- **Diagnostic results are proposals.** They enter the same review path as any
  other AI proposal and require a parent decision before they become state.
  A diagnostic that writes state directly is a diagnostic that has replaced the
  parent.

## 14. No normative comparison — ever

- No percentiles. No age norms. No grade equivalents. No "typical for".
- No comparison between children, including siblings in the same family.
- No leaderboards, no cohort averages, no "students like yours".
- No aggregate that could be reversed into a ranking of one child against
  another.

This holds in the database, the API, the UI, and any export.

## 15. Standards boundary

- Standards may **annotate** a profile ("this skill relates to MA.3.FR.1.1").
- Standards may **never** be an input to state, readiness, diagnostic probe
  selection, or next-skill suggestion.
- Coverage remains information, never a target and never a completion metric.
- The default family view shows no standards at all
  (`families.standards_visibility` already exists — honour it).
- Test it: with all 184 published standards present and with the standards
  tables empty, the profile and the diagnostic must produce **identical**
  results. Prove this, do not assert it.

## 16. Family-facing language

Follow the table in `17-child-paced-learning.md`. Non-negotiable substitutions:

| never | instead |
|---|---|
| behind / ahead | *not shown yet* / *already comfortable* |
| grade level | *where they are working* |
| mastery | *what they've shown* |
| gap / deficiency | *worth revisiting* |
| failed / incorrect | *not yet* |
| test / assessment | *a few questions to find a starting point* |
| not started | *not shown yet* — see §6, this is about Nestra, not the child |
| expired / stale / lapsed | *worth revisiting* |
| 62% / score / level | there is no family-facing equivalent — see §3.2 |

`scripts/check-family-language.mjs` already enforces part of this. Extend it to
cover every new string STEP 7 introduces, in **both** `en-US` and `es-US`.

## 17. Schema requirements, and the migration of §3

- Forward-only migrations, continuing from 0080.
- The §3 decisions land **first**, in their own migrations, before any new
  profile table exists. Building the profile and then fixing the enums
  underneath it is how the old semantics survive in a new table.
- **DECIDED: reshape `student_skills` and `student_skill_events` IN PLACE.**
  Both are empty. Do not create parallel, superseded or `_v2` tables — one
  canonical lineage, or the next person inherits two tables and a trap.
  - Drop the obsolete columns explicitly (`score`, and the old `mastery_level`
    and `confidence` columns as they are replaced). No dead columns left behind.
  - Drop the retired enums (`app.mastery_level`, `app.confidence_level`) once no
    column uses them. An enum nobody dropped is an enum somebody will use.
  - **Add the retired semantics to `app.assert_schema_invariants()`**, following
    the precedent of migration 0072, which forbids `framework`, `framework_ref`,
    `standard`, `standard_id`, `standard_ref`, `standard_code` and
    `standards_code` from ever reappearing on `public.skills` by checking
    `pg_attribute`. Do the same on the profile tables for `score`,
    `mastery_level`, `percent`, `percentage` and `grade_level`. A decision that
    lives only in a document is a decision that comes back.
- **Migrating must not invent knowledge about a child.** All five affected
  columns currently hold zero rows, so the honest migration is structural. But
  write it as though rows existed, because one day they will:
  - No old `mastery_level` value may be mapped to a *higher* new state than the
    evidence supports. `not_started` maps to `unknown` — never to `emerging`,
    because "we were told nothing" is not "the child is beginning".
  - No old `confidence_level` value may be split into all three new axes by
    guessing the two it never carried. `parent_reported` tells you the source;
    it tells you nothing about confidence or provenance, and those must migrate
    to an explicit unknown rather than to a plausible-looking default.
  - Where the old value cannot answer a new question, the new column records
    that it does not know. Refuse to fill it in.
- If any of the five columns is non-zero at migration time, **stop and report**.
  Do not migrate rows whose meaning you inferred.
- Every new table has RLS enabled and explicit policies. No table without a
  policy — 0074 shipped a readable, unwritable table and nobody noticed.
- `app.assert_schema_invariants()` must pass after every migration.
- Definer functions pin `set search_path = ''`.
- Anything a family reads must be nullable-friendly: no NOT NULL column that
  forces a claim about a child in order to insert a row.

## 18. RLS, privacy and data minimisation

Diagnostic responses are a child's answers to questions. Treat them as the most
sensitive rows in the system.

- Strict family scoping. Prove no cross-family read is possible, adversarially.
- Evaluator access: only through the existing evaluator grant path, only what
  the grant covers, and never raw diagnostic responses unless explicitly shared.
- A student-role account may see its own profile only if the family enables it,
  and never a comparison.
- Deletion must be real: removing a child's diagnostic history must remove the
  responses, not just hide them.
- No service-role key in any path a family action can reach.

## 19. AI boundary

The engine may use: prerequisites · confirmed evidence · diagnostic responses ·
readiness · historical difficulty · pace · interests · parent goals · learning
modality.

It may not use: standards · grade · age · normative data · any comparison to
another child.

Every AI output is a **proposal** carrying its reasoning and its inputs. No
proposal becomes state without a human decision. Confidence values are not
permission — a proposal at 0.99 approves nothing.

## 20. Explainability: "why do you think that?"

Every state, every readiness suggestion, and every diagnostic proposal must
answer that question with the actual evidence that produced it, in family
language, without jargon, and with links to the underlying work.

If a state cannot be explained, it must not be shown.

## 21. Reversibility

- Every computed state can be cleared without deleting the evidence under it.
- Every parent correction can be undone.
- A full recompute from evidence must be possible at any time and must
  reproduce the same states, except where a parent has overridden them.
- Nothing STEP 7 writes may be irreversible from the family's side.

## 22. Testing

- Unit tests for the recompute: determinism, idempotence, and every state
  transition including the ones that must **not** happen (decay never demotes;
  standards never influence; recompute never overwrites a parent).
- RLS suite: a new numbered file in `tests/rls/`, owning everything it creates,
  mutating no seeded row. Cross-family isolation proved adversarially.
- Diagnostic tests: frustration floor fires; hard cap terminates; partial
  session yields partial proposals; no probe selection reads grade, age or
  standards; results never write state directly.
- The identical-results test from §15, run both ways.
- **Migration regression tests for §3, written against synthetic pre-migration
  rows — not against the empty tables.** A migration test run on zero rows
  proves nothing and passes for the wrong reason; that is precisely the vacuous
  test §23.3 forbids. Insert rows carrying every old `mastery_level` and every
  old `confidence_level` value, migrate, and assert:
  - `not_started` became `unknown`, and no row moved to a state above what its
    evidence supports;
  - no new axis was populated with a value the old enum could not have carried;
  - unanswerable axes came out explicitly unknown rather than defaulted;
  - no row gained a claim about a child that did not exist before the migration.
- A test that `refresh_suggested` cannot be written into the state column at
  all — attempt it and assert the database refuses.
- A test that a row with provenance `ai_proposed_unreviewed` cannot contribute
  to a state.
- Family-language guard extended to all new strings, both locales.
- E2E at desktop / tablet / mobile.
- No test may pass by doing nothing — assert the precondition before asserting
  the behaviour.

## 23. Process protections earned in STEP 6 — apply them from the start

1. **Never tune logic to force an expected number.** When a count is off,
   find the cause. STEP 6's parser returned 183 instead of 184; the fix was a
   nesting bug, not a threshold.
2. **Prove every guard fires.** Deliberately break the thing the guard exists
   to catch and watch it refuse. An untested guard is decoration.
3. **A test that passes because it did nothing is a failing test.** Assert that
   the row was visible before asserting that the update was refused.
4. **Postgres folds constant expressions at plan time.** `CASE WHEN ok THEN 'x'
   ELSE 1/0 END` fires whichever branch is taken. Use `raise exception`.
5. **Parity digests must exclude lifecycle columns.** A digest containing
   `status` changes when rows move `staged → published`, making two healthy
   deployments look like corrupted copies of each other.
6. **Own what you create in tests.** Never delete or mutate a seeded row to
   prove a cascade. That destroyed real managed data once.
7. **Verify derived claims with a second, independent implementation** where
   the claim matters. One extractor's output is not evidence.
8. **Report refusals as refusals**, never as empty successes.
9. Forward-only migrations. Local first, then managed, then compare.

## 24. Local and managed deployment

- Apply locally, run the full suite, then apply to `homeschool-os-dev`.
- Compare the two with a **content digest that excludes lifecycle columns**.
- Every managed statement runs as a real signed-in user under RLS. Verify
  `current_user = authenticated` and `is_superuser = off` rather than assuming.
- Record the deployment in `supabase/imports/DEPLOYMENT.md` style: both sides,
  every count, the digest, and what the digest does and does not cover.

## 25. Do NOT build

- Grade-level placement, or any "your child is at grade N" output.
- Percentiles, norms, grade equivalents, cohort comparison.
- Any score shown to a child.
- Any child-facing mastery percentage, for a child or for a parent.
- Any numeric signal that is the conceptual source of truth for a skill state.
- `needs_refresh`, or any other value, as a fifth state.
- Automatic skill↔standard mapping.
- Standards-driven next-skill selection.
- A diagnostic that is required, gated, timed by default, or that continues
  through repeated failure.
- Any state written by AI without a human decision.
- Any irreversible record about a child.
- Predictions of future ability, aptitude, or potential.
- Any export that could be reversed into a ranking.

## 26. Final report

Return a numbered report covering: the three inherited defects and the
migration that implemented each decision, including the pre-migration row counts
you re-verified · the state model · recompute determinism evidence ·
parent-override proof · decay behaviour · readiness · diagnostic safety rules
with the test that proves each · the standards-independence result from §15 ·
RLS and privacy proofs · family language · local and managed counts and the
content digest · defects found and fixed · what was deliberately not built.

End with exactly one of:

    STEP 7 PASS — STUDENT SKILL PROFILE + ADAPTIVE DIAGNOSTIC COMPLETE
    STOP — STEP 7 NOT COMPLETE

## 27. Consistency review against the existing schema (2026-09-08)

Every decision is resolved. What follows is what a reshape in place actually
touches — verified against the migrations and `homeschool-os-dev`, not assumed.
**Read this before writing the first migration.**

**Safe — no change needed:**

- **RLS policies do not reference the reshaped columns.** Every policy on
  `student_skills` and `student_skill_events` keys on `student_id` through
  `app.my_student_ids_for(...)` and `app.can_student_action(...)`. Dropping
  `score`, `mastery_level` and `confidence` breaks no policy. Re-run the RLS
  suite anyway, but do not expect to rewrite policies.
- **No application code reads or writes mastery.** The only occurrences in
  `src/` are two comments explaining that STEP 5 deliberately does not write it.
  There is no UI, action or type to migrate.

**Must be handled — these will break or silently rot:**

- **`app.attach_history('public.student_skills')`** (migration 0028) attaches
  record history to the table. Verify it after the reshape and confirm it
  captures the new columns rather than the retired ones.
- **`student_skills_review_idx` is on `(student_id, mastery_level)`** — an index
  on a column being replaced. Drop and recreate it against the new state column.
- **`student_skill_events` keeps history natively** (per 0028). That is
  compatible with the new model and should be preserved: the events table is the
  immutable record, `student_skills` the current state. Do not make it mutable.
- **`student_skills.ai_suggestion_id`** (FK added in 0019) is the existing link
  to the AI proposal layer, and the natural anchor for `record_provenance`.
  Reconcile the two rather than adding a second parallel mechanism.

**Existing tests the reshape will break — update them, do not delete them:**

- `tests/rls/02_invariants.sql:14,21` inserts `mastery_level, confidence, score`
  directly. Rewrite against the new columns.
- `tests/rls/02_invariants.sql:167–175` proves `student_skill_events` is
  append-only by attempting `update ... set score = 99` and requiring a refusal.
  **`score` is the column being retired**, so the append-only guarantee needs a
  new column to test against. Losing this test would silently drop an
  append-only guarantee — re-point it and assert it still refuses.
- `tests/rls/09_step5_learning.sql:335–337` counts rows in both tables to prove
  STEP 5 never writes mastery. That assertion still matters: STEP 7 writes state
  through its own reviewed path, never as a side effect of evidence capture.
  Keep it, adapted.
- `tests/rls/06_privilege_escalation.sql` references `'student_skills'` as a
  table-name string in audit and permission tests. Confirm it still resolves.

**STEP 6 invariants that must still hold afterwards — re-run, do not assume:**

- `app.prerequisites_are_not_imported()` still refuses `import` and
  `ai_suggestion` prerequisite edges.
- `app.is_standards_admin()` remains the only write path to standards, and
  reading the catalogue still does not confer it.
- The 184 published benchmarks, locators and provenance untouched: content
  digest `b0c0d24c365da8ac39524aa30640d229`.
- `skill_standards` and imported prerequisites remain at zero after every STEP 7
  migration and every recompute.
- The retired-column invariant from 0072 still fires on `public.skills`.
- The §15 standards-independence test passes in both directions.

## 28. Stop conditions

STOP and report rather than proceeding if:

- the recompute cannot be made deterministic;
- a parent override cannot be made to survive recompute;
- the standards-independence test in §15 does not produce identical results;
- cross-family isolation cannot be proved;
- the diagnostic cannot be made to terminate safely under the frustration floor;
- any inherited defect in §3 cannot be resolved without breaking existing data;
- any of the five columns in §3 holds rows at migration time whose meaning
  cannot be established without guessing.

Do not begin STEP 8.
