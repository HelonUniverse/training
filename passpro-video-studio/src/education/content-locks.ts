// Content Lock model + validator (PassPro education layer).
//
// Rules:
// - Only VERIFIED locks are authoritative. A claim that matches a VERIFIED
//   lock with a different value is a CONTENT CONFLICT (blocks generation).
// - A claim matching an UNVERIFIED or STALE lock needs human review: it is
//   never treated as confirmed.
// - A lock itself in CONFLICT status blocks any clip that touches it.
// - A number with a known unit that matches no lock is an UNLOCKED claim and
//   needs review (the creative layer may not invent numbers).
// - The validator NEVER rewrites text. It only reports.

import type { Clip, ValidationIssue } from '../core/types.ts';
import { findNumericMentions, normalizeText, type NumericMention, type NumericUnit } from './numbers-es.ts';

export type LockStatus = 'UNVERIFIED' | 'VERIFIED' | 'STALE' | 'CONFLICT';

export interface ContentLock {
  id: string;
  scope_key: string;
  exam_id: string | null;
  concept: string;
  statement: string;
  value_numeric: number | null;
  value_text: string | null;
  unit: NumericUnit | string | null;
  jurisdiction: string | null;
  effective_date: string | null;
  verified_date: string | null;
  verified_by: string | null;
  source_name: string | null;
  source_url: string | null;
  source_reference: string | null;
  verification_status: LockStatus;
  match_rules: { require_any?: string[]; forbid_any?: string[]; forbidden_variants?: string[] };
}

export function isAuthoritative(l: ContentLock): boolean {
  return l.verification_status === 'VERIFIED' && Boolean(l.source_name && l.verified_date && l.verified_by);
}

const rx = (patterns: string[] = []) => patterns.map((p) => new RegExp(normalizeText(p), 'i'));

function sentenceAround(norm: string, m: NumericMention): string {
  const before = norm.slice(0, m.start);
  const after = norm.slice(m.end);
  const s = Math.max(before.lastIndexOf('.'), before.lastIndexOf('?'), before.lastIndexOf('!'), before.lastIndexOf('\n'));
  const eIdx = after.search(/[.?!\n]/);
  return norm.slice(s + 1, eIdx === -1 ? norm.length : m.end + eIdx);
}

function lockMatches(lock: ContentLock, sentence: string): boolean {
  const req = rx(lock.match_rules.require_any);
  const forb = rx(lock.match_rules.forbid_any);
  if (forb.some((r) => r.test(sentence))) return false;
  return req.length === 0 || req.some((r) => r.test(sentence));
}

export interface TextLocation {
  where: string;
  clip_id?: string;
}

export function validateTextAgainstLocks(text: string, locks: ContentLock[], loc: TextLocation): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const norm = normalizeText(text).replace(/por\s+ciento/g, 'porciento');
  const base = { source: 'content-lock', clip_id: loc.clip_id } as const;

  for (const m of findNumericMentions(text)) {
    const sentence = sentenceAround(norm, m);
    const sameUnit = locks.filter((l) => l.unit === m.unit && l.value_numeric !== null);
    let matched = sameUnit.filter((l) => lockMatches(l, sentence));
    if (!matched.length) {
      // Unqualified mention ("40 preguntas"): accept only an exact VERIFIED value match.
      const exact = sameUnit.filter((l) => isAuthoritative(l) && l.value_numeric === m.value);
      if (exact.length === 1) matched = exact;
    }
    if (!matched.length) {
      issues.push({
        ...base,
        code: 'UNLOCKED_NUMERIC_CLAIM',
        severity: 'review',
        message: `${loc.where}: "${m.text}" is a numeric claim with no matching Content Lock. Add/verify a lock or confirm it is not an educational fact.`,
        found: m.text,
      });
      continue;
    }
    for (const lock of matched) {
      const found = `${m.text} (= ${m.value} ${m.unit})`;
      if (lock.verification_status === 'CONFLICT') {
        issues.push({ ...base, code: 'LOCK_IN_CONFLICT', severity: 'conflict', lock_id: lock.id, found,
          message: `${loc.where}: "${m.text}" touches "${lock.concept}", whose Content Lock is itself marked CONFLICT. Resolve the source first.` });
      } else if (!isAuthoritative(lock)) {
        issues.push({ ...base, code: lock.verification_status === 'STALE' ? 'STALE_FACT' : 'UNVERIFIED_FACT', severity: 'review',
          lock_id: lock.id, found, expected: `${lock.value_numeric} ${lock.unit} (${lock.verification_status})`,
          message: `${loc.where}: "${m.text}" relies on "${lock.concept}", which is ${lock.verification_status}. It cannot be used as authoritative until verified.` });
      } else if (Math.abs((lock.value_numeric ?? NaN) - m.value) > 1e-9) {
        issues.push({ ...base, code: 'CONTENT_CONFLICT', severity: 'conflict', lock_id: lock.id, found,
          expected: `${lock.value_numeric} ${lock.unit}`,
          message: `⚠ CONTENT CONFLICT — ${loc.where}: script says "${m.text}" but the verified lock "${lock.concept}" is ${lock.value_numeric} ${lock.unit} (source: ${lock.source_name}). Not corrected automatically.` });
      } else {
        issues.push({ ...base, code: 'FACT_CONFIRMED', severity: 'info', lock_id: lock.id, found,
          message: `${loc.where}: "${m.text}" matches verified lock "${lock.concept}".` });
      }
    }
  }

  for (const lock of locks)
    for (const v of lock.match_rules.forbidden_variants ?? [])
      if (norm.includes(normalizeText(v)))
        issues.push({ ...base, code: 'CONTENT_CONFLICT', severity: 'conflict', lock_id: lock.id, found: v,
          expected: lock.value_text ?? lock.statement,
          message: `⚠ CONTENT CONFLICT — ${loc.where}: "${v}" contradicts locked term "${lock.concept}" (${lock.value_text ?? lock.statement}).` });

  return issues;
}

export function validateClipAgainstLocks(clip: Clip, locks: ContentLock[]): ValidationIssue[] {
  const out: ValidationIssue[] = [];
  clip.dialogue.forEach((d) => {
    out.push(...validateTextAgainstLocks(d.text, locks, { where: `clip ${clip.ord}, ${d.speaker_label} (script line ${d.source_line})`, clip_id: clip.id }));
  });
  out.push(...validateTextAgainstLocks(clip.action, locks, { where: `clip ${clip.ord} action`, clip_id: clip.id }));
  if (clip.visual_prompt !== clip.action)
    out.push(...validateTextAgainstLocks(clip.visual_prompt, locks, { where: `clip ${clip.ord} visual prompt`, clip_id: clip.id }));
  return out;
}

/** VERIFIED facts relevant to a clip: those whose unit the clip actually mentions. */
export function relevantVerifiedLocks(clip: Clip, locks: ContentLock[]): ContentLock[] {
  const text = [...clip.dialogue.map((d) => d.text), clip.action, clip.visual_prompt].join('\n');
  const units = new Set<string>(findNumericMentions(text).map((m) => m.unit));
  return locks.filter((l) => isAuthoritative(l) && l.unit !== null && units.has(l.unit));
}
