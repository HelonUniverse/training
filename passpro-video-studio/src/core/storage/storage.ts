// Where clip videos and assets live. Production: Supabase Storage bucket
// 'video-studio' (private; signed URLs). Local/demo: a directory on disk.

export interface IngestResult {
  storage_path: string;
  duration_s: number;
  bytes: number;
}

export interface MediaStorage {
  /**
   * Copy a provider result into our storage IMMEDIATELY (provider URLs expire).
   * mock:// URLs are synthesized locally so the free workflow is playable.
   */
  ingestVideo(sourceUrl: string, destPath: string, expectedDurationS: number): Promise<IngestResult>;
  /** A URL a provider or the UI can fetch (signed/short-lived in production). */
  urlFor(storagePath: string): Promise<string>;
  /** Local filesystem path when available (render worker). */
  localPath?(storagePath: string): string;
  writeText?(storagePath: string, text: string): Promise<void>;
}

export function clipVersionPath(episodeId: string, clipId: string, version: number): string {
  return `episodes/${episodeId}/clips/${clipId}/v${version}.mp4`;
}
