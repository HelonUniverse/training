// Provider-independent description of a final render. Built from the timeline
// and canonical captions; consumed by the FFmpeg worker. Contains only storage
// paths — no provider URLs, no API keys — so rendering can never call an AI API.

export interface RenderInput {
  clip_id: string;
  version: number;
  storage_path: string;
  duration_s: number;
  transition: 'cut' | 'fade';
}

export interface RenderSpec {
  episode_id: string;
  inputs: RenderInput[];
  output_path: string;
  srt_path: string | null;
  srt: string | null;
  captions: { enabled: boolean; burn_in: boolean; language: string };
  video: { width: number; height: number; fps: number };
  audio: { sample_rate: number; loudnorm: boolean };
}

export function totalDuration(spec: RenderSpec): number {
  return spec.inputs.reduce((s, i) => s + i.duration_s, 0);
}
