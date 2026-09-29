-- ============================================================================
-- PassPro EDUCATION LAYER: Content Locks
--
-- Kept apart from the core schema on purpose: the video engine knows nothing
-- about exams. A series opts in through vs_series.bible->'content_lock_scopes'.
--
-- The DATABASE is the source of truth for facts. Prompts never hard-code
-- them; the prompt compiler reads VERIFIED rows from here at compile time.
-- Only VERIFIED locks are authoritative. UNVERIFIED / STALE / CONFLICT locks
-- never confirm a claim: a script that mentions them needs human review.
-- ============================================================================

create table public.vs_content_locks (
  id                  uuid primary key default gen_random_uuid(),
  -- grouping key a series opts into, e.g. 'FL-2-14'
  scope_key           text not null,
  -- optional link to PassPro's exam catalog (read-only reference)
  exam_id             uuid references public.exams on delete set null,
  concept             text not null,
  statement           text not null,
  value_numeric       numeric,
  value_text          text,
  unit                text,
  jurisdiction        text,
  effective_date      date,
  verified_date       date,
  verified_by         text,
  source_name         text,
  source_url          text,
  source_reference    text,
  verification_status text not null default 'UNVERIFIED'
                        check (verification_status in ('UNVERIFIED', 'VERIFIED', 'STALE', 'CONFLICT')),
  -- detection rules used by the validator:
  -- {require_any: [regex], forbid_any: [regex], forbidden_variants: [text]}
  match_rules         jsonb not null default '{}'::jsonb,
  notes               text not null default '',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (scope_key, concept),
  check (value_numeric is not null or value_text is not null),
  -- a VERIFIED fact must say where it came from and when it was checked
  check (verification_status <> 'VERIFIED'
         or (source_name is not null and verified_date is not null and verified_by is not null))
);

create index vs_content_locks_scope_idx on public.vs_content_locks (scope_key, verification_status);

create trigger vs_content_locks_touch before update on public.vs_content_locks
  for each row execute function public.vs_touch_updated_at();

alter table public.vs_content_locks enable row level security;

create policy vs_content_locks_admin on public.vs_content_locks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
