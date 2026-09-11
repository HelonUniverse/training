# STEP 7 Phase 6 — the adaptive Learning Path

**Status:** built locally, all gates green, **stopped before managed** at the §31
gate. The decisions listed at the end are the reason.

`Student → Skills → Evidence → Readiness → Learning Path`. This is the last
arrow, and it is where an education product usually turns back into a school.

## Migrations

| # | file | what |
|---|---|---|
| 0098 | `20260912010000_learning_path_schema.sql` | enums, three tables, RLS |
| 0099 | `20260912010100_learning_path_engine.sql` | candidates, readiness, resources |
| 0100 | `20260912010200_learning_path_rpcs.sql` | generate, decide, edit, regenerate |
| 0101 | `20260912010300_learning_path_demo_resources.sql` | two demo resources, marked |
| 0102 | `20260912010400_learning_path_invariants.sql` | five structural guards + two triggers |

## The model

`learning_paths` — one row per version. `version`, `supersedes_id`, `status`
(`proposed → approved → paused → archived`, or `rejected`), `rule_version`,
`node_horizon`, and `generation_inputs`: everything the engine looked at, frozen,
so "why did it suggest this?" is answerable two years later without re-deriving a
profile that has moved on.

`learning_path_nodes` — the four inputs kept in **four columns, never one
number**:

| column | question it answers |
|---|---|
| `evidence_context` | what Nestra knows about the child |
| `reason_code` + `reason_detail` | what the family wants to explore |
| `prerequisites_considered` | what skills logically connect |
| `resource_id` / `resource_note` | what material is available |

`learning_path_events` — append-only. Every human decision, kept, because
regeneration reads it.

## Candidate generation

Eight sources, unioned, reduced to one row per skill keeping the strongest
reason and the union of readiness reasons:

`parent_goal` · `revisit_requested` · `active_plan_priority` ·
`diagnostic_frontier` · `uncertain_boundary` · `continue_connected_skill`
(including the branch root, which has nothing before it) ·
`curriculum_resource_available` · `enrichment`

Ordered by reason, then depth in the graph, then skill code. Three total orders,
no score.

**Reachability.** A candidate *Nestra* chose whose direct prerequisites are
uncharacterized is not a reasonable next step. The first smoke test produced a
path opening at "compare fractions" for a child with no fraction evidence at all,
purely because that skill had a demo worksheet attached. So: two or more unmet
direct prerequisites → skipped; exactly one → carried by **one** support node;
never two, never recursive.

**A person is exempt.** A skill named by a goal, a plan priority or a revisit
request is never skipped for reachability. A parent saying "this term we are
working on comparing fractions" is not making a readiness claim Nestra gets to
veto. Found by the test asking whether a parent's goal survives the engine.

## Readiness

A set of reasons, never a number: what the prerequisites look like, whether there
is evidence, where the uncertainty is, who named it, whether a person has already
confirmed it. `app.path_readiness` builds it from the graph and the stored
profile. There is no percentage, no rank, and no global level, and 0102 refuses
a column or a function that would introduce one.

`app.path_skill_context` reads the **stored** profile rather than recomputing.
A recompute would be a second opinion running beside Phase 3's, and the moment
the two disagreed the path would be reasoning from something other than what the
parent sees on her own screen — and the stored row is where her override lives.

## What it will not do

Nothing in the path engine writes to `student_skills`, `student_skill_events` or
`student_skill_overrides`. Generating creates no evidence. Approving creates no
evidence. `complete_path_node` records that a family did the work and returns
`evidence_created: false` in so many words. Evidence is created by the evidence
architecture, by a person who looked at what the child actually did.

## Security

A path is a `learning_plan` in the capability matrix, so the existing rules
decide. Reading follows `my_student_ids_for('learning_plan','read')`; creating
and editing need `create`/`update`; **approving needs `approve`, which only
`guardian_full` holds**. A tutor with `staff_assigned_write` can help build a
path and cannot ratify it.

## Structural invariants (0102)

1. The path may not read the standards catalogue.
2. Nor grade or age.
3. Nor write to the profile — with **no exception at all**, unlike Phase 5's one.
4. Evidence may not point back at a path: the FK that would make "it was on her
   plan" into a reason to believe something cannot exist.
5. An approved path is not rewritten in place — two triggers plus the live-path
   index and the approval constraints, checked by name.

Seven negative tests (G1–G7) break each guard and assert the invariants refuse
it. The regexes were checked directly for the Phase 5 escaped-backslash mistake
before being trusted.

## Tests

`tests/rls/17_step7_path.sql` — **102 assertion call sites** covering the full
40-item matrix: determinism, the four standards arms, grade and age, the three
no-evidence rules, one-level support, the horizon, parent edit/remove/reorder
with warnings, versioning and reconstruction, family isolation, approval
authority, refresh vs revisit, conflicting evidence, human override, no scores,
no automatic secure, resource presence and absence, and demo-resource provenance.

Local: 17 SQL suites PASS · migration regression PASS (22 migrations over legacy
rows) · typecheck, lint clean · 821 i18n keys both locales · family-language
guard extended with 17 new phrases, each proved to fire.
