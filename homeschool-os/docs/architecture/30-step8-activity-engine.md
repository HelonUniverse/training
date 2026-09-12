# STEP 8 Phase 1 — the Learning Activity & Resource engine

**Migrations 0103–0107** · `tests/rls/19_step8_activity.sql`, 143 assertion call
sites · Built and verified locally. **Not yet deployed to managed** — see the
decision gate at the end.

STEP 7 answers *what would be reasonable for this child to explore next*. This
layer begins answering *what can she actually do* — and the entire risk of it is
one sentence:

> the moment a resource becomes the unit of learning, the provider's table of
> contents becomes the child's education.

So the skill is the model and the resource is one way to reach it. A skill
survives its resource disappearing. A family with no curriculum at all has a
complete system, because "use the measuring cups in the kitchen" is a
first-class activity here and not a degraded one.

## The two tables

`learning_activities` has `skill_id NOT NULL` and `resource_id` nullable. That
asymmetry is the architecture in two lines.

`learning_activity_events` is append-only. A parent's decision to swap a
worksheet for a walk, or to put a morning off, is a fact about her week that the
next selection does not get to erase.

The catalogue (`learning_resources`, in production since STEP 5) grows
provider, external id, activity kind, modality, language, duration,
availability, content ownership, integration mode and a licence note. Every one
of those is a fact somebody can state, not a score somebody would have to
invent.

## Selection is an ORDER BY

No model chooses what a child does. `app.learning_activity_candidates` is a
filter and a sort.

**Eligible** — all four must hold:

1. a person has **confirmed** that this material teaches this skill;
2. it can be opened today (`availability = 'available'`) and its course and
   provider are still active. Availability has **two different defaults on
   purpose**: the column was *added* as `available`, which back-fills every row
   that predates STEP 8 — retroactively inventing a restriction would have
   silently removed material families are using today — and the default was then
   changed to `unknown`, which every row written since gets. `unknown` means
   nobody has established availability. It is **not** unavailable, nothing may
   present it as though it were, and it is simply not eligible for automatic
   selection;
3. if the caller explicitly required a language, it satisfies it — material
   whose language nobody stated does **not** satisfy an explicit requirement,
   because "we don't know" is not Spanish;
4. nothing else. Not grade, not age, not a standard, not a benchmark.

**Ordered** — §8's list, minus the criteria the data model does not represent:

| key | |
|---|---|
| 1 | material the family is actually enrolled in — `status = 'active'`, and *only* active. A course finished, paused or dropped is a fact about last year. Migration 0106a aligns STEP 7's `app.path_resource_for` to the same definition, forward, without touching the deployed 0099; an invariant now refuses either selector preferring an enrolment it does not require to be active |
| 2 | parent provider preference — **not represented. Skipped, not invented.** |
| 3 | modality, only when the caller asked for one explicitly |
| 4 | kind, **as text** |
| 5 | title |
| 6 | id |

Key 4 sorts on the *text* of the kind rather than the enum position, so nobody
can read a pedagogical ranking into the order the labels were declared in. A
tiebreak is supposed to be arbitrary and stable; it is not supposed to be a
quiet opinion about whether a video beats a worksheet.

Key 3 fires only on an explicit request. There is no stored "this child is a
hands-on learner", and the language guard now refuses that sentence in the
family catalogs in both languages.

## No eligible resource is an answer

`app.learning_activity_select_resource` returns

```json
{"resource_available": false,
 "reason": "no_eligible_confirmed_resource",
 "considered": {"confirmed_mappings": 1, "awaiting_confirmation": 0,
                "blocked_by_availability": 1, "blocked_by_inactive_home": 0}}
```

It does not widen the filter, walk down the skill graph, reach for an
unconfirmed mapping, or touch the path. Nothing is written. The difference
between *there is nothing for this skill* and *there are two and the
subscription lapsed* is the difference between a dead end and a five-minute fix,
and the family is told which one she is looking at.

## `human_created` may carry a resource

What separates `human_created` from `human_selected` is **who composed the
activity**, not whether a resource is attached.

* `human_selected` — a person picked a catalogue resource, and *that* is the
  activity. `la_human_selected_names_its_resource_ck` requires one.
* `human_created` — a person **authored** it: "practise with the measuring cups,
  then watch this video". A catalogue resource may support it.
  `la_authored_activity_is_not_a_selection_ck` requires that such a row carry no
  rule version and no engine reasons, so attaching a video can never make her
  sentence look like something an ordering produced.

Every attachment freezes a `resource_snapshot` — title, provider, ownership,
licence note, availability — so that "why was my daughter doing this in March"
survives the provider renaming or withdrawing the content.

## The lifecycle is a graph, not a free-for-all

```
proposed   -> selected available skipped not_today replaced archived
selected   -> available started skipped not_today replaced archived
available  -> selected started skipped not_today replaced archived
started    -> completed skipped not_today replaced archived
not_today  -> selected available started replaced archived
skipped    -> selected available started replaced archived
completed  -> archived
replaced   -> (nothing)
archived   -> (nothing)
```

Flexible where a homeschool week is flexible, firm where the record has to stay
true. `skipped` and `not_today` reopen freely — a week that went sideways on
Tuesday and came back on Thursday is an ordinary week, and a lifecycle that made
her create a second row to say so would teach her to work around the product.
`completed` does not reopen: doing something again is a **new activity with
lineage**, never an edit that removes a morning that happened.

Refusals are structured, never an opaque constraint name:

```json
{"moved": false, "from": "completed", "to": "started",
 "reason": "a_completed_activity_is_not_undone",
 "allowed_next": ["archived"], "evidence_created": false}
```

The RPCs check the graph and hand that back; `la_history_is_not_rewritten`
enforces the same graph on the row, so a future code path cannot reach the wrong
place by a different route. All 72 ordered pairs are tested against the matrix
as written down, not against the function's own opinion of itself.

## Provenance: five sentences, not one flag

`deterministic_system_selection` · `human_selected` · `human_created` ·
`provider_imported` · `ai_proposed_unreviewed`

A deterministic `ORDER BY` is not a model, and labelling it AI would
misrepresent the one column somebody would read to find out how a child came to
be doing this. `la_provenance_matches_origin_ck` makes origin and
`record_provenance` unable to disagree; a trigger makes neither editable after
the fact.

## What is refused, and where

| refusal | enforced by |
|---|---|
| reading the standards catalogue | invariant (1), proved by G1 |
| reading grade or age | invariant (2), G2 |
| writing to the profile | invariant (3), G3 |
| naming a child's computed state | invariant (3b), G4 |
| evidence pointing back at an activity | invariant (4), G10 |
| selecting on an unconfirmed mapping | invariant (5), G5 — and behaviourally, test 3 |
| rewriting the learning path | invariant (6), G6 |
| the **path** reading availability | invariant (7), G7 |
| an activity on a goal target, chosen by the system | trigger + invariant (8), G8, N1 |
| a failure label anywhere in the lifecycle | invariant (9), G9 |
| history being rewritten (completed → started, and the rest) | invariant (9b) + trigger, D25–D28 |
| two definitions of "the curriculum this family is using" | invariant (alignment), F7 |
| a score on an activity | invariant (10), G11 |
| moving the skill an activity is for | trigger, N2 |
| rewriting where an activity came from | trigger, N3 |

The G-tests write the exact violation, check that
`app.assert_schema_invariants()` refuses it, and roll the damage back. Their
match patterns are drawn only from the invariant's own message, so a dead guard
fails the test instead of passing it by accident.

## The seed is deliberately full of holes

Eight demo resources, every one `is_demo`, `nestra_owned`, licence-noted and
titled `Demo:`. And:

* **`NST.FR.4` has nothing at all** — the most important row in the file is the
  one that is not there. It is what proves a skill survives having no material.
* **`NST.FR.2`'s material is behind a lapsed subscription** — so "nothing
  exists" and "something exists and is out of reach" can be told apart.
* **`NST.FR.1`'s mapping is unreviewed** — good material, unconfirmed claim.
* **Nothing is confirmed.** Every mapping ships `confirmed = false`, because
  nobody confirmed them; they are a seed. Inventing a confirming person to make
  seed data authoritative is the precise lie this schema exists to refuse — and
  a pre-confirmed seed would mean deploying this migration silently started
  choosing material for real children. The tests confirm what they need, as a
  named fixture guardian, which exercises the whole "a person decides" loop
  rather than assuming its outcome.

## Independence, proved rather than asserted

* **Standards**: `public.standards`, `skill_standards` and `standards_texts` are
  renamed out from under the running selector inside a rolled-back transaction.
  Byte-identical selection (test 26). Mappings added and removed: identical
  (27).
* **Grade and age**: Lucas is moved from grade 5 to grade 1, then to grade 12
  with a 2004 birthday. Byte-identical selection (28, 29).

## Managed

Deployed as `step8_activity_resource_schema`, `step8_activity_engine`,
`step8_activity_rpcs`, `step8_activity_demo_resources`,
`step8_path_active_enrollment_alignment` and `step8_activity_invariants`.

13 of 14 schema digests match local exactly, including
`canonical_function_bodies`. Every STEP 7 and STEP 8 function body matches
byte-for-byte, `app.assert_schema_invariants()` included. The one raw-body
difference is `public.log_activity`, a STEP 4 function on the documented
pre-existing comment-drift list in `23-deferred-hygiene.md`.

A 27-line behavioural probe returns line-for-line identical output on both
databases, and an authenticated RLS probe confirms cross-family isolation under
real policies. Both roll back completely.

## What Phase 1 deliberately does not build

No Today dashboard, no daily scheduling, no automatic replanning, no mastery
from completion, no evidence extraction from completion, no adaptive difficulty,
no preference-learning, no AI-generated curriculum, no mass lesson generation,
no recommendation feed.

`app.learning_resource_reason` carries `parent_provider_preference` for a
preference the data model does not yet represent. It is never emitted.
