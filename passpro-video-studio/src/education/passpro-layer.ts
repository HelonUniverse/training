// PassPro Education Layer: plugs Content Locks into the core Video Studio via
// the PlanValidator and FactContextProvider hooks. Facts are loaded from the
// database (vs_content_locks) through a loader — never embedded in code.

import type { Clip, Series, ValidationIssue } from '../core/types.ts';
import type { FactContextProvider, FactStatement } from '../core/compiler/prompt-compiler.ts';
import type { PlanValidator, StudioLayer } from '../core/workflow/hooks.ts';
import {
  relevantVerifiedLocks,
  validateClipAgainstLocks,
  validateTextAgainstLocks,
  type ContentLock,
} from './content-locks.ts';

/** e.g. select * from vs_content_locks where scope_key = any($1) */
export type ContentLockLoader = (scopeKeys: string[]) => Promise<ContentLock[]>;

export class PassProEducationLayer implements PlanValidator, FactContextProvider {
  readonly id = 'passpro-content-locks';
  private load: ContentLockLoader;

  constructor(load: ContentLockLoader) {
    this.load = load;
  }

  private locksFor(series: Series): Promise<ContentLock[]> {
    const scopes = series.bible.content_lock_scopes ?? [];
    return scopes.length ? this.load(scopes) : Promise.resolve([]);
  }

  async validateClip(clip: Clip, series: Series): Promise<ValidationIssue[]> {
    return validateClipAgainstLocks(clip, await this.locksFor(series));
  }

  async validateText(text: string, series: Series, where: string): Promise<ValidationIssue[]> {
    return validateTextAgainstLocks(text, await this.locksFor(series), { where });
  }

  async factsForClip(clip: Clip, series: Series): Promise<FactStatement[]> {
    return relevantVerifiedLocks(clip, await this.locksFor(series)).map((l) => ({ id: l.id, statement: l.statement }));
  }

  asLayer(): StudioLayer {
    return { validators: [this], facts: this };
  }
}
