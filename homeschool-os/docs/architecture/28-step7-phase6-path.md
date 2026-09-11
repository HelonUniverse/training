# STEP 7 Phase 6 — the adaptive Learning Path

**Status:** the eight product decisions were reviewed and returned with
refinements; those are applied, and 0098-0102 are **deployed to managed**.

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

Seven sources, unioned, reduced to one row per skill keeping the strongest
reason and the union of readiness reasons:

`parent_goal` · `revisit_requested` · `active_plan_priority` ·
`diagnostic_frontier` · `uncertain_boundary` · `continue_connected_skill`
(including the branch root, which has nothing before it) · `enrichment`

**Owning a worksheet is not one of them.** `curriculum_resource_available` was a
source in the first build and was removed on review: a resource existing in the
database must never by itself put a skill in a child's path, because that is a
content catalogue deciding what she learns next. The order is choose a skill,
work out readiness, *then* attach material if any exists. The enum label
survives for a resource-led choice a person makes; the engine never emits it.

Ordered by reason, then depth in the graph, then skill code. Three total orders,
no score.

**Reachability.** A candidate *Nestra* chose whose direct prerequisites are
uncharacterized is not a reasonable next step. The first smoke test produced a
path opening at "compare fractions" for a child with no fraction evidence at all,
purely because that skill had a demo worksheet attached. So: two or more unmet
direct prerequisites → skipped; exactly one → carried by **one** support node;
never two, never recursive.

**A person's goal is kept, not promoted.** The first build let a named skill
bypass reachability entirely, on the reasoning that the parent is the authority.
She is - over what the family is working toward. It was never a claim that her
daughter is ready this week, and the bypass turned it into one: Nestra proposed
"compare fractions" as the next step for a child with no evidence under it.

So readiness applies to everyone. A named skill that fails it becomes a **goal
target**: on the path, named, visible, and explicitly not the next step.

| | |
|---|---|
| `node_kind = 'actionable'` | a reasonable next step, given the evidence |
| `node_kind = 'goal_target'` | where the family is heading |

`explain_learning_path` returns them as two arrays, never one list with a flag,
because a caller that has to filter will one day forget to. Goal targets do not
consume the horizon: the horizon bounds what a family is asked to *do*, and
capping where they are heading would be Nestra deciding how many things a mother
is allowed to want. She can still place a goal first herself - `add_path_node`
and `reorder_path_node` allow it and hand back the structured warning.

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

## Resources: eligibility before selection

**Only a mapping a person has confirmed may attach automatically.** An
unconfirmed mapping is a guess about what a worksheet teaches, and attaching one
would put unreviewed machine judgement into a child's plan through the back door
- the thing Phase 3 refuses for evidence and Phase 5 refuses for routing.

Among eligible confirmed mappings: material the family is enrolled in, then kind,
then title, then id. A parent modality preference would sit second; the data
model does not represent one, so the criterion is skipped rather than invented.

The two demo resources are `is_demo`, titled `Demo:`, and their mappings are
`confirmed = false` - so they never auto-attach. That is the point: "no resource
available yet" is a valid and honest result, and a seed that recommended itself
would be Nestra quietly promoting its own test content.

## Horizon

Default 4, maximum 5, and 3-5 is a target range rather than a floor. When only
one or two steps are reasonable, the path is one or two steps long. Nothing is
padded, no enrichment is conjured, no prerequisite is added and nothing confirmed
is retaught to reach three.

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

**133 assertion call sites** after the refinement round, including the A-J
matrix: a goal with nothing missing under it, with one thing missing, with two
things missing, forced forward by hand, a resource that cannot create a
candidate, an unconfirmed mapping that cannot attach, a confirmed one that can,
a two-candidate path that stays two long, a revisit of a confirmed skill, and an
advisory that inserts nothing.

Local: 17 SQL suites PASS · migration regression PASS (22 migrations over legacy
rows) · typecheck, lint clean · 821 i18n keys both locales · family-language
guard extended with 17 new phrases, each proved to fire.

## Deployed

0098-0102 applied to `homeschool-os-dev`. All 28 Phase 6 function bodies are
**byte-identical** on both databases; 13 of 14 digest rows match, including
`canonical_function_bodies 173 / b661f40b…` and `enum_labels 755 / 2bcc3881…`.
The parity probe - six path shapes, both independence arms, resource
eligibility, the feedback-loop check, versioning and two RLS probes - is
identical line for line. `rls_digest` and `step6_digest` unchanged; standards
184; profile rows, events and path rows all 0 afterwards.
