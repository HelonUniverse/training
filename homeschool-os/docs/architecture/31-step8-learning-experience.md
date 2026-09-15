# STEP 8 Phase 2 — the learning experience

**Migrations 0109–0113** · `tests/rls/20_step8_experience.sql`, 172 assertion
call sites · Built and verified locally. **Not deployed to managed** — four
decisions are waiting at the gate.

Phase 1 answered *what could support this skill*. This is the layer where a
nine-year-old opens it, works for eleven minutes, gets interrupted, comes back
on Thursday and finishes — and her mother takes a photo of the page.

The failure mode here is quieter than in any previous phase, because crossing
the line feels like being helpful:

```
she finished the worksheet     ->  she knows equivalent fractions
she uploaded a photo           ->  that is evidence
the session lasted 40 minutes  ->  she must have learned something
it was in Today and she did it ->  mark it off
```

Every one of those is refused structurally.

## Today has no table

Today is a `SELECT` over the learning path, the activities, and the handful of
explicit decisions a person made about today. There is no daily-plan table,
because a product with a plan *and* a schedule has two records that disagree
within a year and no way to say which is true.

The only things `today_decisions` holds are the three that cannot be derived:
**pinned**, **hidden**, **chosen for today**. One row per activity per day.
Being in Today is never evidence, and invariant (6) refuses any profile column
that could point at a Today decision.

Order — every key a fact somebody stated:

| | |
|---|---|
| 1 | she pinned it for today |
| 2 | it is already open — finish what was started |
| 3 | a step on the path she approved, in her order |
| 4 | she chose it or wrote it herself |
| 5 | somebody asked to come back to this skill |
| 6 | the activity's creation time, then its id |

No due date exists anywhere in the file. Nothing can be late.

## An activity is the thing; a session is a morning

`learning_activity_sessions` is what makes repeated work honest. She starts on
Tuesday, stops when the baby wakes, resumes Thursday, finishes. Tuesday stays on
the record.

* One open session per activity (`las_one_open_session_idx`), so "is she working
  on this" has an answer.
* An ended session is not reopened, re-outcomed, or moved in time
  (`las_occasions_are_not_rewritten`). Doing it again is a **new session**.
* `duration_minutes` is **reported, never derived**. A session left open
  overnight did not take fourteen hours, and invariant (8) refuses any function
  here that touches `epoch`, `age()` or `justify_interval`. Null means nobody
  knows, which is the ordinary case for a walk.
* The outcome vocabulary is exactly the six labels specified, and invariant (9)
  pins it. There is no `failed`, and no `due_on`.

## Resource launch, said honestly

`nestra_hosted · external_link · provider_integrated · offline ·
no_digital_resource`

An external link is described to the family as *"a link to somebody else's site.
It isn't part of Nestra, and Nestra doesn't see what happens there."*
`provider_integrated` is reachable only where a provider genuinely reports one —
nothing does.

An activity with `resource_id = NULL` returns `no_digital_resource` and carries
the instructions a person wrote instead. Section 29–31 runs a kitchen activity
end to end: Today → start → pause → resume → note → photo → finish → evidence
offer, with no resource at any point.

## The evidence bridge

```
activity -> session -> artifact -> OFFER -> a person answers
                                              |
                                    accepted  v
                                    public.confirm_skill_evidence  (STEP 5)
                                              |
                                              v
                                    learning_evidence   <- and it stops here
```

An offer is a question. It creates nothing. Accepting calls the STEP 5 function
that has recorded *"this work RELATES to this skill"* since September, and stops
— it does **not** write `student_skills` or `student_skill_events`. Invariant (7)
refuses `accept_evidence_proposal` ever writing `learning_evidence` itself, so
the confirmation rules cannot be bypassed by a caller who did not know they
existed.

Declining is kept, with the reason, so a family is not asked the same thing
forever.

Deciding is an `approve`, not an `update`: a tutor may run the week; only a
guardian with full access decides what enters the evidence record.

## Artifacts store nothing

`learning_activity_artifacts` points at `documents` and `portfolio_items`. The
scan gate, the sharing rules and the retention policy that protect a child's
work all live there already, and a second file store would mean a second place
to get them wrong.

## A child may run her own morning without running her own curriculum

That sentence is why `learning_activity` is a new resource type rather than a
widening of `learning_plan`. A child gets `read` and `update`: open, start,
pause, resume, note, finish. She does **not** get `create` (choosing her own
curriculum), `delete`, or `approve` (deciding what counts as evidence about
herself) — and invariant (11) refuses those three ever appearing for
`student_self`.

## What is refused, and where

| refusal | enforced by |
|---|---|
| reading the standards catalogue | invariant (1), G1 |
| reading grade or age | invariant (2), G2 |
| writing to the profile | invariant (3), G3 |
| naming a child's computed state | invariant (3b), G4 |
| rewriting the learning path | invariant (5), G5 |
| evidence pointing at a session | invariant (6), G6 |
| the profile pointing at Today membership | invariant (6), G7 |
| bypassing `confirm_skill_evidence` | invariant (7), G8 |
| deriving a duration from the clock | invariant (8), G9 |
| removing the session guard | invariant (10), G10 |
| a due date on a morning | invariant (9), G11 |
| a child approving evidence about herself | invariant (11), G12 |
| rewriting an ended session | trigger, N1–N3 |
| an ended session with no outcome or actor | constraint, N4 |
| an accepted offer with no evidence behind it | constraint, N5 |

## Two defects the tests found in Phase 1

1. **`open_activity_resource` silently overwrote its own launch description.**
   `jsonb ||` lets the right-hand side win, so adding a second `note` key
   replaced the sentence telling the family whose page they were about to open.
   The no-evidence statement moved to `evidence_note`.
2. **The event log could not be read back in order.** Every row written inside
   one transaction shared a `created_at`, because `now()` is the transaction's
   start time. A morning where a child opened, started, paused, resumed,
   attached and finished came back ordered by random uuid. `created_at` now
   defaults to `clock_timestamp()` and the log carries a `seq`. An audit trail
   that cannot be read in order is not an audit trail.

Both fixed forward in `0110a`, which also widens two Phase 1 policies and the
Phase 1 transition function so a child can write her own morning into her own
history. All three are widenings; nobody who could write before loses anything.
