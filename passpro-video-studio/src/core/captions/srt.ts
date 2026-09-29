// SRT captions from the CANONICAL dialogue (never from speech recognition).
// Timing: each clip's lines are placed at the clip's offset on the timeline;
// the planner's in-clip estimates are scaled to the version's real duration.

import type { Clip, TimelineItem } from '../types.ts';

export interface CaptionCue {
  index: number;
  start_s: number;
  end_s: number;
  text: string;
}

export interface CaptionOptions {
  max_chars_per_line?: number;
  speaker_labels?: boolean;
  min_cue_s?: number;
}

export function formatSrtTime(seconds: number): string {
  const ms = Math.max(0, Math.round(seconds * 1000));
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  const s = Math.floor((ms % 60_000) / 1000);
  const r = ms % 1000;
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  return `${p(h)}:${p(m)}:${p(s)},${p(r, 3)}`;
}

/** Wraps to at most two lines; longer text is split into several cues by the caller. */
export function wrapCaption(text: string, max = 42): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let cur = '';
  for (const w of words) {
    if (cur && (cur + ' ' + w).length > max) {
      lines.push(cur);
      cur = w;
    } else cur = cur ? `${cur} ${w}` : w;
  }
  if (cur) lines.push(cur);
  return lines;
}

/** Cues of at most two lines, breaking at sentence ends first, then by length. */
export function captionChunks(text: string, max = 42): string[] {
  const sentences = text.match(/[^.!?…]+(?:[.!?…]+["”»)]?|$)\s*/g)?.map((x) => x.trim()).filter(Boolean) ?? [text];
  const chunks: string[][] = [];
  let cur: string[] = [];
  for (const sentence of sentences) {
    const lines = wrapCaption(sentence, max);
    if (cur.length && cur.length + lines.length <= 2) {
      const merged = wrapCaption([...cur, ...lines].join(' '), max);
      if (merged.length <= 2) {
        cur = merged;
        continue;
      }
    }
    if (cur.length) chunks.push(cur);
    cur = [];
    for (let i = 0; i < lines.length; i += 2) {
      if (i + 2 < lines.length) chunks.push(lines.slice(i, i + 2));
      else cur = lines.slice(i, i + 2);
    }
  }
  if (cur.length) chunks.push(cur);
  return chunks.map((c) => c.join('\n'));
}

export function buildCaptionCues(
  timeline: TimelineItem[],
  clips: Clip[],
  opts: CaptionOptions = {},
): CaptionCue[] {
  const max = opts.max_chars_per_line ?? 42;
  const minCue = opts.min_cue_s ?? 1;
  const byId = new Map(clips.map((c) => [c.id, c]));
  const cues: CaptionCue[] = [];
  let offset = 0;
  for (const item of timeline) {
    if (!item.enabled) continue;
    const clip = byId.get(item.clip_id);
    if (!clip) continue;
    const version = clip.versions.find((v) => v.version === item.version && !v.deleted_at);
    const realDuration = version?.duration_s ?? clip.duration_estimate_s;
    const planned = Math.max(clip.duration_estimate_s, ...clip.dialogue.map((d) => d.est_end_s), 0.001);
    const scale = realDuration / planned;
    for (const d of clip.dialogue) {
      const text = opts.speaker_labels ? `${d.speaker_label}: ${d.text}` : d.text;
      const chunks = captionChunks(text, max);
      const start = offset + d.est_start_s * scale;
      const end = Math.min(offset + realDuration, offset + d.est_end_s * scale);
      const span = Math.max(minCue * chunks.length, end - start);
      const total = chunks.reduce((s, c) => s + c.length, 0);
      let t = start;
      for (const c of chunks) {
        const dur = (span * c.length) / total;
        cues.push({ index: cues.length + 1, start_s: t, end_s: Math.min(offset + realDuration, t + dur), text: c });
        t += dur;
      }
    }
    offset += realDuration;
  }
  return cues;
}

export function toSrt(cues: CaptionCue[]): string {
  return cues.map((c) => `${c.index}\n${formatSrtTime(c.start_s)} --> ${formatSrtTime(c.end_s)}\n${c.text}\n`).join('\n');
}
