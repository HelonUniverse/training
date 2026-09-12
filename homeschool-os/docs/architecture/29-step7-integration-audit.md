# STEP 7 final integration audit

**Date:** 2026-09-12 · **Suite:** `tests/rls/18_step7_integration.sql`, 147 assertion
call sites · Run on **local and managed**.

No product functionality was added. One test-harness defect and one audit-check
defect were found and fixed; no defect was found in the product.

## The scenario

One child, one branch, one deliberately mixed profile — built from real evidence
through the real recompute, never by writing a state into a column:

| skill | how it got there |
|---|---|
| `NST.FR.1` | two observations, then a parent confirmed `secure` |
| `NST.FR.2` | two observations, two sources, two dates → `developing` |
| `NST.FR.3` | two adults who saw different things → conflict preserved |
| `NST.FR.4` | an unreviewed AI proposal → still `unknown` |
| `NST.FR.5` | nothing at all → no row |

## What the lifecycle actually did

```
profile NST.FR.1 secure/supported n=2 decided=t
profile NST.FR.2 developing/supported n=2 decided=f
profile NST.FR.3 developing/supported n=2 decided=f
profile NST.FR.4 unknown/none n=0 decided=f
profile NST.FR.5 unknown/none n=0 decided=f
diag opens NST.FR.4
diag route NST.FR.4/explore_next_skill/skipped | NST.FR.4/uncertainty_probe/not_today
           | NST.FR.4/uncertainty_probe/demonstrated
diag stop  no_items_available
confirmed  computed=emerging effective=emerging
path steps 1.NST.FR.4/diagnostic_frontier | 2.NST.FR.5/continue_connected_skill
path goals (none)
```

Read it as a sentence: the diagnostic skipped everything the profile could
already speak to and opened exactly where Nestra's knowledge ran out; a skip and
a "not today" changed nothing; one demonstration, confirmed by her, became
evidence and moved `NST.FR.4` to `emerging`; and the path then opened at that
same boundary. **Identical on both databases.**

And the composition that matters most: when the same scenario carries a parent
goal on `NST.FR.5`, her review is what promotes it. Before the confirmation the
goal is a `goal_target` with two uncharacterized skills beneath it; after it,
`NST.FR.5` is the actionable first step. Evidence → readiness → path, with a
person in the middle.

## Independence, over the whole pipeline

Not "the path ignores standards" — the entire chain, compared character for
character:

| arm | result |
|---|---|
| 184 standards present | baseline |
| catalogue renamed out from under the running code | **identical** |
| every branch skill mapped to a benchmark | **identical** |
| every mapping removed | **identical** |
| grade 11, born 2015 | **identical** |

Profile, diagnostic opening skill, route, stop reason, the confirmed
observation's effect, path steps, goal targets, prerequisite-support decisions
and resource selection — all of it.

## The eight loops, all proven absent

`path membership → evidence` · `path approval → evidence` ·
`path completion → mastery` · `unreviewed diagnostic → knowledge` ·
`refresh advisory → downgrade` · `standard mapping → readiness` ·
`resource existence → candidate` · `goal target → assumed readiness`

Structurally as well as behaviourally: no foreign key runs from any evidence
table into a learning path or the standards catalogue, and
`generate + approve + complete` leaves the events table byte-for-byte where it
was.

## Security

Diego is a real guardian — of a different child. Every STEP 7 surface returns
zero for him: profile rows, evidence, overrides, refresh decisions, diagnostic
sessions, session items, observations, routing decisions, paths, nodes, events.
Naming a row by its id returns nothing. Joining through the tables he *is*
allowed to read — the shared item bank, the skill graph, shared resources —
returns only his own child's rows.

A refusal for a real path and a refusal for an invented uuid are the **same
string**, so the error text carries no signal about whether the row exists.

## Explainability and reconstruction

Three structured explanations, none needing prose: `explain_student_skill`
(reason codes, cited evidence ids, the sufficiency counts),
`explain_diagnostic_session` (starting context, the skip decision, a reason on
every question) and `explain_learning_path` (readiness reasons, prerequisites
considered, frozen generation inputs). Afterwards, everything reconstructs:
evidence, the named human decision, the session and its route, her review, path
v1 exactly as she approved it, her own edit, and v2 pointing at what it came
from.

## Defects

**None in the product.** Two in the audit itself, both fixed:

1. Assertion 7m compared an approved path against a snapshot taken *before the
   parent's own edits*, so it failed for the right reason stated wrongly. The
   guarantee is that **regeneration** does not rewrite her version — not that
   her version never changes. She may edit it freely; what may not happen is
   Nestra editing it for her.
2. Check 16b flagged the table comment "there is no remediation staircase" — the
   schema documenting the promise it keeps. Negations are now excluded, and a
   companion test asserts the check still catches a comment that *asserts* the
   claim. This is the third instance of that shape in STEP 7 (`vencido` in
   Phase 4, `nivel de dominio` in Phase 6); the rule each time is the same: ban
   the claim, not the word.

One reading needed care rather than a fix: on managed, an earlier probe showed
Diego's joins returning non-zero counts. A follow-up scoped probe established
they were **his own child's rows**, created by that probe in the same
transaction — Lucas's rows are 0 through every join and every id lookup.
