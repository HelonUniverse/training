// Parses a production script into scenes and beats WITHOUT rewriting it.
// Dialogue text is kept verbatim (only surrounding whitespace and one pair of
// wrapping quotes are removed). Accepted conventions:
//
//   ESCENA 1 — EXTERIOR, CASA DE DOÑA PÓLIZA      scene heading (also SCENE/EXT./INT./#)
//   DOÑA PÓLIZA: ¿Tú también vienes por el examen?  dialogue
//   DOÑA PÓLIZA (susurrando): Ven acá.            dialogue with delivery note
//   DOÑA PÓLIZA                                  screenplay-style dialogue block
//   (entra con una bandeja)                        …delivery / action
//   ¿Tú también vienes…?
//   [Doña Póliza entra con pastelillos.]           action
//   [CÁMARA: primer plano]                         camera direction
//   ---  or  [CORTE]                               forced clip break

import type { Character } from '../types.ts';
import { normalizeName } from '../util.ts';

export type Beat =
  | { kind: 'dialogue'; speaker_label: string; character_id: string | null; text: string; delivery?: string; source_line: number }
  | { kind: 'action'; text: string; source_line: number }
  | { kind: 'camera'; text: string; source_line: number }
  | { kind: 'break'; source_line: number };

export interface ParsedScene {
  heading: string;
  source_line: number;
  beats: Beat[];
}

export interface ParseWarning {
  code: 'UNKNOWN_SPEAKER' | 'CONTENT_BEFORE_FIRST_SCENE' | 'EMPTY_SCENE' | 'NO_SCENES';
  message: string;
  source_line: number;
}

export interface ParsedScript {
  title: string | null;
  scenes: ParsedScene[];
  warnings: ParseWarning[];
}

const SCENE_RE = /^(?:#{1,6}\s*)?(?:\*\*)?\s*(ESCENA|SCENE|EXT\.?|INT\.?|EXTERIOR|INTERIOR)\b/i;
const BREAK_RE = /^(?:-{3,}|\[\s*(?:CORTE|CUT)(?:\s+(?:A|TO))?\s*[.:]?\s*\])$/i;
const CAMERA_RE = /^[\[(]\s*(?:C[AÁ]MARA|CAMERA|PLANO|SHOT)\s*[:\-–—]\s*(.+?)\s*[\])]$/i;
const BRACKET_ACTION_RE = /^\[(.+)\]$/s;
const PAREN_LINE_RE = /^\((.+)\)$/s;
const STAR_ACTION_RE = /^\*(?!\*)(.+)\*$/s;
const INLINE_SPEAKER_RE = /^(?:\*\*)?([^:*\[\]()]{1,40}?)(?:\*\*)?\s*(?:\(([^)]*)\))?\s*(?:\*\*)?\s*:\s*(.+)$/s;
const LEADING_PAREN_RE = /^\(([^)]*)\)\s*(.+)$/s;

function stripWrappingQuotes(s: string): string {
  const t = s.trim();
  const pairs: [string, string][] = [['"', '"'], ['“', '”'], ['«', '»']];
  for (const [a, b] of pairs) if (t.length > 1 && t.startsWith(a) && t.endsWith(b)) return t.slice(1, -1).trim();
  return t;
}

function isUpperish(s: string): boolean {
  const letters = s.replace(/[^\p{L}]/gu, '');
  return letters.length >= 2 && letters === letters.toUpperCase() && !/\d/.test(s) && s.trim().split(/\s+/).length <= 5;
}

export class CharacterIndex {
  private map = new Map<string, Character>();
  constructor(characters: Character[]) {
    for (const c of characters) {
      for (const n of [c.name, c.slug.replace(/-/g, ' '), ...c.aliases]) {
        const k = normalizeName(n);
        if (k) this.map.set(k, c);
      }
    }
  }
  find(label: string): Character | null {
    return this.map.get(normalizeName(label)) ?? null;
  }
  /** Characters whose name/alias appears as whole words in free text. */
  mentionedIn(text: string): Character[] {
    const t = ` ${normalizeName(text)} `;
    const found = new Map<string, Character>();
    for (const [k, c] of this.map) if (k.length > 2 && t.includes(` ${k} `)) found.set(c.id, c);
    return [...found.values()];
  }
}

export function parseScript(script: string, characters: Character[]): ParsedScript {
  const idx = new CharacterIndex(characters);
  const lines = script.replace(/\r\n?/g, '\n').split('\n');
  const scenes: ParsedScene[] = [];
  const warnings: ParseWarning[] = [];
  let title: string | null = null;
  let current: ParsedScene | null = null;
  let blockSpeaker: { label: string; id: string | null; delivery?: string } | null = null;

  const ensureScene = (lineNo: number): ParsedScene => {
    if (!current) {
      warnings.push({ code: 'CONTENT_BEFORE_FIRST_SCENE', message: 'Content before the first scene heading was placed in an implicit scene.', source_line: lineNo });
      current = { heading: '', source_line: lineNo, beats: [] };
      scenes.push(current);
    }
    return current;
  };
  const pushDialogue = (label: string, id: string | null, raw: string, lineNo: number, delivery?: string) => {
    let text = raw.trim();
    const lead = LEADING_PAREN_RE.exec(text);
    if (lead) {
      delivery = [delivery, lead[1].trim()].filter(Boolean).join('; ');
      text = lead[2];
    }
    text = stripWrappingQuotes(text);
    if (!text) return;
    if (!id) warnings.push({ code: 'UNKNOWN_SPEAKER', message: `Speaker "${label}" is not in the character bible.`, source_line: lineNo });
    ensureScene(lineNo).beats.push({ kind: 'dialogue', speaker_label: label, character_id: id, text, delivery: delivery || undefined, source_line: lineNo });
  };

  lines.forEach((rawLine, i) => {
    const lineNo = i + 1;
    const line = rawLine.trim();
    if (!line) {
      blockSpeaker = null;
      return;
    }

    if (SCENE_RE.test(line)) {
      blockSpeaker = null;
      current = { heading: line.replace(/^#+\s*/, '').replace(/\*\*/g, '').trim(), source_line: lineNo, beats: [] };
      scenes.push(current);
      return;
    }
    if (!current && !title && /^#\s+/.test(line)) {
      title = line.replace(/^#+\s*/, '').trim();
      return;
    }
    if (BREAK_RE.test(line)) {
      blockSpeaker = null;
      ensureScene(lineNo).beats.push({ kind: 'break', source_line: lineNo });
      return;
    }
    const cam = CAMERA_RE.exec(line);
    if (cam) {
      ensureScene(lineNo).beats.push({ kind: 'camera', text: cam[1].trim(), source_line: lineNo });
      return;
    }

    // Screenplay block continuation
    if (blockSpeaker) {
      const paren = PAREN_LINE_RE.exec(line);
      if (paren) {
        blockSpeaker.delivery = [blockSpeaker.delivery, paren[1].trim()].filter(Boolean).join('; ');
        return;
      }
      pushDialogue(blockSpeaker.label, blockSpeaker.id, line, lineNo, blockSpeaker.delivery);
      blockSpeaker.delivery = undefined;
      return;
    }

    const bracket = BRACKET_ACTION_RE.exec(line) ?? STAR_ACTION_RE.exec(line) ?? PAREN_LINE_RE.exec(line);
    if (bracket) {
      ensureScene(lineNo).beats.push({ kind: 'action', text: bracket[1].trim(), source_line: lineNo });
      return;
    }

    // Screenplay-style: a line that is just a known character name (+ optional parenthetical)
    const nameOnly = /^(?:\*\*)?([^:()*]{1,40}?)(?:\*\*)?\s*(?:\(([^)]*)\))?$/.exec(line);
    if (nameOnly) {
      const who = idx.find(nameOnly[1]);
      if (who && isUpperish(nameOnly[1])) {
        blockSpeaker = { label: nameOnly[1].trim(), id: who.id, delivery: nameOnly[2]?.trim() };
        return;
      }
    }

    const inline = INLINE_SPEAKER_RE.exec(line);
    if (inline) {
      const label = inline[1].trim();
      const who = idx.find(label);
      if (who || isUpperish(label)) {
        pushDialogue(label, who?.id ?? null, inline[3], lineNo, inline[2]?.trim());
        return;
      }
    }

    ensureScene(lineNo).beats.push({ kind: 'action', text: line, source_line: lineNo });
  });

  for (const s of scenes)
    if (!s.beats.some((b) => b.kind === 'dialogue' || b.kind === 'action'))
      warnings.push({ code: 'EMPTY_SCENE', message: `Scene "${s.heading}" has no action or dialogue.`, source_line: s.source_line });
  if (!scenes.length) warnings.push({ code: 'NO_SCENES', message: 'No scenes found in the script.', source_line: 1 });

  return { title, scenes, warnings };
}

/** Every dialogue line of the script, in order — the canonical reference for fidelity checks. */
export function canonicalDialogue(parsed: ParsedScript): { source_line: number; speaker_label: string; text: string }[] {
  return parsed.scenes.flatMap((s) =>
    s.beats.flatMap((b) => (b.kind === 'dialogue' ? [{ source_line: b.source_line, speaker_label: b.speaker_label, text: b.text }] : [])),
  );
}
