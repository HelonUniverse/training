// Pure FFmpeg argument builders (unit-testable without running FFmpeg).
//
// Pipeline:
//   1. normalize every clip → same size / fps / pixel format / 48 kHz stereo
//      AAC (silent track added when a clip has no audio), optional fades
//   2. concat (stream copy — inputs are now identical in format)
//   3. finalize: EBU R128 loudness normalization; captions either burned in
//      or attached as a soft mov_text track (language-tagged)

import type { RenderSpec } from '../core/render/render-spec.ts';

export const FADE_S = 0.5;

export function normalizeArgs(
  input: string,
  output: string,
  o: { duration_s: number; has_audio: boolean; fade_in: boolean; fade_out: boolean; video: RenderSpec['video']; sample_rate: number },
): string[] {
  const { width: W, height: H, fps } = o.video;
  const d = o.duration_s;
  const vf = [
    `scale=${W}:${H}:force_original_aspect_ratio=decrease`,
    `pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black`,
    'setsar=1',
    `fps=${fps}`,
    'format=yuv420p',
  ];
  const af = [`aresample=${o.sample_rate}`, 'aformat=sample_fmts=fltp:channel_layouts=stereo'];
  if (o.fade_in) {
    vf.push(`fade=t=in:st=0:d=${FADE_S}`);
    af.push(`afade=t=in:st=0:d=${FADE_S}`);
  }
  if (o.fade_out) {
    vf.push(`fade=t=out:st=${Math.max(0, d - FADE_S).toFixed(3)}:d=${FADE_S}`);
    af.push(`afade=t=out:st=${Math.max(0, d - FADE_S).toFixed(3)}:d=${FADE_S}`);
  }
  const args = ['-i', input];
  if (!o.has_audio) args.push('-f', 'lavfi', '-t', String(d), '-i', `anullsrc=r=${o.sample_rate}:cl=stereo`);
  const aIn = o.has_audio ? '0:a:0' : '1:a:0';
  args.push(
    '-filter_complex', `[0:v:0]${vf.join(',')}[v];[${aIn}]${af.join(',')}[a]`,
    '-map', '[v]', '-map', '[a]',
    '-t', String(d),
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-r', String(fps),
    '-c:a', 'aac', '-b:a', '192k', '-ar', String(o.sample_rate), '-ac', '2',
    '-movflags', '+faststart',
    output,
  );
  return args;
}

export function concatListFile(files: string[]): string {
  return files.map((f) => `file '${f.replace(/'/g, "'\\''")}'`).join('\n') + '\n';
}

export function concatArgs(listFile: string, output: string): string[] {
  return ['-f', 'concat', '-safe', '0', '-i', listFile, '-c', 'copy', output];
}

/** Escape a path for the subtitles filter argument. */
export function escapeFilterPath(p: string): string {
  return p.replace(/\\/g, '\\\\').replace(/:/g, '\\:').replace(/'/g, "\\'").replace(/,/g, '\\,');
}

export function finalizeArgs(
  input: string,
  output: string,
  o: { loudnorm: boolean; srt_file: string | null; burn_in: boolean; language: string },
): string[] {
  const args = ['-i', input];
  const softSubs = Boolean(o.srt_file && !o.burn_in);
  if (softSubs) args.push('-i', o.srt_file!);
  if (o.srt_file && o.burn_in) args.push('-vf', `subtitles='${escapeFilterPath(o.srt_file)}'`, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20');
  else args.push('-c:v', 'copy');
  if (o.loudnorm) args.push('-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000');
  else args.push('-c:a', 'copy');
  args.push('-map', '0:v:0', '-map', '0:a:0');
  if (softSubs) {
    const lang3 = ({ es: 'spa', en: 'eng' } as Record<string, string>)[o.language] ?? o.language;
    args.push('-map', '1:0', '-c:s', 'mov_text', '-metadata:s:s:0', `language=${lang3}`);
  }
  args.push('-movflags', '+faststart', output);
  return args;
}
