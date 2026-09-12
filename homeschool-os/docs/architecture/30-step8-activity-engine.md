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
   provider are still active;
3. if the caller explicitly required a language, it satisfies it — material
   whose language nobody stated does **not** satisfy an explicit requirement,
   because "we don't know" is not Spanish;
4. nothing else. Not grade, not age, not a standard, not a benchmark.

**Ordered** — §8's list, minus the criteria the data model does not represent:

| key | |
|---|---|
| 1 | material the family is actually enrolled in (`status = 'active'`) |
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

## What Phase 1 deliberately does not build

No Today dashboard, no daily scheduling, no automatic replanning, no mastery
from completion, no evidence extraction from completion, no adaptive difficulty,
no preference-learning, no AI-generated curriculum, no mass lesson generation,
no recommendation feed.

`app.learning_resource_reason` carries `parent_provider_preference` for a
preference the data model does not yet represent. It is never emitted.
