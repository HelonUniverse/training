# STEP 7 phase 5 — the adaptive diagnostic

Migrations 0092–0095.

## What it answers

*What does Nestra have useful evidence about, and where would it be reasonable
to explore next?* It does not answer what grade a child is at, and it
structurally cannot: 0095 refuses any routing function whose source reads the
standards catalogue, `grade_level`, `grade_equivalent`, `grade_band`,
`normalized_grade`, `date_of_birth` or `birthdate`.

## The slice

Five connected fraction skills from the STEP 5 graph, with `NST.FR.5` depending
on both `FR.3` and `FR.4` so the branch is a real DAG rather than a line, plus
two reading skills that exist only so a test can prove a hard afternoon with
fractions leaves reading untouched. 19 seed items, across four modalities.

## The four rules

**Where it starts.** The branch is the root plus everything downstream, ranked by
*longest* path from the root so a skill always sorts after all its
prerequisites. A skill is **established** when the profile already says something
useful: effective state `developing` or `secure`, on at least `supported`
evidence. The **frontier** is the skills that are not established but whose
in-branch prerequisites all are. The session opens at the shallowest of those,
tie-broken on skill code.

That is the rule that stops a child being asked about addition because of her
age. If multiplication is established, addition sits behind the frontier and is
never presented.

**Where it goes next.** Two demonstrated observations of a skill move to the next
connected skill. There is no score to push higher, so a third correct answer
buys nothing and costs a child's afternoon.

**The frustration floor.** Two consecutive `not_demonstrated` observations
anywhere in the branch stop it escalating. At most **one** prerequisite probe
follows, then the session ends. No downward staircase.

**Skip and not-today are not failures.** They do not touch the consecutive
counter, cannot reach the floor, and write nothing.

## The loop that is not allowed to exist

Observations steer the rest of their own session and are written **nowhere else**.
The diagnostic never inserts into `student_skills` or `student_skill_events` from
its routing path; only `confirm_diagnostic_observation`, driven by a person,
creates an evidence event — `evidence_source = 'diagnostic_session'`,
`record_provenance = 'human_confirmed_ai_proposal'`. So the engine cannot read
back its own unreviewed guess as established evidence and grow more confident
from it. Test 13 asserts that two demonstrated observations produce zero evidence
rows and zero profile rows.

## Success and failure are recorded, not inferred

`app.diagnostic_outcome` is supplied by the human who watched. Nestra never
decides whether a child demonstrated something — it records that somebody said
so, and routes on it. This removes the largest subjective decision in the phase
rather than resolving it.

## Sessions

`diagnostic_sessions` stores the student, the initiating human, the branch root,
timestamps, status, **the rule version**, the starting profile context, and the
stop reason. Items, observations and routing decisions are append-only; an
observation accepts UPDATE only so a person can review it, and a trigger refuses
any change to what was actually seen.

A paused session carries the rule version it was routed under. If the engine has
moved on, `resume_diagnostic_session` returns `resumed: false`,
`reason: rule_version_changed` and leaves the session exactly as it was. It never
re-routes the remainder under new rules, because a session that is half one
algorithm and half another cannot be explained afterwards.

## Security

Everything `SECURITY INVOKER`; **no new definer function**. Starting needs
`skill:create`, driving needs `skill:update`, reading needs `skill:read` — so a
view-only guardian may watch a session and may not stop it, and another family
cannot see that a session exists.

## The prerequisite probe — approved 2026-09-11

After the floor, at most **one** probe, targeting a **direct** prerequisite of
the floored skill that:

- was **not observed during this session** — a prerequisite she demonstrated
  twenty minutes ago is not re-asked, because that is the repetition the floor
  exists to prevent; and
- is **not human-confirmed secure** — a parent's standing judgement is not
  re-opened because the next skill up went badly.

Ties between equally-near prerequisites break on skill code. Nothing eligible
means no probe at all and the branch simply ends. Direct only, so there is no
recursive descent, and the probe's own outcome cannot trigger a second one. The
result creates an observation and does exactly nothing else — it lowers no state.

Seven tests (7A–7G) cover each arm: established-and-unseen, demonstrated this
session, human-confirmed secure, two eligible prerequisites, a probe that itself
goes badly, a floored skill with no prerequisites, and a confirmed `secure` that
stays exactly where the parent left it.

This replaces the unreachable rule the first build shipped with: the frontier
guarantees every in-branch prerequisite is already established, so "probe an
unestablished prerequisite" could never fire, and the first smoke run produced no
probe at all.
