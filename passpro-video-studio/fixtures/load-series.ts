// Loads a series bible JSON (the same file the SQL seed is generated from)
// into in-memory domain objects for tests and the demo.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Asset, Character, Series } from '../src/core/types.ts';
import { uuid } from '../src/core/util.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

export interface LoadedSeries {
  series: Series;
  characters: Character[];
  assets: Asset[];
}

export function loadSeriesBible(slug = 'en-la-casa-de-dona-poliza'): LoadedSeries {
  const raw = JSON.parse(readFileSync(join(ROOT, 'seed', 'series', `${slug}.json`), 'utf8'));
  const series: Series = { id: uuid(), ...raw.series };
  const characters: Character[] = raw.characters.map((c: any) => ({
    id: uuid(),
    series_id: series.id,
    primary_reference_asset_id: null,
    age: null,
    wardrobe: '',
    negative_prompt: '',
    continuity_notes: '',
    rules: [],
    personality: [],
    ...c,
  }));
  const assets: Asset[] = raw.assets.map((a: any) => ({
    id: uuid(),
    series_id: series.id,
    aliases: [],
    description: '',
    visual_prompt: '',
    negative_prompt: '',
    continuity_notes: '',
    character_id: null,
    parent_asset_id: null,
    storage_path: null,
    mime_type: null,
    status: 'ready',
    metadata: {},
    ...a,
  }));
  return { series, characters, assets };
}

export function readFixture(name: string): string {
  return readFileSync(join(ROOT, 'fixtures', name), 'utf8');
}
