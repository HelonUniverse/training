// Executes a RenderSpec with FFmpeg against local files. Used by the Railway
// worker (after downloading inputs) and by the local demo.

import { mkdtemp, mkdir, rm, writeFile, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawn } from 'node:child_process';
import type { RenderSpec } from '../core/render/render-spec.ts';
import { runFfmpeg, probeDuration } from '../core/storage/local-storage.ts';
import { concatArgs, concatListFile, finalizeArgs, normalizeArgs } from './ffmpeg-plan.ts';

export function hasAudioStream(file: string): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const p = spawn('ffprobe', ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=index', '-of', 'csv=p=0', file]);
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve(out.trim().length > 0) : reject(new Error(`ffprobe exited ${code}`))));
  });
}

export interface RenderResult {
  output_file: string;
  srt_file: string | null;
  duration_s: number;
}

/**
 * @param resolve maps a spec storage path to a local file path
 * @param outRoot directory where spec.output_path / spec.srt_path are written
 */
export async function renderEpisode(spec: RenderSpec, resolve: (storagePath: string) => string, outRoot: string): Promise<RenderResult> {
  if (!spec.inputs.length) throw new Error('render spec has no inputs');
  const work = await mkdtemp(join(tmpdir(), 'vs-render-'));
  try {
    const normalized: string[] = [];
    for (const [i, input] of spec.inputs.entries()) {
      const src = resolve(input.storage_path);
      const out = join(work, `n${String(i).padStart(3, '0')}.mp4`);
      // item.transition = how the timeline goes INTO this clip (cut | fade)
      await runFfmpeg(normalizeArgs(src, out, {
        duration_s: input.duration_s,
        has_audio: await hasAudioStream(src),
        fade_in: i > 0 && input.transition === 'fade',
        fade_out: spec.inputs[i + 1]?.transition === 'fade',
        video: spec.video,
        sample_rate: spec.audio.sample_rate,
      }));
      normalized.push(out);
    }
    const list = join(work, 'list.txt');
    await writeFile(list, concatListFile(normalized));
    const joined = join(work, 'joined.mp4');
    await runFfmpeg(concatArgs(list, joined));

    let srtFile: string | null = null;
    if (spec.captions.enabled && spec.srt) {
      srtFile = join(work, 'captions.srt');
      await writeFile(srtFile, spec.srt, 'utf8');
    }
    const output = join(outRoot, spec.output_path);
    await mkdir(dirname(output), { recursive: true });
    await runFfmpeg(finalizeArgs(joined, output, {
      loudnorm: spec.audio.loudnorm,
      srt_file: srtFile,
      burn_in: spec.captions.burn_in,
      language: spec.captions.language,
    }));
    let srtOut: string | null = null;
    if (srtFile && spec.srt_path) {
      srtOut = join(outRoot, spec.srt_path);
      await mkdir(dirname(srtOut), { recursive: true });
      await copyFile(srtFile, srtOut);
    }
    return { output_file: output, srt_file: srtOut, duration_s: await probeDuration(output) };
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}
