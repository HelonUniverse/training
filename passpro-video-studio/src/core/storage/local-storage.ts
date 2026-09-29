// Local-disk MediaStorage for tests and the demo (Node only).
// mock://clip?duration=&color=&label=&tone= → a real MP4 made with FFmpeg:
// solid colour card, burned-in label, sine tone. Costs nothing.

import { mkdir, stat, writeFile, copyFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { spawn } from 'node:child_process';
import type { IngestResult, MediaStorage } from './storage.ts';

export function runFfmpeg(args: string[], bin = 'ffmpeg'): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(bin, ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}: ${err.slice(-2000)}`))));
  });
}

export function probeDuration(file: string, bin = 'ffprobe'): Promise<number> {
  return new Promise((resolve, reject) => {
    const p = spawn(bin, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', file]);
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve(Number(out.trim())) : reject(new Error(`ffprobe exited ${code}`))));
  });
}

const escDrawtext = (s: string) => s.replace(/\\/g, '\\\\').replace(/:/g, '\\:').replace(/'/g, "\u2019").replace(/%/g, '\\%');

export async function synthesizeMockClip(file: string, p: URLSearchParams): Promise<void> {
  const dur = Number(p.get('duration') ?? 5);
  const color = (p.get('color') ?? '3d405b').replace(/[^0-9a-f]/gi, '');
  const tone = Number(p.get('tone') ?? 440);
  const label = escDrawtext(p.get('label') ?? 'mock');
  await runFfmpeg([
    '-f', 'lavfi', '-i', `color=c=0x${color}:s=640x360:r=24:d=${dur}`,
    '-f', 'lavfi', '-i', `sine=frequency=${tone}:sample_rate=48000:duration=${dur}`,
    '-vf', `drawtext=text='MOCK CLIP ${label}':fontcolor=white:fontsize=20:x=(w-tw)/2:y=(h-th)/2`,
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file,
  ]);
}

export class LocalMediaStorage implements MediaStorage {
  readonly root: string;
  constructor(root: string) {
    this.root = root;
  }

  localPath(storagePath: string): string {
    if (storagePath.includes('..')) throw new Error('invalid storage path');
    return join(this.root, storagePath);
  }

  async urlFor(storagePath: string): Promise<string> {
    return `file://${this.localPath(storagePath)}`;
  }

  async writeText(storagePath: string, text: string): Promise<void> {
    const f = this.localPath(storagePath);
    await mkdir(dirname(f), { recursive: true });
    await writeFile(f, text, 'utf8');
  }

  async ingestVideo(sourceUrl: string, destPath: string, expectedDurationS: number): Promise<IngestResult> {
    const file = this.localPath(destPath);
    await mkdir(dirname(file), { recursive: true });
    if (sourceUrl.startsWith('mock://')) {
      await synthesizeMockClip(file, new URL(sourceUrl.replace('mock://', 'http://mock/')).searchParams);
    } else if (sourceUrl.startsWith('file://')) {
      await copyFile(sourceUrl.slice('file://'.length), file);
    } else if (/^https:\/\//.test(sourceUrl)) {
      const res = await fetch(sourceUrl);
      if (!res.ok) throw new Error(`download failed: HTTP ${res.status}`);
      await writeFile(file, new Uint8Array(await res.arrayBuffer()));
    } else {
      throw new Error(`unsupported source URL scheme: ${sourceUrl.slice(0, 16)}`);
    }
    const duration = await probeDuration(file).catch(() => expectedDurationS);
    return { storage_path: destPath, duration_s: Math.round(duration * 1000) / 1000, bytes: (await stat(file)).size };
  }
}
