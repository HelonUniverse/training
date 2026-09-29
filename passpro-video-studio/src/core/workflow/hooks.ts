// Extension points that subject layers (e.g. PassPro education) implement.
// Core calls them; core never imports a layer.

import type { Clip, Series, ValidationIssue } from '../types.ts';
import type { FactContextProvider } from '../compiler/prompt-compiler.ts';

export interface PlanValidator {
  readonly id: string;
  /** Validate one clip's content (dialogue, action, visual prompt). */
  validateClip(clip: Clip, series: Series): Promise<ValidationIssue[]>;
  /** Validate arbitrary text (e.g. the final compiled prompt) before a paid submission. */
  validateText(text: string, series: Series, where: string): Promise<ValidationIssue[]>;
}

export interface StudioLayer {
  validators: PlanValidator[];
  facts?: FactContextProvider;
}
