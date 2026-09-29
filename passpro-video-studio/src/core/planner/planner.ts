// Production planner: script → scenes → clips, with per-clip cost estimates.
//
// RuleBasedPlanner is deterministic and never paraphrases (dialogue is copied
// from the parser). An LLM planner can implement ProductionPlanner later; its
// output must pass checkDialogueFidelity before it is accepted.

import type { Asset, Character, Clip, DialogueLine, Scene, Series, ValidationIssue } from '../types.ts';
import { estimateClipCost, type PriceRow } from '../pricing.ts';
import type { ProviderCapabilities } from '../providers/video-provider.ts';
import { CharacterIndex, canonicalDialogue, parseScript, type Beat, type ParsedScript } from './script-parser.ts';
import { canonicalJson, normalizeName, sha256Hex, uuid } from '../util.ts';

export interface PlannerInput {
  episode_id: string;
  script: string;
  series: Series;
  characters: Character[];
  assets: Asset[];
  pricing: PriceRow[];
  provider: { id: string; model: string; paid: boolean; capabilities: ProviderCapabilities };
  resolution: string;
  timing?: Partial<TimingModel>;
}

export interface TimingModel {
  words_per_second: number;
  pause_after_line_s: number;
  min_action_s: number;
  action_words_per_second: number;
  target_clip_s: number;
}

export const DEFAULT_TIMING: TimingModel = {
  words_per_second: 2.5,
  pause_after_line_s: 0.4,
  min_action_s: 2,
  action_words_per_second: 4,
  target_clip_s: 12,
};

export interface PlanDraft {
  title: string | null;
  scenes: Scene[];
  clips: Clip[];
  warnings: ValidationIssue[];
  parsed: ParsedScript;
  summary: PlanSummary;
}

export interface PlanSummary {
  scene_count: number;
  clip_count: number;
  estimated_duration_s: number;
  estimated_cost_usd: number | null;
  pricing_verified: boolean;
  character_ids: string[];
}

export interface ProductionPlanner {
  plan(input: PlannerInput): Promise<PlanDraft>;
}

const words = (s: string) => (s.trim() ? s.trim().split(/\s+/).length : 0);

interface Unit {
  beat: Beat;
  /** for split dialogue: the verbatim part of the line */
  text?: string;
  seconds: number;
}

/** Splits a long line at sentence boundaries; the parts re-join to the original text. */
export function splitAtSentences(text: string, maxSeconds: number, t: TimingModel): string[] {
  const secs = (s: string) => words(s) / t.words_per_second + t.pause_after_line_s;
  if (secs(text) <= maxSeconds) return [text];
  const sentences = text.match(/[^.!?…]+(?:[.!?…]+["”»)]?|$)\s*/g)?.map((s) => s.trim()).filter(Boolean) ?? [text];
  const parts: string[] = [];
  let cur = '';
  for (const s of sentences) {
    const next = cur ? `${cur} ${s}` : s;
    if (cur && secs(next) > maxSeconds) {
      parts.push(cur);
      cur = s;
    } else cur = next;
  }
  if (cur) parts.push(cur);
  return parts;
}

export class RuleBasedPlanner implements ProductionPlanner {
  async plan(input: PlannerInput): Promise<PlanDraft> {
    const t: TimingModel = { ...DEFAULT_TIMING, ...input.timing };
    const caps = input.provider.capabilities;
    const maxS = caps.max_duration_s;
    const minS = Math.max(caps.min_duration_s, 5);
    const parsed = parseScript(input.script, input.characters);
    const idx = new CharacterIndex(input.characters);
    const byId = new Map(input.characters.map((c) => [c.id, c]));
    const warnings: ValidationIssue[] = parsed.warnings.map((w) => ({
      code: w.code,
      severity: w.code === 'UNKNOWN_SPEAKER' || w.code === 'NO_SCENES' ? 'review' : 'info',
      source: 'planner',
      message: `line ${w.source_line}: ${w.message}`,
    }));

    const locations = input.assets.filter((a) => a.kind === 'location');
    const defaultLocation =
      locations.find((a) => a.slug === input.series.bible.default_location_slug) ?? locations[0] ?? null;
    const findLocation = (heading: string): Asset | null => {
      const h = ` ${normalizeName(heading)} `;
      let best: Asset | null = null;
      let bestLen = 0;
      for (const loc of locations)
        for (const n of [loc.name, ...loc.aliases]) {
          const k = normalizeName(n);
          if (k && h.includes(` ${k} `) && k.length > bestLen) {
            best = loc;
            bestLen = k.length;
          }
        }
      return best ?? defaultLocation;
    };

    const scenes: Scene[] = [];
    const clips: Clip[] = [];
    let clipOrd = 0;

    for (const [si, ps] of parsed.scenes.entries()) {
      const location = findLocation(ps.heading);
      const scene: Scene = {
        id: uuid(),
        episode_id: input.episode_id,
        ord: si + 1,
        heading: ps.heading || `Escena ${si + 1}`,
        location_asset_id: location?.id ?? null,
        summary: ps.beats.filter((b) => b.kind === 'action').map((b) => (b as { text: string }).text).join(' ').slice(0, 280),
      };
      scenes.push(scene);

      // Expand beats into timed units (long lines split at sentence boundaries).
      const groups: Unit[][] = [[]];
      let camera = '';
      const cameraFor = new Map<Unit[], string>();
      for (const beat of ps.beats) {
        const g = groups[groups.length - 1];
        if (beat.kind === 'break') {
          if (g.length) groups.push([]);
          continue;
        }
        if (beat.kind === 'camera') {
          camera = beat.text;
          cameraFor.set(g, camera);
          continue;
        }
        if (beat.kind === 'action') {
          g.push({ beat, seconds: Math.max(t.min_action_s, words(beat.text) / t.action_words_per_second) });
          continue;
        }
        const parts = splitAtSentences(beat.text, maxS, t);
        for (const p of parts) g.push({ beat, text: p, seconds: words(p) / t.words_per_second + t.pause_after_line_s });
      }

      // Greedy packing into clips ≤ provider max, aiming for target length.
      for (const group of groups.filter((g) => g.length)) {
        let bucket: Unit[] = [];
        let secs = 0;
        const flush = () => {
          if (!bucket.length) return;
          clipOrd += 1;
          clips.push(this.buildClip(input, scene, clipOrd, bucket, secs, minS, maxS, cameraFor.get(group) ?? camera, idx, byId, location));
          bucket = [];
          secs = 0;
        };
        for (const [ui, u] of group.entries()) {
          const nextIsDialogue = group[ui + 1]?.beat.kind === 'dialogue';
          if (bucket.length && (secs + u.seconds > maxS || (secs >= t.target_clip_s && !(u.beat.kind === 'action' && nextIsDialogue && secs + u.seconds <= maxS)))) {
            flush();
          }
          bucket.push(u);
          secs += u.seconds;
        }
        flush();
      }
    }

    // Continuity between neighbours.
    for (const [i, c] of clips.entries()) {
      const prev = clips[i - 1];
      const next = clips[i + 1];
      c.continuity = {
        from_previous: !prev
          ? 'Opening shot of the episode.'
          : prev.scene_id === c.scene_id
            ? `Continues directly from clip ${prev.ord}: ${lastMoment(prev)}`
            : `New scene: ${scenes.find((s) => s.id === c.scene_id)?.heading ?? ''}`,
        into_next: !next
          ? 'Final shot of the episode.'
          : next.scene_id === c.scene_id
            ? `Ends so clip ${next.ord} can continue in the same place with the same characters.`
            : 'Ends the scene.',
      };
    }

    const total = clips.reduce((s, c) => s + c.duration_estimate_s, 0);
    const costs = clips.map((c) => c.estimated_cost_usd);
    const summary: PlanSummary = {
      scene_count: scenes.length,
      clip_count: clips.length,
      estimated_duration_s: total,
      estimated_cost_usd: costs.some((c) => c === null) ? null : Math.round(costs.reduce((a, b) => a! + b!, 0)! * 10000) / 10000,
      pricing_verified: clips.every((c) => c.pricing_verified),
      character_ids: [...new Set(clips.flatMap((c) => c.character_ids))],
    };
    for (const issue of checkDialogueFidelity(parsed, clips)) warnings.push(issue);
    return { title: parsed.title, scenes, clips, warnings, parsed, summary };
  }

  private buildClip(
    input: PlannerInput,
    scene: Scene,
    ord: number,
    units: Unit[],
    seconds: number,
    minS: number,
    maxS: number,
    camera: string,
    idx: CharacterIndex,
    byId: Map<string, Character>,
    location: Asset | null,
  ): Clip {
    const id = uuid();
    const duration = Math.min(maxS, Math.max(minS, Math.ceil(seconds)));
    const issues: ValidationIssue[] = [];

    let cursor = 0;
    const dialogue: DialogueLine[] = [];
    const actions: string[] = [];
    const charIds = new Set<string>();
    for (const u of units) {
      if (u.beat.kind === 'dialogue') {
        const d = u.beat;
        dialogue.push({
          speaker_character_id: d.character_id,
          speaker_label: d.speaker_label,
          text: u.text ?? d.text,
          source_line: d.source_line,
          est_start_s: round1(cursor),
          est_end_s: round1(Math.min(duration, cursor + u.seconds)),
          delivery: d.delivery,
        });
        if (d.character_id) charIds.add(d.character_id);
      } else if (u.beat.kind === 'action') {
        actions.push(u.beat.text);
        for (const c of idx.mentionedIn(u.beat.text)) charIds.add(c.id);
      }
      cursor += u.seconds;
    }
    if (seconds > maxS + 0.01) {
      issues.push({
        code: 'CLIP_TOO_LONG',
        severity: 'review',
        source: 'planner',
        clip_id: id,
        message: `Content needs ~${seconds.toFixed(1)}s but the provider maximum is ${maxS}s. A sentence cannot be split without rewording; edit the script or approve a dub.`,
      });
    }

    const visible = [...charIds].map((c) => byId.get(c)!).filter((c) => c && !c.voice_only);
    const refIds: string[] = [];
    for (const c of visible) {
      const refs = input.assets.filter((a) => a.kind === 'reference_image' && a.character_id === c.id && a.status === 'ready');
      const primary = refs.find((a) => a.id === c.primary_reference_asset_id) ?? refs[0];
      if (primary) refIds.push(primary.id);
      else
        issues.push({
          code: 'MISSING_REFERENCE_IMAGE',
          severity: input.provider.paid ? 'review' : 'info',
          source: 'planner',
          clip_id: id,
          message: `${c.name} has no uploaded reference image; character consistency cannot be locked.`,
        });
    }
    if (location) {
      const locRef = input.assets.find((a) => a.kind === 'reference_image' && a.parent_asset_id === location.id && a.status === 'ready');
      if (locRef) refIds.push(locRef.id);
    }

    const speakers = [...new Set(dialogue.map((d) => (d.speaker_character_id && byId.get(d.speaker_character_id)?.name) || d.speaker_label))];
    const action = actions.join(' ') || (speakers.length ? `${speakers.join(' and ')} speaking.` : 'Establishing shot.');
    const est = estimateClipCost(input.pricing, {
      provider: input.provider.id,
      model: input.provider.model,
      resolution: input.resolution,
      duration_s: duration,
      reference_image_count: refIds.length,
    });
    for (const i of est.issues) issues.push({ ...i, clip_id: id });

    const voiceOnly = [...charIds].map((c) => byId.get(c)!).filter((c) => c?.voice_only);
    return {
      id,
      episode_id: input.episode_id,
      scene_id: scene.id,
      ord,
      duration_estimate_s: duration,
      location_asset_id: location?.id ?? null,
      character_ids: [...charIds],
      dialogue,
      action,
      camera_direction: camera || 'medium shot, eye level, static camera',
      visual_prompt: action,
      audio_requirements: {
        mode: 'native',
        notes: [
          ...voiceOnly.map((c) => `${c.name} is heard off-screen only (never shown).`),
          'Warm neighborhood ambience under the dialogue.',
        ],
      },
      reference_asset_ids: refIds,
      continuity: { from_previous: '', into_next: '' },
      estimated_cost_usd: est.amount_usd,
      pricing_verified: est.verified,
      status: 'PLANNED',
      issues,
      versions: [],
      selected_version: null,
      edited_by_human: false,
    };
  }
}

function round1(n: number) {
  return Math.round(n * 10) / 10;
}

function lastMoment(c: Clip): string {
  const d = c.dialogue[c.dialogue.length - 1];
  return d ? `${d.speaker_label} just said "${d.text.slice(0, 80)}"` : c.action.slice(0, 120);
}

/**
 * Verifies clips carry the script's dialogue verbatim and in order. Planner
 * mismatches are CONFLICTS (a paraphrase slipped in); explicit human edits are
 * REVIEW items so a person confirms the change on purpose.
 */
export function checkDialogueFidelity(parsed: ParsedScript, clips: Clip[]): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const canon = canonicalDialogue(parsed);
  const ws = (s: string) => s.replace(/\s+/g, ' ').trim();
  const planned = new Map<number, { text: string[]; clips: Clip[] }>();
  for (const c of clips)
    for (const d of c.dialogue) {
      const e = planned.get(d.source_line) ?? { text: [], clips: [] };
      e.text.push(d.text);
      if (!e.clips.includes(c)) e.clips.push(c);
      planned.set(d.source_line, e);
    }
  for (const line of canon) {
    const p = planned.get(line.source_line);
    if (!p) {
      issues.push({ code: 'DIALOGUE_MISSING', severity: 'conflict', source: 'fidelity', message: `Script line ${line.source_line} (${line.speaker_label}) is not in any clip.`, expected: line.text });
      continue;
    }
    if (ws(p.text.join(' ')) !== ws(line.text)) {
      const human = p.clips.some((c) => c.edited_by_human);
      issues.push({
        code: human ? 'DIALOGUE_EDITED' : 'DIALOGUE_MISMATCH',
        severity: human ? 'review' : 'conflict',
        source: 'fidelity',
        clip_id: p.clips[0].id,
        message: human
          ? `Dialogue from script line ${line.source_line} was edited by a person. Confirm the change is intended.`
          : `Dialogue from script line ${line.source_line} does not match the script verbatim.`,
        expected: line.text,
        found: p.text.join(' '),
      });
    }
  }
  const canonLines = new Set(canon.map((l) => l.source_line));
  for (const [ln, p] of planned)
    if (!canonLines.has(ln))
      issues.push({ code: 'DIALOGUE_NOT_IN_SCRIPT', severity: 'conflict', source: 'fidelity', clip_id: p.clips[0].id, message: `Clip dialogue references script line ${ln}, which has no dialogue.`, found: p.text.join(' ') });
  return issues;
}

/** Hash of everything a human approves. Any edit changes it and voids approval. */
export async function computePlanHash(scenes: Scene[], clips: Clip[]): Promise<string> {
  const plan = {
    scenes: scenes.map((s) => ({ id: s.id, ord: s.ord, heading: s.heading, location: s.location_asset_id })),
    clips: [...clips]
      .sort((a, b) => a.ord - b.ord)
      .map((c) => ({
        id: c.id,
        ord: c.ord,
        scene: c.scene_id,
        duration: c.duration_estimate_s,
        location: c.location_asset_id,
        characters: [...c.character_ids].sort(),
        dialogue: c.dialogue.map((d) => [d.speaker_character_id, d.text, d.delivery ?? null]),
        action: c.action,
        camera: c.camera_direction,
        visual: c.visual_prompt,
        audio: c.audio_requirements,
        refs: [...c.reference_asset_ids].sort(),
        estimate: c.estimated_cost_usd,
      })),
  };
  return sha256Hex(canonicalJson(plan));
}
