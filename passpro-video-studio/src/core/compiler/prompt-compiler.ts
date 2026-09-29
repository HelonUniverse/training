// PromptCompiler: series style + character master data + location + clip
// action + dialogue + camera + continuity + reference assets + (optional,
// layer-provided) locked facts  →  one provider-neutral CompiledClipRequest.
//
// The raw script is never sent to a provider. Facts are never written here:
// they arrive at compile time from a FactContextProvider (e.g. the PassPro
// education layer reading VERIFIED content locks from the database).

import type { Asset, Character, Clip, Scene, Series } from '../types.ts';
import { StudioError } from '../types.ts';
import type { CompiledClipRequest, MediaRef, ProviderCapabilities } from '../providers/video-provider.ts';

export interface FactStatement {
  id: string;
  statement: string;
}

/** Hook implemented by subject layers. Core has no facts of its own. */
export interface FactContextProvider {
  factsForClip(clip: Clip, series: Series): Promise<FactStatement[]>;
}

export interface CompileInput {
  series: Series;
  characters: Character[];
  assets: Asset[];
  scene: Scene;
  clip: Clip;
  clip_count: number;
  capabilities: ProviderCapabilities;
  resolution: string;
  ratio: string;
  /** Resolves an asset to a URL the provider can fetch (signed URL). */
  resolveMedia: (asset: Asset) => Promise<string>;
  facts?: FactStatement[];
}

export interface CompiledPrompt {
  request: CompiledClipRequest;
  sections: Record<string, string>;
  fact_ids: string[];
  warnings: string[];
}

const DO_NOT = [
  'change any character’s clothing, age, face, hairstyle or body type',
  'change any character design from the reference images',
  'add characters who are not listed in CHARACTER LOCK',
  'show on-screen text, subtitles, captions, signs with words, logos or watermarks',
  'change, add or invent any number, date, percentage or rule',
  'reword the dialogue; speak it exactly as written',
];

export async function compileClipPrompt(input: CompileInput): Promise<CompiledPrompt> {
  const { series, clip, scene, capabilities: caps } = input;
  const byId = new Map(input.characters.map((c) => [c.id, c]));
  const assetById = new Map(input.assets.map((a) => [a.id, a]));
  const inClip = clip.character_ids.map((id) => byId.get(id)).filter((c): c is Character => Boolean(c));
  const visible = inClip.filter((c) => !c.voice_only);
  const offscreen = inClip.filter((c) => c.voice_only);
  const warnings: string[] = [];

  // Reference images, numbered in the order the provider receives them.
  const refs: MediaRef[] = [];
  for (const id of clip.reference_asset_ids) {
    const a = assetById.get(id);
    if (!a || a.status !== 'ready' || !a.storage_path) {
      warnings.push(`reference asset ${id} is not uploaded; skipped`);
      continue;
    }
    if (refs.length >= caps.max_reference_images) {
      warnings.push(`reference ${a.name} dropped: provider accepts ${caps.max_reference_images}`);
      continue;
    }
    const owner = a.character_id ? byId.get(a.character_id)?.name : a.parent_asset_id ? assetById.get(a.parent_asset_id)?.name : a.name;
    refs.push({ asset_id: a.id, url: await input.resolveMedia(a), label: owner ?? a.name });
  }
  const refNumber = (label: string) => {
    const i = refs.findIndex((r) => r.label === label);
    return i >= 0 ? i + 1 : null;
  };

  // Reference audio: master voice samples for speaking characters (native mode).
  const audios: MediaRef[] = [];
  const speakers = [...new Set(clip.dialogue.map((d) => d.speaker_character_id).filter(Boolean))] as string[];
  if (clip.audio_requirements.mode === 'native' && caps.audio_reference && refs.length) {
    for (const sid of speakers) {
      const c = byId.get(sid);
      const sample = c?.voice.master_sample_asset_id ? assetById.get(c.voice.master_sample_asset_id) : undefined;
      if (sample?.status === 'ready' && sample.storage_path && audios.length < caps.max_reference_audios)
        audios.push({ asset_id: sample.id, url: await input.resolveMedia(sample), label: c!.name });
    }
  }
  const audioNumber = (name: string) => {
    const i = audios.findIndex((r) => r.label === name);
    return i >= 0 ? i + 1 : null;
  };

  const location = clip.location_asset_id ? assetById.get(clip.location_asset_id) : undefined;
  const sections: Record<string, string> = {};

  sections.STYLE = [series.visual_style, ...series.bible.generation_rules].filter(Boolean).join(' ');

  sections['CHARACTER LOCK'] = visible.length
    ? visible
        .map((c) => {
          const n = refNumber(c.name);
          return [
            `${c.name}${c.age !== null ? ` (age ${c.age})` : ''}: ${c.visual_prompt || c.description}`,
            c.wardrobe && `Wardrobe: ${c.wardrobe}`,
            c.continuity_notes && `Continuity: ${c.continuity_notes}`,
            n ? `Must match reference image ${n} exactly.` : 'No reference image uploaded yet; follow this description exactly.',
          ]
            .filter(Boolean)
            .join(' ');
        })
        .join('\n')
    : 'No on-screen characters in this shot.';
  if (offscreen.length)
    sections['CHARACTER LOCK'] += `\nOff-screen voice only (never visible): ${offscreen.map((c) => c.name).join(', ')}.`;

  if (location) {
    const n = refNumber(location.name);
    sections['LOCATION LOCK'] = `${location.name}: ${location.visual_prompt || location.description}${n ? ` Must match reference image ${n}.` : ''}`;
  }

  sections['CURRENT SHOT'] = `${scene.heading}. Clip ${clip.ord} of ${input.clip_count}, ${clip.duration_estimate_s} seconds.`;
  sections.ACTION = clip.visual_prompt || clip.action;
  sections.CAMERA = clip.camera_direction;

  if (clip.dialogue.length) {
    const lang = series.language === 'es' ? 'Spanish' : series.language;
    sections.DIALOGUE =
      `Spoken in ${lang}, word for word, lip-synced for on-screen speakers:\n` +
      clip.dialogue
        .map((d) => {
          const c = d.speaker_character_id ? byId.get(d.speaker_character_id) : undefined;
          const voice = c?.voice.description ? ` [voice: ${c.voice.description}${audioNumber(c.name) ? `; timbre follows reference audio ${audioNumber(c.name)}` : ''}]` : '';
          const how = d.delivery ? ` (${d.delivery})` : '';
          const off = c?.voice_only ? ' (off-screen)' : '';
          return `${d.speaker_label}${off}${how}${voice}: "${d.text}"`;
        })
        .join('\n');
  }

  const audioNotes = clip.audio_requirements.notes.filter(Boolean);
  if (audioNotes.length) sections.AUDIO = audioNotes.join(' ');

  sections.CONTINUITY = [clip.continuity.from_previous, clip.continuity.into_next, ...series.bible.continuity_rules]
    .filter(Boolean)
    .join(' ');

  const facts = input.facts ?? [];
  if (facts.length)
    sections['LOCKED FACTS'] =
      'If any of these facts is spoken, it must be exactly as stated:\n' + facts.map((f) => `- ${f.statement}`).join('\n');

  sections['DO NOT'] = [...DO_NOT, series.bible.negative_prompt && `include: ${series.bible.negative_prompt}`]
    .filter(Boolean)
    .map((s) => `- ${s}`)
    .join('\n');

  const prompt = Object.entries(sections)
    .map(([k, v]) => `${k}:\n${v}`)
    .join('\n\n');

  if (prompt.length > caps.max_prompt_chars)
    throw new StudioError('VS_PROMPT_TOO_LONG', `compiled prompt is ${prompt.length} chars; provider max ${caps.max_prompt_chars}. Shorten the clip or split it.`);

  const negative = [series.bible.negative_prompt, ...visible.map((c) => c.negative_prompt)].filter(Boolean).join(', ');
  return {
    request: {
      clip_id: clip.id,
      prompt,
      negative_prompt: negative,
      duration_s: clip.duration_estimate_s,
      resolution: input.resolution,
      ratio: input.ratio,
      reference_images: refs,
      reference_audios: audios,
    },
    sections,
    fact_ids: facts.map((f) => f.id),
    warnings,
  };
}
