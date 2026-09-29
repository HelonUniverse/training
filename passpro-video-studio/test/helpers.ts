import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MemoryStudioStore } from '../src/core/workflow/store.ts';
import { StudioService } from '../src/core/workflow/studio-service.ts';
import { MockVideoProvider, type MockVideoOptions } from '../src/core/providers/mock-video-provider.ts';
import { LocalMediaStorage } from '../src/core/storage/local-storage.ts';
import { PassProEducationLayer } from '../src/education/passpro-layer.ts';
import { loadSeriesBible } from '../fixtures/load-series.ts';
import { fixtureLocks } from '../fixtures/content-locks.fixture.ts';
import { fixturePricing } from '../fixtures/pricing.fixture.ts';
import type { VideoProvider } from '../src/core/providers/video-provider.ts';

/** Wraps a provider and counts every call — proves nothing is sent before approval. */
export class SpyProvider implements VideoProvider {
  calls = { generateClip: 0, getJobStatus: 0, getResult: 0 };
  inner: VideoProvider;
  constructor(inner: VideoProvider) { this.inner = inner; }
  get id() { return this.inner.id; }
  get model() { return this.inner.model; }
  get paid() { return this.inner.paid; }
  capabilities() { return this.inner.capabilities(); }
  supportsImageReference() { return this.inner.supportsImageReference(); }
  supportsAudioReference() { return this.inner.supportsAudioReference(); }
  supportsCharacterReference() { return this.inner.supportsCharacterReference(); }
  validateRequest(r: Parameters<VideoProvider['validateRequest']>[0]) { return this.inner.validateRequest(r); }
  generateClip(...a: Parameters<VideoProvider['generateClip']>) { this.calls.generateClip++; return this.inner.generateClip(...a); }
  getJobStatus(id: string) { this.calls.getJobStatus++; return this.inner.getJobStatus(id); }
  getResult(id: string) { this.calls.getResult++; return this.inner.getResult(id); }
}

export async function makeStudio(mockOpts: MockVideoOptions = {}) {
  const bible = loadSeriesBible();
  const store = new MemoryStudioStore();
  store.setSettings({ pricing: fixturePricing() });
  store.addSeries(bible.series);
  bible.characters.forEach((c) => store.addCharacter(c));
  bible.assets.forEach((a) => store.addAsset(a));
  const root = await mkdtemp(join(tmpdir(), 'vs-test-'));
  const storage = new LocalMediaStorage(root);
  const provider = new SpyProvider(new MockVideoProvider({ ticksToComplete: 2, ...mockOpts }));
  const education = new PassProEducationLayer(async (scopes) => fixtureLocks().filter((l) => scopes.includes(l.scope_key)));
  const studio = new StudioService({ store, provider, storage, layers: [education.asLayer()] });
  return { bible, store, storage, provider, studio, root, education };
}

export async function runUntilIdle(studio: StudioService, episodeId: string, max = 50) {
  for (let i = 0; i < max; i++) {
    const r = await studio.tick(episodeId);
    if (r.open === 0) return;
  }
  throw new Error('jobs did not finish');
}
