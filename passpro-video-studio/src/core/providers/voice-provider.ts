// Voice (TTS) provider contract. For the first test the video model voices
// characters natively (voice.provider = 'minimax-native'), so no VoiceProvider
// is required to generate. This interface exists so ElevenLabs (or MiniMax
// speech) can become the fallback "dub" path without touching clips.

import type { VoiceProfile } from '../types.ts';

export interface SynthesisRequest {
  text: string;
  voice: VoiceProfile;
  language: string;
  emotion?: string;
}

export interface SynthesisResult {
  audio_url: string;
  duration_s: number;
  cost_usd: number;
  simulated: boolean;
}

export interface VoiceProvider {
  readonly id: string;
  readonly paid: boolean;
  estimateCost(text: string): number;
  synthesize(req: SynthesisRequest): Promise<SynthesisResult>;
}

/** Free fake: returns a mock:// URL and a duration estimate. */
export class MockVoiceProvider implements VoiceProvider {
  readonly id = 'mock-voice';
  readonly paid = false;
  private n = 0;

  estimateCost(text: string): number {
    return Math.round(text.length * 0.0001 * 10000) / 10000; // simulated
  }

  async synthesize(req: SynthesisRequest): Promise<SynthesisResult> {
    if (!req.voice.voice_id && req.voice.provider !== 'minimax-native') {
      throw new Error('voice_id required: characters must use their persistent voice');
    }
    const words = req.text.trim().split(/\s+/).length;
    this.n += 1;
    return {
      audio_url: `mock://voice/${this.n}?voice=${encodeURIComponent(req.voice.voice_id ?? 'native')}`,
      duration_s: Math.max(1, words / 2.6),
      cost_usd: this.estimateCost(req.text),
      simulated: true,
    };
  }
}
