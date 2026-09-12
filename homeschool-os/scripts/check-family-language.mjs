#!/usr/bin/env node
/**
 * Nestra is child-paced. Standards are optional reference maps.
 *
 * The failure mode this guards against is not a bad decision - it is drift. One
 * plausible string ("On track", "Behind") added months from now by someone who
 * never read docs/architecture/17-child-paced-learning.md, and the product is
 * quietly telling a homeschool parent their child is failing against a map the
 * family never agreed to be measured by.
 *
 * So the rule lives here, where the build can fail, instead of only in prose.
 *
 * Scope is deliberately the SHIPPED CATALOGS, not the source. Copy is what a
 * parent reads; a variable called `isBehind` is a naming problem, not this one.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const LOCALES = ['en-US', 'es-US'];

/**
 * Each entry is a phrase that makes a claim about a child's standing against an
 * external framework. Wording that describes OUR RECORDS is fine and absent
 * here on purpose: "no learning evidence is linked to this reference" says what
 * we hold, not what the child is.
 *
 * A third element narrows an entry to matching KEYS. Most of these words are a
 * deficit claim wherever they appear, but a few are only a deficit claim when
 * they are about a child: an invitation that is `Vencida` has genuinely
 * expired, and saying so is correct. Banning the word outright failed on
 * exactly that string, so the ambiguous ones are scoped to the copy where the
 * subject is a child rather than a token.
 */
const BANNED = [
  // English
  [/\brequired standard\b/i,            'a standard is a reference, never a requirement'],
  [/\bmust complete\b/i,                'nothing in a child-paced product must be completed by a date'],
  [/\bgrade[- ]level requirement\b/i,   'grade level is context, not a box'],
  [/\bshould already know\b/i,          'states a deficit from a map the family never chose'],
  [/\bbehind (standard|grade)\b/i,      'a coverage gap is not a deficiency'],
  [/\bon track for\b/i,                 'implies a schedule the child is being measured against'],
  [/\bfalling behind\b/i,               'same'],
  [/\bcatch up\b/i,                     'same'],
  [/\bbelow grade\b/i,                  'same'],
  [/\boff[- ]grade\b/i,                 'asynchronous development across subjects is normal'],
  // STEP 7 phase 4. A revisit suggestion is the single most likely place for a
  // deficit claim to appear, because the feature is genuinely about something
  // fading - and the honest version of that sentence is about OUR RECORDS
  // ("you haven't captured recent evidence"), never about the child
  // ("your child is forgetting this").
  [/\bforgetting\b/i,                   'a gap in our records is not a claim about how a child remembers'],
  [/\b(skill|mastery) (has )?declined\b/i, 'nothing declined; we simply have not seen it lately'],
  [/\bno longer secure\b/i,             '`secure` stays `secure` while a revisit is suggested'],
  [/\bneeds? remediation\b/i,           'a revisit is an invitation, not a treatment plan'],
  [/\boverdue\b/i,                      'an interval elapsing is not a deadline missed', /^(refresh|activity)\./],
  [/\bregress(ed|ion|ing)\b/i,          'Nestra never asserts a child went backwards'],
  [/\bolvidando\b/i,                    'a gap in our records is not a claim about how a child remembers'],
  [/\bha disminuido\b/i,                'nothing declined; we simply have not seen it lately'],
  [/\bya no (es|est[áa]) seguro\b/i,    '`secure` stays `secure` while a revisit is suggested'],
  [/\bvencid[oa]\b/i,                   'an interval elapsing is not a deadline missed', /^(refresh|activity)\./],
  // STEP 7 phase 5. A diagnostic is where grade level tries hardest to come
  // back, because the whole genre it resembles is built on it. An item is never
  // a grade's item, a child is never too old or too young for one, and an
  // observation that did not demonstrate something is never a failure.
  [/\b(\d+(st|nd|rd|th)|first|second|third|fourth|fifth)[- ]grade (question|item|level)\b/i,
                                        'an item belongs to a skill, never to a grade'],
  [/\byou should know this\b/i,         'nobody owes a skill by a date'],
  [/\btoo easy for your age\b/i,        'age is not a claim about what a child finds easy'],
  [/\b(you |she |he )?failed\b/i,       'an observation that did not demonstrate a skill is not a failure'],
  [/\bdeficien(t|cy)\b/i,               'Nestra describes what it can support, never what is missing from a child'],
  [/\bplacement (test|level|grade)\b/i, 'this is not a placement test and must never be described as one'],
  [/\bdemasiado f[áa]cil para (tu|su) edad\b/i, 'age is not a claim about what a child finds easy'],
  [/\bya deber[ií]as saber\b/i,         'nobody owes a skill by a date'],
  [/\breprob[óo]\b/i,                   'an observation that did not demonstrate a skill is not a failure'],
  [/\bdeficien(te|cia)\b/i,             'Nestra describes what it can support, never what is missing from a child'],
  // STEP 7 phase 6. A learning path is where school sneaks back in, because a
  // list of what to do next looks exactly like a syllabus. The forbidden
  // sentences are the ones that turn a suggestion into a verdict: they compare
  // the child to a schedule she never chose, or describe the plan as owed work
  // rather than as an invitation.
  [/\bnext grade\b/i,                  'a path follows this child, not a grade sequence'],
  [/\bon grade level\b/i,              'there is no grade level in a child-paced path'],
  [/\bexpected for (age|grade)\b/i,    'nothing here is expected of a child by a date'],
  [/\bscope and sequence\b/i,          'a suggestion is not a syllabus a family owes'],
  [/\byear[- ]?long plan\b/i,          'the path answers what to explore next, not what a year looks like'],
  [/\bassigned to (your child|her|him)\b/i, 'Nestra proposes; it never assigns'],
  [/\brequired (next step|lesson|path)\b/i, 'a proposal a parent can reject is not required'],
  [/\bmissing skills?\b/i,             'an absence of evidence is not a missing skill'],
  [/\bknowledge gaps?\b/i,             'a gap in our records is not a gap in a child'],
  [/\breadiness score\b/i,             'readiness is a set of reasons, never a number'],
  // Key-scoped, for the same reason `overdue` is. The catalogs already use
  // "mastery level" to DENY one - "nothing here is a grade or a mastery level" -
  // and banning the phrase outright would delete the sentence that makes the
  // promise. What must not happen is a path CLAIMING one, so the rule watches
  // the path keys.
  [/\bmastery (level|percent)/i,        'a child is not a percentage', /^path\./],
  [/\bpr[óo]ximo grado\b/i,            'a path follows this child, not a grade sequence'],
  [/\ben el nivel de (su )?grado\b/i,  'there is no grade level in a child-paced path'],
  [/\besperado para (la edad|el grado)\b/i, 'nothing here is expected of a child by a date'],
  [/\bdestrezas? faltantes?\b/i,       'an absence of evidence is not a missing skill'],
  [/\bvac[íi]os? de conocimiento\b/i,  'a gap in our records is not a gap in a child'],
  [/\bnivel de dominio\b/i,            'a child is not a percentage', /^path\./],
  [/\basignad[oa] a (tu|su) (hija|hijo)\b/i, 'Nestra proposes; it never assigns'],
  // STEP 8 phase 1. Two different ways this layer turns into school. The first
  // is homework: an activity that is owed, late, or failed, when the honest
  // sentence is that a morning went differently than planned. The second is
  // quieter and worse - a claim about WHO THE CHILD IS. "She's a visual
  // learner" is a diagnosis the evidence for does not exist, and once the copy
  // says it, every future feature routes around it: the girl labelled at seven
  // gets videos at eleven because a sentence said so. Modality describes the
  // ACTIVITY. It never describes her.
  [/\bvisual learner\b/i,               'modality describes an activity, never a child'],
  [/\b(auditory|kinesthetic|hands[- ]on|tactile) learner\b/i,
                                        'modality describes an activity, never a child'],
  [/\blearning style\b/i,               'Nestra does not assign a child a permanent style'],
  [/\brequired activity\b/i,            'Nestra proposes an activity; a family is never required to do one'],
  [/\bassignment (is )?required\b/i,    'Nestra proposes; it never assigns required work'],
  [/\bassigned (activity|work|lesson)\b/i, 'Nestra proposes; it never assigns'],
  // Key-scoped, for the same reason `overdue` and `vencido` are: a required
  // FORM FIELD is genuinely required, and `common.required` = "Obligatorio" is
  // a correct label on an input. What must never happen is an ACTIVITY being
  // described as obligatory, so the rule watches the copy where the subject is
  // a child's work rather than a text box. Ban the claim, not the word.
  [/\bmandatory\b/i,                    'nothing a family does with their own child is mandatory here',
                                        /^(activity|path)\./],
  [/\bremediation\b/i,                  'a different way in is not a treatment plan'],
  [/\bfailed (the |this )?(activity|lesson|worksheet)\b/i,
                                        'an activity that did not happen is not a failure'],
  [/\bincomplete work\b/i,              'a morning that went differently is not a debt'],
  [/\bmissed (activit|lesson|work)/i,    'a skipped activity is not a mark against anyone'],
  [/\b(you |she |he )?must (do|finish|complete) (this|it)\b/i,
                                        'a suggestion a parent can decline is not an obligation'],
  [/\baprendiz (visual|auditiv[oa]|kinest[ée]sic[oa])\b/i,
                                        'modality describes an activity, never a child'],
  [/\bestilo de aprendizaje\b/i,        'Nestra does not assign a child a permanent style'],
  [/\bactividad (obligatoria|requerida)\b/i,
                                        'Nestra proposes an activity; a family is never required to do one'],
  [/\b(tarea|actividad) asignada\b/i,   'Nestra proposes; it never assigns'],
  [/\bobligatori[oa]\b/i,               'nothing a family does with their own child is mandatory here',
                                        /^(activity|path)\./],
  [/\bremediaci[óo]n\b/i,               'a different way in is not a treatment plan'],
  [/\btrabajo incompleto\b/i,           'a morning that went differently is not a debt'],
  // Spanish - the same claims, which is the point of checking both catalogs
  [/\best[áa]ndar requerido\b/i,        'a standard is a reference, never a requirement'],
  [/\bdebe completar\b/i,               'nothing must be completed by a date'],
  [/\bpor debajo del (grado|nivel)\b/i, 'a coverage gap is not a deficiency'],
  [/\batrasad[oa]\b/i,                  'states a deficit about a child'],
  [/\bponerse al d[ií]a\b/i,            'same'],
  [/\bya deber[ií]a saber\b/i,          'states a deficit from a map the family never chose'],
];

function flatten(object, prefix = '') {
  const out = [];
  for (const [k, v] of Object.entries(object)) {
    if (v && typeof v === 'object' && !Array.isArray(v)) out.push(...flatten(v, `${prefix}${k}.`));
    else out.push([`${prefix}${k}`, String(v)]);
  }
  return out;
}

/**
 * A key-scoped rule can die silently: narrow the scope a little too far and the
 * pattern stops matching anything, the build stays green, and the sentence it
 * was written to prevent walks straight in. That has already happened once in
 * this file.
 *
 * So every scoped rule carries a specimen - a key INSIDE its scope and a string
 * it must flag. These are not real catalog entries; they exist only to prove
 * the rule is still alive.
 */
const MUST_BE_FLAGGED = [
  ['refresh.probe',  'This revisit is overdue'],
  ['activity.probe', 'This activity is overdue'],
  ['refresh.probe',  'Esta revisión está vencida'],
  ['activity.probe', 'Esta actividad está vencida'],
  ['path.probe',     'Her mastery level is 72%'],
  ['path.probe',     'Su nivel de dominio es 72%'],
  ['activity.probe', 'This activity is mandatory'],
  ['activity.probe', 'Esta actividad es obligatoria'],
];

function flag(key, value) {
  for (const [pattern, , keyScope] of BANNED) {
    if (keyScope && !keyScope.test(key)) continue;
    if (pattern.test(value)) return true;
  }
  return false;
}

const dead = MUST_BE_FLAGGED.filter(([key, value]) => !flag(key, value));
if (dead.length > 0) {
  console.error('A guard in this file no longer catches what it was written for:\n');
  for (const [key, value] of dead) console.error(`  ${key}  "${value}"`);
  console.error('\nA rule that flags nothing is a comment. Widen its key scope or fix its pattern.');
  process.exit(1);
}

const problems = [];
for (const locale of LOCALES) {
  const catalog = JSON.parse(readFileSync(join(ROOT, 'messages', `${locale}.json`), 'utf8'));
  for (const [key, value] of flatten(catalog)) {
    for (const [pattern, why, keyScope] of BANNED) {
      if (keyScope && !keyScope.test(key)) continue;
      if (pattern.test(value)) problems.push({ locale, key, value, why });
    }
  }
}

if (problems.length > 0) {
  console.error('Family-facing language that measures a child against a standard:\n');
  for (const p of problems) {
    console.error(`  ${p.locale}  ${p.key}`);
    console.error(`    "${p.value}"`);
    console.error(`    ${p.why}\n`);
  }
  console.error('See docs/architecture/17-child-paced-learning.md.');
  console.error('If a regulatory feature genuinely needs this wording, it does not');
  console.error('belong in the family catalogs - raise it rather than widening this list.');
  process.exit(1);
}

console.log(`family language: ok (${LOCALES.length} catalogs, ${MUST_BE_FLAGGED.length} live-guard probes)`);
